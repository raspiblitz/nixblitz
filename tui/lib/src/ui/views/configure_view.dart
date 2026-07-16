import 'dart:convert';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/branch_picker.dart';
import '../widgets/option_editor.dart';
import '../widgets/password_input.dart';
import '../widgets/tappable.dart';
import '../../providers/ui_state_provider.dart';
import '../../providers/viewport_provider.dart';
import '../layout.dart';
import 'configure/field_editor.dart';
import 'configure/plugin_catalog.dart';
import 'plugin_action_view.dart';
import 'plugin_install_view.dart';
import 'plugin_switch_branch_view.dart';

// ---------------------------------------------------------------------------
// _MenuEntry — sealed sum type for the Configure tab bar
// ---------------------------------------------------------------------------

sealed class _MenuEntry {
  const _MenuEntry();

  String get label;

  /// Identifier used for keyboard-nav state and pending-key lookups.
  String get menuKey;
}

class _SystemEntry extends _MenuEntry {
  const _SystemEntry();
  @override
  String get label => 'System';
  @override
  String get menuKey => 'system';
}

class _ManifestEntry extends _MenuEntry {
  final AppManifest manifest;
  const _ManifestEntry(this.manifest);
  @override
  String get label => manifest.label;
  @override
  String get menuKey => manifest.id;
}

class _PluginsEntry extends _MenuEntry {
  const _PluginsEntry();
  @override
  String get label => 'Plugins';
  @override
  String get menuKey => 'plugins';
}

// ---------------------------------------------------------------------------
// Module-level providers
// ---------------------------------------------------------------------------

final _selectedOptionProvider = StateProvider<int>((ref) => 0);
final _changingPasswordProvider = StateProvider<bool>((ref) => false);
final _statusMessageProvider = StateProvider<String>((ref) => '');

/// Non-null while the user is in overlay-edit mode for a manifest field
/// that requires an editor (StringField / IntField). Holds the app id
/// and field name so the build method can look them up.
final _editingFieldProvider =
    StateProvider<({String appId, String fieldName})?>((ref) => null);

/// Non-null while the user is in inline text-edit mode for a System block
/// string field (hostname or timezone). Uses a dedicated overlay.
enum _SystemTextField { hostname, timezone }

final _editingSystemFieldProvider = StateProvider<_SystemTextField?>(
  (ref) => null,
);

/// When true, the Configure view delegates to [PluginInstallView] —
/// the consent-driven install wizard. Set when the operator picks a
/// row in the Plugins section (catalog entry or "Install from
/// URL…"); reset when the install view dismisses.
final _installingPluginProvider = StateProvider<bool>((ref) => false);

/// URL to seed [PluginInstallView] with — non-null for one-tap
/// installs from the catalog, `null` for the URL-input flow. Read
/// once when the install view mounts; reset alongside
/// [_installingPluginProvider].
final _pendingInstallUrlProvider = StateProvider<String?>((ref) => null);

/// When non-null, the Configure view delegates to [PluginActionView]
/// to run the chosen action. The configure-view body is replaced
/// for the duration of the run, same pattern as
/// [_installingPluginProvider] uses for the install wizard.
///
/// Carries the owning plugin's id alongside the action — [wasm:]
/// actions need it to resolve the plugin's [PluginManifest] (for its
/// `sandbox` block) and installed source dir; [PluginActionView]
/// looks both up via [installedPluginsProvider] /
/// [pluginServiceProvider] rather than have every trigger site do it.
final _runningPluginActionProvider =
    StateProvider<({PluginAction action, String pluginId})?>((ref) => null);

/// When non-null, Configure delegates to [PluginSwitchBranchView] for
/// the plugin id stored here. Cleared on dismiss.
final _switchingPluginIdProvider = StateProvider<String?>((ref) => null);

/// When true, the BranchPicker overlay is rendered above the System
/// section so the operator can pick which nixblitz branch their flake
/// tracks. The overlay writes into [SystemConfig.nixblitzBranch] on
/// confirm; ScaffoldService rewrites the flake URL on the next Apply.
final _branchPickerActiveProvider = StateProvider<bool>((ref) => false);

/// Non-null while the operator is confirming removal of an installed
/// plugin. Holds the plugin id; the build method renders the Remove
/// confirm takeover. Removal is staged (hard-delete of the plugin dir +
/// `plugins.list` regen, identical to `nixblitz plugin remove`) and the
/// node only changes on the next Apply.
final _removingPluginIdProvider = StateProvider<String?>((ref) => null);

/// Format the System pane's Branch row display value from the
/// operator's [configValue] and the embedded [manifest].
///
/// - null            -> `<default-key> (ref: <default-ref>)` — the
///                       ScaffoldService will materialise the manifest's
///                       default into the flake.
/// - `custom:<r>`    -> `custom (ref: <r>)` — operator-typed escape hatch.
/// - declared key    -> `<key> (ref: <ref>)`.
/// - unknown key     -> `<key> (no longer declared, falling back to`
///                       `<default-key>)` — the operator's pin lost its
///                       declaration in a newer manifest.
String _formatBranchDisplay(String? configValue, BranchManifest manifest) {
  if (configValue == null) {
    final dk = manifest.defaultKey;
    if (dk == null) return '(no default declared)';
    return '$dk (ref: ${manifest.branches[dk]!.ref})';
  }
  if (configValue.startsWith('custom:')) {
    return 'custom (ref: ${configValue.substring('custom:'.length)})';
  }
  final entry = manifest.branches[configValue];
  if (entry != null) return '$configValue (ref: ${entry.ref})';
  final dk = manifest.defaultKey;
  return '$configValue (no longer declared, falling back to ${dk ?? '?'})';
}

/// Which column of Configure's two-column layout currently has the
/// keyboard focus. `sidebar` is the section picker on the left;
/// `content` is the section's field / row list on the right.
///
/// Key model (Enter to descend, Esc to ascend — `←/→/h/l` are
/// reserved globally for top-menu navigation):
///   - `j` / `k` / `↑` / `↓`: navigate within the focused column.
///   - `Enter`: from sidebar → focus shifts to content;
///              from content → existing per-row action
///              (edit field / cycle bool / drill into plugin).
///   - `Esc`: from content → focus returns to sidebar;
///            from sidebar → exit Configure to the dashboard.
///
/// `h` / `l` / `←` / `→` are deliberately NOT consumed here —
/// the top menu in `_Shell` claims them globally for view
/// switching. Predictable nav: arrow keys leave the view, Enter
/// drills in, Esc backs out.
enum ConfigureColumn { sidebar, content }

final configureFocusedColumnProvider = StateProvider<ConfigureColumn>(
  (ref) => ConfigureColumn.sidebar,
);

// ---------------------------------------------------------------------------
// ConfigureView
// ---------------------------------------------------------------------------

class ConfigureView extends StatelessComponent {
  const ConfigureView({super.key});

  @override
  Component build(BuildContext context) {
    // ── Password-change overlay (highest priority) ────────────────────
    final changingPassword = context.watch(_changingPasswordProvider);
    if (changingPassword) {
      return PasswordInput(
        title: 'Change Admin Password',
        subtitle: 'Enter a new password for the admin user.',
        minLength: 8,
        requireConfirmation: true,
        onSubmit: (password) {
          final session = context.read(sudoSessionProvider);
          final stdin = Uint8List.fromList(utf8.encode('admin:$password\n'));
          session.runOneShot(['chpasswd'], stdinBytes: stdin).then((res) {
            if (res.exitCode != 0) {
              LogService.error(
                'chpasswd failed: exit=${res.exitCode} '
                'stderr=${res.stderr}',
              );
              context.read(_statusMessageProvider.notifier).state =
                  'Failed to change password (exit ${res.exitCode}).';
            } else {
              LogService.info('Password changed successfully');
              context.read(_statusMessageProvider.notifier).state =
                  'Password changed successfully.';
            }
            context.read(_changingPasswordProvider.notifier).state = false;
          });
        },
        onCancel: () {
          context.read(_changingPasswordProvider.notifier).state = false;
        },
      );
    }

    // ── System text-field inline-edit overlay ────────────────────────
    final editingSystemField = context.watch(_editingSystemFieldProvider);
    if (editingSystemField != null) {
      final configAsync = context.watch(configProvider);
      return configAsync.when(
        loading: () => const Center(child: Text('Loading...')),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (config) {
          final initial = editingSystemField == _SystemTextField.hostname
              ? config.system.hostname
              : config.system.timezone;
          final label = editingSystemField == _SystemTextField.hostname
              ? 'hostname'
              : 'timezone';
          return _SystemTextOverlay(
            label: label,
            initialValue: initial,
            onSubmit: (value) {
              final updated = editingSystemField == _SystemTextField.hostname
                  ? config.copyWith(
                      system: config.system.copyWith(hostname: value),
                    )
                  : config.copyWith(
                      system: config.system.copyWith(timezone: value),
                    );
              context.read(configProvider.notifier).updateConfig(updated);
              context.read(_editingSystemFieldProvider.notifier).state = null;
            },
            onCancel: () {
              context.read(_editingSystemFieldProvider.notifier).state = null;
            },
          );
        },
      );
    }

    // ── Plugin install wizard takeover ───────────────────────────────
    final installingPlugin = context.watch(_installingPluginProvider);
    if (installingPlugin) {
      final presetUrl = context.read(_pendingInstallUrlProvider);
      return PluginInstallView(
        pluginService: context.read(pluginServiceProvider),
        presetUrl: presetUrl,
        onDismiss: () {
          context.read(_installingPluginProvider.notifier).state = false;
          context.read(_pendingInstallUrlProvider.notifier).state = null;
        },
      );
    }

    // ── Plugin branch-switch wizard takeover ─────────────────────────
    final switchingPluginId = context.watch(_switchingPluginIdProvider);
    if (switchingPluginId != null) {
      final markers = context.read(installedPluginMarkersProvider);
      final marker = markers
          .where((m) => m.id == switchingPluginId)
          .firstOrNull;
      final currentBranch = marker?.branch ?? 'main';
      // Look up the declared branches block from the installed plugin's
      // manifest. Null when the plugin's manifest omits `branches` — the
      // shared BranchPicker then renders only the Custom branch… row.
      final manifest = context
          .read(installedPluginsProvider)
          .where((m) => m.id == switchingPluginId)
          .firstOrNull;
      return PluginSwitchBranchView(
        pluginService: context.read(pluginServiceProvider),
        pluginId: switchingPluginId,
        currentBranch: currentBranch,
        branches: manifest?.branches,
        onDismiss: () {
          context.read(_switchingPluginIdProvider.notifier).state = null;
          context.invalidate(pluginAppVersionsProvider);
        },
      );
    }

    // ── Plugin action runner takeover ────────────────────────────────
    final runningAction = context.watch(_runningPluginActionProvider);
    if (runningAction != null) {
      return PluginActionView(
        action: runningAction.action,
        pluginId: runningAction.pluginId,
        runner: context.read(pluginActionRunnerProvider),
        onDismiss: () {
          context.read(_runningPluginActionProvider.notifier).state = null;
        },
      );
    }

    // ── Plugin remove confirm takeover ───────────────────────────────
    final removingPluginId = context.watch(_removingPluginIdProvider);
    if (removingPluginId != null) {
      final pluginName =
          context
              .read(installedPluginsProvider)
              .where((m) => m.id == removingPluginId)
              .map((m) => m.name)
              .firstOrNull ??
          removingPluginId;
      return _PluginRemoveConfirmView(
        pluginId: removingPluginId,
        pluginName: pluginName,
        pluginService: context.read(pluginServiceProvider),
        onConfirmed: () {
          // Drop the plugin's app_configs entry (symmetric with install
          // seeding it). This both clears the now-orphaned config AND makes
          // the removal a config change, so it registers in the top-bar
          // pending count (pendingChangeKeysProvider diffs config keys).
          // Via the notifier so the in-memory config + the file both update.
          final cfg = context.read(configProvider).value;
          if (cfg != null && cfg.appConfigs.containsKey(removingPluginId)) {
            context
                .read(configProvider.notifier)
                .updateConfig(cfg.removeAppConfig(removingPluginId));
          }
          // Sequential provider sets work here (cf. apply_view._reset);
          // refresh the installed-plugin views so the removed row drops.
          context.read(_statusMessageProvider.notifier).state =
              'Removed $removingPluginId — run System → Apply to rebuild.';
          context.read(_selectedOptionProvider.notifier).state = 0;
          context.read(_removingPluginIdProvider.notifier).state = null;
          context.invalidate(installedPluginsProvider);
          context.invalidate(installedPluginMarkersProvider);
        },
        onCancel: () {
          context.read(_removingPluginIdProvider.notifier).state = null;
        },
      );
    }

    // ── Main view ────────────────────────────────────────────────────
    final configAsync = context.watch(configProvider);
    final serviceIndex = context.watch(selectedServiceIndexProvider);
    final selectedOption = context.watch(_selectedOptionProvider);
    final statusMessage = context.watch(_statusMessageProvider);
    final editingField = context.watch(_editingFieldProvider);
    // Yield focus while a modal popup is up — sudo / help / branch picker.
    // The branch picker is a Stack-sibling overlay (not a takeover) so
    // its visibility is folded into modalActive locally rather than via
    // ui_state_provider, mirroring how the picker is scoped to this view.
    final branchPickerActive = context.watch(_branchPickerActiveProvider);
    final modalActive =
        context.watch(modalActiveProvider) || branchPickerActive;
    final registry = context.watch(appManifestRegistryProvider);

    // Build the manifest-driven menu: System + all apps + Plugins.
    final menuEntries = <_MenuEntry>[
      const _SystemEntry(),
      for (final m in registry.allApps) _ManifestEntry(m),
      const _PluginsEntry(),
    ];

    return configAsync.when(
      loading: () => const Center(child: Text('Loading...')),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (config) {
        final currentEntry =
            menuEntries[serviceIndex.clamp(0, menuEntries.length - 1)];

        // Manifest-entry overlay-edit mode: render the field editor overlay.
        if (editingField != null && currentEntry is _ManifestEntry) {
          final manifest = currentEntry.manifest;
          final field = manifest.field(editingField.fieldName);
          if (field != null && fieldRequiresEditor(field)) {
            final currentValue = config.appConfig(
              editingField.appId,
            )[field.name];
            return buildFieldEditor(
              field: field,
              currentValue: currentValue,
              onSubmit: (value) {
                final updated = config.setAppOption(
                  editingField.appId,
                  field.name,
                  value,
                );
                context.read(configProvider.notifier).updateConfig(updated);
                context.read(_editingFieldProvider.notifier).state = null;
              },
              onCancel: () {
                context.read(_editingFieldProvider.notifier).state = null;
              },
            );
          } else {
            // Stale editing state. Clear it.
            context.read(_editingFieldProvider.notifier).state = null;
          }
        }

        // Per-key pending markers from pendingChangeKeysProvider.
        // Synchronous Provider (NOT FutureProvider) — direct read, no
        // AsyncValue unwrap, no flicker frame on configProvider ticks.
        final pendingKeys = context.watch(pendingChangeKeysProvider);
        final focusedColumn = context.watch(configureFocusedColumnProvider);
        // Pass -1 (no row "selected") when the sidebar owns focus, so
        // option editors skip the cursor + accent and render in their
        // idle color. Avoids the misleading "> hostname: [foo]" cue
        // when j/k is actually moving the sidebar.
        final visibleSelected = focusedColumn == ConfigureColumn.content
            ? selectedOption
            : -1;
        final options = _buildOptions(
          context,
          config,
          currentEntry,
          visibleSelected,
          pendingKeys: pendingKeys,
        );

        // Number of navigable rows for j/k in the content column.
        // System / Manifest entries: fields + plugin actions (the
        // rendered options list interleaves a non-selectable
        // header so .length includes those — use the explicit
        // count instead). Plugins: catalog entries not yet
        // installed + 1 (the "Install from URL…" row). _buildOptions
        // returns an empty list for Plugins because its body is
        // rendered separately via _buildPluginsContent.
        final int contentRowCount;
        if (currentEntry is _PluginsEntry) {
          final installedIds = context
              .read(installedPluginsProvider)
              .map((m) => m.id)
              .toSet();
          final availableCount = officialPluginCatalog
              .where((p) => !installedIds.contains(p.id))
              .length;
          contentRowCount = availableCount + 1;
        } else if (currentEntry is _ManifestEntry) {
          // +1 for the synthetic "Switch branch…" row in the Actions section.
          // The row is always rendered (pinned plugins show it as display-only
          // but it occupies a slot); only installed plugins (those backed by a
          // PluginManifest) have the switch-branch row — bundled apps don't
          // have a PluginMarker and thus no branch to switch. Guard by
          // checking whether a marker exists.
          final hasMarker = context
              .read(installedPluginMarkersProvider)
              .any((m) => m.id == currentEntry.manifest.id);
          // +2 synthetic rows for installed plugins: the "Switch branch…"
          // row and the trailing "Remove plugin" row that bracket the
          // declared actions. Bundled apps (no marker) have neither.
          contentRowCount =
              currentEntry.manifest.fields.length +
              (hasMarker ? 2 : 0) +
              _actionsFor(context, currentEntry.manifest.id).length;
        } else {
          contentRowCount = options.length;
        }

        final body = Focusable(
          focused: !modalActive,
          onKeyEvent: (event) {
            try {
              // Clear status message on any key press.
              if (statusMessage.isNotEmpty) {
                context.read(_statusMessageProvider.notifier).state = '';
              }

              // Vertical nav: dispatch based on which column is focused.
              // Sidebar: walk sections; content: walk rows within section.
              if (event.logicalKey == LogicalKey.keyJ ||
                  event.logicalKey == LogicalKey.arrowDown) {
                if (focusedColumn == ConfigureColumn.sidebar) {
                  if (serviceIndex < menuEntries.length - 1) {
                    context.read(selectedServiceIndexProvider.notifier).state =
                        serviceIndex + 1;
                    context.read(_selectedOptionProvider.notifier).state = 0;
                  }
                } else {
                  final max = contentRowCount - 1;
                  if (selectedOption < max) {
                    context.read(_selectedOptionProvider.notifier).state =
                        selectedOption + 1;
                  }
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyK ||
                  event.logicalKey == LogicalKey.arrowUp) {
                if (focusedColumn == ConfigureColumn.sidebar) {
                  if (serviceIndex > 0) {
                    context.read(selectedServiceIndexProvider.notifier).state =
                        serviceIndex - 1;
                    context.read(_selectedOptionProvider.notifier).state = 0;
                  }
                } else {
                  if (selectedOption > 0) {
                    context.read(_selectedOptionProvider.notifier).state =
                        selectedOption - 1;
                  }
                }
                return true;
              }

              // Enter / Space: sidebar → focus content; content →
              // existing drill-in (edit field, cycle bool, drill plugin).
              if (event.logicalKey == LogicalKey.enter ||
                  event.logicalKey == LogicalKey.space) {
                if (focusedColumn == ConfigureColumn.sidebar) {
                  context.read(configureFocusedColumnProvider.notifier).state =
                      ConfigureColumn.content;
                } else {
                  _handleEnter(context, config, currentEntry, selectedOption);
                }
                return true;
              }

              // Plugins section: Enter on a row drives install (see
              // _handleEnter); refresh lives in System → Apply. Remove is
              // the synthetic "Remove plugin" action row (or the
              // `nixblitz plugin remove` CLI).

              // Esc: content → sidebar, sidebar → dashboard. The
              // arrow keys (`←/→/h/l`) are reserved for the top
              // menu and intentionally bubble past this handler.
              if (event.logicalKey == LogicalKey.escape) {
                if (focusedColumn == ConfigureColumn.content) {
                  context.read(configureFocusedColumnProvider.notifier).state =
                      ConfigureColumn.sidebar;
                } else {
                  // Set the prompt before navigating: per the nocterm
                  // pitfall, the second provider set in a handler is
                  // the one at risk of being dropped by a rebuild, so
                  // order the navigate last. (Sequential provider sets
                  // work in practice — cf. apply_view._reset.)
                  if (context.read(pendingChangeKeysProvider).isNotEmpty) {
                    context.read(applyNowPromptProvider.notifier).state =
                        const ApplyNowPrompt();
                  }
                  context.read(currentViewProvider.notifier).state =
                      AppView.dashboard;
                }
                return true;
              }
              return false;
            } catch (e, st) {
              LogService.error('Configure view key handler failed', e, st);
              return true;
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildBody(
                  context: context,
                  compact:
                      context.watch(viewportClassProvider) ==
                      ViewportClass.compact,
                  focusedColumn: focusedColumn,
                  menuEntries: menuEntries,
                  serviceIndex: serviceIndex,
                  currentEntry: currentEntry,
                  selectedOption: selectedOption,
                  options: options,
                ),
              ),
              if (statusMessage.isNotEmpty) ...[
                const SizedBox(height: 1),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    statusMessage,
                    style: TextStyle(
                      color: statusMessage.contains('Failed')
                          ? const Color.fromRGB(255, 80, 80)
                          : const Color.fromRGB(110, 220, 110),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );

        // Stack-sibling overlay for the BranchPicker. Rendered above the
        // body Focusable when _branchPickerActiveProvider is true; the
        // body's Focusable yields focus via the modalActive gate above
        // (CLAUDE.md pitfall #6) so the picker's Focusable catches the
        // keys.
        if (!branchPickerActive) {
          return body;
        }
        return Stack(
          children: [
            body,
            Container(
              padding: const EdgeInsets.all(2),
              child: BranchPicker(
                manifest: context.watch(nixblitzBranchManifestProvider),
                currentValue: config.system.nixblitzBranch,
                focused: true,
                onSelected: (newValue) {
                  // newValue is a declared key (e.g. "stable") or the
                  // encoded "custom:<ref>" form. Persisted as-is —
                  // ScaffoldService resolves it against the manifest at
                  // flake-rewrite time. No immediate scaffold trigger:
                  // the operator sees the new value reflected in the
                  // Branch row and rebuilds on demand via Apply.
                  final updated = config.copyWith(
                    system: config.system.copyWith(nixblitzBranch: newValue),
                  );
                  context.read(configProvider.notifier).updateConfig(updated);
                  context.read(_branchPickerActiveProvider.notifier).state =
                      false;
                },
                onCancel: () {
                  context.read(_branchPickerActiveProvider.notifier).state =
                      false;
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Enter / Space handler
  // ---------------------------------------------------------------------------

  void _handleEnter(
    BuildContext context,
    NixblitzConfig config,
    _MenuEntry currentEntry,
    int selectedOption,
  ) {
    // System tab: typed block handling.
    if (currentEntry is _SystemEntry) {
      _handleSystemEnter(context, config, selectedOption);
      return;
    }

    // Plugins tab: rows are install targets — catalog entries +
    // a trailing "Install from URL…" row. Row order matches
    // `_buildPluginsContent`. Configuring an installed plugin
    // happens via its own sidebar entry (Bitcoin Core, LNBits, …)
    // — the Plugins section is install-focused.
    if (currentEntry is _PluginsEntry) {
      final installed = context
          .read(installedPluginsProvider)
          .map((m) => m.id)
          .toSet();
      final available = officialPluginCatalog
          .where((p) => !installed.contains(p.id))
          .toList();
      if (selectedOption < available.length) {
        context.read(_pendingInstallUrlProvider.notifier).state =
            available[selectedOption].url;
        context.read(_installingPluginProvider.notifier).state = true;
      } else if (selectedOption == available.length) {
        // "Install from URL…" — open the wizard's URL-input phase.
        context.read(_pendingInstallUrlProvider.notifier).state = null;
        context.read(_installingPluginProvider.notifier).state = true;
      }
      return;
    }

    // Manifest entry: generic field dispatch, with a trailing
    // actions slice for plugins that declare any. Field indices
    // come first; then the synthetic "Switch branch…" row (for
    // installed plugins that have a PluginMarker); then manifest
    // actions occupy the remaining slots.
    //
    // Row layout when a marker exists:
    //   [0 .. fieldCount)                  → fields
    //   fieldCount                          → Switch branch… (synthetic)
    //   [fieldCount+1 .. fieldCount+1+N)   → declared plugin actions
    //
    // When no marker (bundled app), the synthetic row is absent:
    //   [0 .. fieldCount)                  → fields
    //   [fieldCount .. fieldCount+N)       → declared plugin actions
    if (currentEntry is _ManifestEntry) {
      final manifest = currentEntry.manifest;
      final fieldCount = manifest.fields.length;
      final actions = _actionsFor(context, manifest.id);
      final markers = context.read(installedPluginMarkersProvider);
      final marker = markers.where((m) => m.id == manifest.id).firstOrNull;
      final hasMarker = marker != null;

      if (selectedOption >= fieldCount) {
        if (hasMarker) {
          // First slot after fields = synthetic Switch-branch row.
          if (selectedOption == fieldCount) {
            // Pinned plugins: switch not allowed — silently ignore Enter.
            if (marker.autoUpdate == false) return;
            // Guard: skip if a switch is already in progress.
            if (context.read(_switchingPluginIdProvider) != null) return;
            // Defer the StateProvider set to comply with CLAUDE.md pitfall
            // #1 — setting a StateProvider inside onKeyEvent triggers an
            // immediate rebuild that discards the rest of the handler. Use
            // Future.microtask so the event loop processes it after the
            // current key handler returns.
            final pluginId = manifest.id;
            Future.microtask(() {
              context.read(_switchingPluginIdProvider.notifier).state =
                  pluginId;
            });
            return;
          }
          // Slots after the synthetic Switch-branch row: the declared
          // actions, then a synthetic "Remove plugin" row last.
          final afterSwitch = selectedOption - fieldCount - 1;
          if (afterSwitch < 0) return;
          if (afterSwitch < actions.length) {
            context.read(_runningPluginActionProvider.notifier).state = (
              action: actions[afterSwitch],
              pluginId: manifest.id,
            );
            return;
          }
          if (afterSwitch == actions.length) {
            // Synthetic Remove row → open the confirm takeover. Deferred
            // per CLAUDE.md pitfall #1 (a provider set mid-handler discards
            // the rest of the handler).
            final pluginId = manifest.id;
            Future.microtask(() {
              context.read(_removingPluginIdProvider.notifier).state = pluginId;
            });
            return;
          }
          return;
        } else {
          // No marker — no synthetic row; actions start immediately after
          // fields.
          final actionIndex = selectedOption - fieldCount;
          if (actionIndex < 0 || actionIndex >= actions.length) return;
          context.read(_runningPluginActionProvider.notifier).state = (
            action: actions[actionIndex],
            pluginId: manifest.id,
          );
          return;
        }
      }

      final field = manifest.fields[selectedOption];
      final appId = manifest.id;

      if (fieldRequiresEditor(field)) {
        // Enter overlay-edit mode; the build() method renders the editor.
        context.read(_editingFieldProvider.notifier).state = (
          appId: appId,
          fieldName: field.name,
        );
      } else {
        // Cycle bool / enum in-place.
        final current = config.appConfig(appId)[field.name];
        final next = cycleFieldValue(field, current);
        final updated = config.setAppOption(appId, field.name, next);
        context.read(configProvider.notifier).updateConfig(updated);
      }
    }
  }

  /// Handle Enter for the System tab (typed block — hostname,
  /// timezone, shell, tor, branch, password). Platform is not editable
  /// post-install — see the comment in [_buildSystemOptions].
  void _handleSystemEnter(
    BuildContext context,
    NixblitzConfig config,
    int optionIndex,
  ) {
    switch (optionIndex) {
      case 0:
        // hostname — enter text-edit overlay
        context.read(_editingSystemFieldProvider.notifier).state =
            _SystemTextField.hostname;
      case 1:
        // timezone — enter text-edit overlay
        context.read(_editingSystemFieldProvider.notifier).state =
            _SystemTextField.timezone;
      case 2:
        const shells = ['bash', 'nushell'];
        final next = (shells.indexOf(config.system.shell) + 1) % shells.length;
        final updated = config.copyWith(
          system: config.system.copyWith(shell: shells[next]),
        );
        context.read(configProvider.notifier).updateConfig(updated);
      case 3:
        final torUpdated = config.copyWith(
          system: config.system.copyWith(tor: !config.system.tor),
        );
        context.read(configProvider.notifier).updateConfig(torUpdated);
      case 4:
        // Branch — open the BranchPicker overlay. The overlay's
        // onSelected handler writes into SystemConfig.nixblitzBranch
        // and ScaffoldService rewrites the flake URL on next Apply.
        // Defer the StateProvider set to a microtask so the rest of
        // this handler returns cleanly first (CLAUDE.md pitfall #1 —
        // setting a provider mid-handler triggers a rebuild that
        // discards the remaining sync work).
        Future.microtask(() {
          context.read(_branchPickerActiveProvider.notifier).state = true;
        });
      case 5:
        // Password change — authenticate sudo first.
        final session = context.read(sudoSessionProvider);
        session.ensureFresh().then((ok) {
          if (ok) {
            context.read(_changingPasswordProvider.notifier).state = true;
          } else {
            context.read(_statusMessageProvider.notifier).state =
                'sudo authorization required to change password.';
          }
        });
    }
  }

  // ---------------------------------------------------------------------------
  // Body layout (wide = sidebar + content row; compact = single pane)
  // ---------------------------------------------------------------------------

  Component _buildBody({
    required BuildContext context,
    required bool compact,
    required ConfigureColumn focusedColumn,
    required List<_MenuEntry> menuEntries,
    required int serviceIndex,
    required _MenuEntry currentEntry,
    required int selectedOption,
    required List<Component> options,
  }) {
    final sidebar = _ConfigureSidebar(
      entries: menuEntries,
      selectedIndex: serviceIndex.clamp(0, menuEntries.length - 1),
      focused: focusedColumn == ConfigureColumn.sidebar,
    );
    final innerBody = currentEntry is _PluginsEntry
        ? _buildPluginsContent(
            context,
            selectedOption,
            focusedColumn == ConfigureColumn.content,
          )
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: options,
            ),
          );

    final content = Container(
      // Right pane gets its own full-rectangle border so focus is
      // conveyed via border color (same idiom as the sidebar).
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: focusedColumn == ConfigureColumn.content
              ? const Color.fromRGB(140, 140, 180)
              : const Color.fromRGB(50, 50, 70),
        ),
      ),
      child: _ConfigureContentScroll(
        selectedOption: selectedOption,
        child: innerBody,
      ),
    );

    if (!compact) {
      // Desktop / tablet — both panes side-by-side.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sidebar,
          Expanded(child: content),
        ],
      );
    }

    // Phone-over-SSH — single pane at a time. Sidebar fills width
    // when focused; content fills width otherwise + grows a back
    // header so the operator knows Esc returns to the section list.
    if (focusedColumn == ConfigureColumn.sidebar) {
      return SizedBox.expand(child: sidebar);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CompactBackHeader(label: currentEntry.label),
        Expanded(child: content),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Option builders
  // ---------------------------------------------------------------------------

  List<Component> _buildOptions(
    BuildContext ctx,
    NixblitzConfig config,
    _MenuEntry entry,
    int selectedIndex, {
    Set<String> pendingKeys = const <String>{},
  }) {
    bool isPending(String key) => pendingKeys.contains(key);

    return switch (entry) {
      _SystemEntry() => _buildSystemOptions(
        ctx,
        config,
        selectedIndex,
        isPending,
      ),
      _ManifestEntry(:final manifest) => _buildManifestOptions(
        ctx,
        config,
        manifest,
        selectedIndex,
        isPending,
      ),
      // Plugins entry is handled by `_buildPluginsContent` higher up
      // in the layout (two-column inline). _buildOptions's caller
      // never reaches this branch for Plugins; the empty list keeps
      // the switch exhaustive.
      _PluginsEntry() => const <Component>[],
    };
  }

  // ---------- System (typed block — behaviour unchanged) ----------

  List<Component> _buildSystemOptions(
    BuildContext ctx,
    NixblitzConfig config,
    int selectedIndex,
    bool Function(String) isPending,
  ) {
    // Platform is intentionally NOT shown here — it's locked in at
    // install time (disko layout, bootloader, Pi-5 vs x86 kernel
    // line all derive from it) and flipping `pi5 ↔ x86 ↔ vm` post-
    // install produces an unbootable system. The wizard sets it
    // once; subsequent changes require a fresh install.
    final branchManifest = ctx.watch(nixblitzBranchManifestProvider);
    return [
      TextOptionEditor(
        label: 'hostname',
        value: config.system.hostname,
        focused: selectedIndex == 0,
        pending: isPending('system.hostname'),
      ),
      TextOptionEditor(
        label: 'timezone',
        value: config.system.timezone,
        focused: selectedIndex == 1,
        pending: isPending('system.timezone'),
      ),
      SelectOptionEditor(
        label: 'shell',
        value: config.system.shell,
        options: const ['bash', 'nushell'],
        focused: selectedIndex == 2,
        pending: isPending('system.shell'),
      ),
      SelectOptionEditor(
        label: 'tor',
        value: config.system.tor ? 'enabled' : 'disabled',
        options: const ['enabled', 'disabled'],
        focused: selectedIndex == 3,
        pending: isPending('system.tor'),
      ),
      // Branch — operator's pick of which nixblitz branch the flake
      // tracks. Editor is the shared BranchPicker overlay, opened
      // via _handleSystemEnter when selectedIndex == 4. Display-only
      // here; the pending marker fires when the stored value differs
      // from the on-disk config (e.g. operator picked a non-default).
      TextOptionEditor(
        label: 'Branch',
        value: _formatBranchDisplay(
          config.system.nixblitzBranch,
          branchManifest,
        ),
        focused: selectedIndex == 4,
        pending: isPending('system.nixblitz_branch'),
      ),
      TextOptionEditor(
        label: 'password',
        value: 'Press Enter to change',
        focused: selectedIndex == 5,
        // No pending marker — password is not a config field.
      ),
    ];
  }

  // ---------- Generic manifest walker ----------

  List<Component> _buildManifestOptions(
    BuildContext ctx,
    NixblitzConfig config,
    AppManifest manifest,
    int selectedIndex,
    bool Function(String) isPending,
  ) {
    final appConfig = config.appConfig(manifest.id);
    final actions = _actionsFor(ctx, manifest.id);
    final fieldCount = manifest.fields.length;

    // Look up the PluginMarker for this app, if it's an installed plugin.
    final markers = ctx.read(installedPluginMarkersProvider);
    final marker = markers.where((m) => m.id == manifest.id).firstOrNull;

    // Row layout (when marker present):
    //   [0 .. fieldCount)       → fields
    //   fieldCount              → Switch branch… (synthetic)
    //   [fieldCount+1 .. ..)   → declared actions
    //
    // When no marker, synthetic row is absent and actions start at fieldCount.

    final result = <Component>[
      // Channel info line near the top — visible only for installed plugins.
      if (marker != null) ...[
        Text(
          'Channel: ${marker.branch}',
          style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
        const SizedBox(height: 1),
      ],
      for (var i = 0; i < fieldCount; i++)
        FieldDisplayRow(
          field: manifest.fields[i],
          currentValue: appConfig[manifest.fields[i].name],
          selected: selectedIndex == i,
          pending: isPending('${manifest.id}.${manifest.fields[i].name}'),
        ),
      // Actions section — shown when the plugin has a marker (installed
      // plugin) or when it declares actions. The Switch-branch synthetic
      // row is always first when a marker is present.
      if (marker != null || actions.isNotEmpty) ...[
        const SizedBox(height: 1),
        const Text(
          'Actions',
          style: TextStyle(
            color: Color.fromRGB(247, 147, 26),
            fontWeight: FontWeight.bold,
          ),
        ),
        if (marker != null) ...[
          // Synthetic Switch-branch row — row index fieldCount.
          if (marker.autoUpdate) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${selectedIndex == fieldCount ? "> " : "  "}Switch branch…',
                    style: TextStyle(
                      color: selectedIndex == fieldCount
                          ? const Color.fromRGB(247, 147, 26)
                          : const Color.fromRGB(220, 220, 220),
                      fontWeight: selectedIndex == fieldCount
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  Text(
                    '    Switch this plugin to a different branch.',
                    style: const TextStyle(color: Color.fromRGB(140, 140, 150)),
                  ),
                ],
              ),
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Text(
                '  Switch branch… (pinned — unpin to switch)',
                style: const TextStyle(color: Color.fromRGB(140, 140, 150)),
              ),
            ),
          ],
        ],
        for (var i = 0; i < actions.length; i++)
          _ActionRow(
            action: actions[i],
            selected:
                selectedIndex == fieldCount + (marker != null ? 1 : 0) + i,
          ),
        // Synthetic "Remove plugin" row (installed plugins only) — the last
        // selectable row; Enter opens the confirm. Same shape as the
        // Switch-branch row above.
        if (marker != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${selectedIndex == fieldCount + 1 + actions.length ? "> " : "  "}Remove plugin',
                  style: TextStyle(
                    color: selectedIndex == fieldCount + 1 + actions.length
                        ? const Color.fromRGB(247, 147, 26)
                        : const Color.fromRGB(220, 220, 220),
                    fontWeight: selectedIndex == fieldCount + 1 + actions.length
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                const Text(
                  '    Remove this plugin (takes effect on the next Apply).',
                  style: TextStyle(color: Color.fromRGB(140, 140, 150)),
                ),
              ],
            ),
          ),
      ],
    ];
    return result;
  }

  /// Look up the installed plugin matching [appId]. Returns its
  /// declared actions in stable order, or empty when the app is
  /// bundled (no PluginManifest backing), the plugin declared none,
  /// or the plugin is currently disabled.
  List<PluginAction> _actionsFor(BuildContext ctx, String appId) {
    final installed = ctx.read(installedPluginsProvider);
    final plugin = installed.where((p) => p.id == appId).firstOrNull;
    final enabled =
        ctx.read(configProvider).value?.isAppEnabled(appId) ?? false;
    return visiblePluginActions(plugin: plugin, enabled: enabled);
  }

  // ---------- Plugins (install catalog) ----------

  /// Right-pane renderer for the Plugins section. Lists the
  /// catalog of official plugins not yet installed (one row each)
  /// plus a trailing "Install from URL…" row. Enter on a row drives
  /// [PluginInstallView] — catalog rows pass a preset URL so the
  /// wizard skips the URL-input phase. Configuring an installed
  /// plugin happens via its own sidebar entry, not here.
  Component _buildPluginsContent(
    BuildContext context,
    int selectedIndex,
    bool contentFocused,
  ) {
    final installedManifests = context.watch(installedPluginsProvider);
    final installedMarkers = context.watch(installedPluginMarkersProvider);
    final installedMarkerMap = {for (final m in installedMarkers) m.id: m};
    final installed = installedManifests.map((m) => m.id).toSet();
    final available = officialPluginCatalog
        .where((p) => !installed.contains(p.id))
        .toList();

    const accent = Color.fromRGB(247, 147, 26);
    const normal = Color.fromRGB(200, 200, 200);
    const label = Color.fromRGB(150, 150, 180);
    const dim = Color.fromRGB(140, 140, 150);
    const inactive = Color.fromRGB(85, 85, 105);

    // selectedOption is shared with other Configure sections; the
    // Enter handler clamps it. Total row count = catalog rows +
    // the trailing "Install from URL…" row.
    final totalRows = available.length + 1;
    final clamped = selectedIndex.clamp(0, totalRows - 1);

    // Column widths for the installed-plugins table.
    // Names vary widely ("LNBits" vs "Lightning Network Daemon"), so
    // pad to the widest (and the header) for aligned columns.
    final installedNameW = installedManifests
        .map((m) => m.name.length)
        .fold('Plugin'.length, (a, b) => a > b ? a : b);
    String pluginVersionLabel(PluginManifest m) =>
        (m.version == null || m.version!.isEmpty) ? '—' : 'v${m.version!}';
    final installedVerW = installedManifests
        .map((m) => pluginVersionLabel(m).length)
        .fold('Version'.length, (a, b) => a > b ? a : b);
    // App versions resolved on demand by running each plugin's
    // app_version command (cached by the provider). Empty while the
    // FutureProvider is still resolving → cells show "…".
    final appVersions =
        context.watch(pluginAppVersionsProvider).value ??
        const <String, String>{};
    // App version column width — needed because it's no longer trailing.
    final installedAppVerW = installedManifests
        .map((m) => (appVersions[m.id] ?? '…').length)
        .fold('App version'.length, (a, b) => a > b ? a : b);
    // Channel is the trailing column — no padding needed on the last column.

    final children = <Component>[
      // Installed plugins (display-only) — surfaces each plugin's
      // version for at-a-glance audit. The app version (the actual
      // bitcoind/lnd/etc binary) is reported separately on each
      // dashboard tile; this is the plugin packaging version.
      if (installedManifests.isNotEmpty) ...[
        Text(
          'Installed',
          style: TextStyle(
            color: contentFocused ? accent : inactive,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          '  ${'Plugin'.padRight(installedNameW)}   '
          '${'Version'.padRight(installedVerW)}   '
          '${'App version'.padRight(installedAppVerW)}   Channel',
          style: TextStyle(color: contentFocused ? label : inactive),
        ),
        for (final m in installedManifests)
          Text(
            '  ${m.name.padRight(installedNameW)}   '
            '${pluginVersionLabel(m).padRight(installedVerW)}   '
            '${(appVersions[m.id] ?? '…').padRight(installedAppVerW)}   '
            '${installedMarkerMap[m.id]?.branch ?? '—'}',
            style: TextStyle(color: contentFocused ? normal : inactive),
          ),
        const SizedBox(height: 1),
      ],
      Text(
        'Install a plugin',
        style: TextStyle(
          color: contentFocused ? accent : inactive,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 1),
      Text(
        installed.isEmpty
            ? 'Pick a plugin to install on this node.'
            : available.isEmpty
            ? 'All official plugins are installed. Use the URL '
                  'option below to install a plugin from any forge.'
            : 'Catalog of official plugins not yet installed. '
                  'Enter installs the highlighted row.',
        style: TextStyle(color: contentFocused ? dim : inactive),
      ),
      const SizedBox(height: 1),
    ];

    // Drop long descriptions when the terminal is vertically
    // short — phone SSH clients with the keyboard up report ~10-12
    // rows regardless of orientation. Names like "LNBits" /
    // "Tailscale" / "Electrs" are familiar enough that the
    // operator doesn't need a paragraph per row eating their
    // already-cramped screen height.
    final short = context.watch(viewportShortProvider);

    for (var i = 0; i < available.length; i++) {
      final isActive = i == clamped;
      final showCursor = isActive && contentFocused;
      final p = available[i];
      final nameColor = contentFocused
          ? (isActive ? accent : normal)
          : inactive;
      final descColor = contentFocused ? dim : inactive;
      children.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${showCursor ? "> " : "  "}${p.name}',
              style: TextStyle(
                color: nameColor,
                fontWeight: showCursor ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (!short)
              Text('    ${p.description}', style: TextStyle(color: descColor)),
          ],
        ),
      );
      children.add(const SizedBox(height: 1));
    }

    // Trailing "Install from URL…" row — index == available.length.
    final urlIsActive = clamped == available.length;
    final urlCursor = urlIsActive && contentFocused;
    final urlNameColor = contentFocused
        ? (urlIsActive ? accent : normal)
        : inactive;
    final urlDescColor = contentFocused ? dim : inactive;
    children.add(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${urlCursor ? "> " : "  "}Install from URL…',
            style: TextStyle(
              color: urlNameColor,
              fontWeight: urlCursor ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (!short)
            Text(
              '    Paste a github: / forgejo: / https:// plugin URL.',
              style: TextStyle(color: urlDescColor),
            ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...children,
          if (installed.isNotEmpty) ...[
            const SizedBox(height: 1),
            Text(
              'Already installed: ${installed.toList().join(", ")}',
              style: TextStyle(color: contentFocused ? label : inactive),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// visiblePluginActions — pure helper for the actions gate
// ---------------------------------------------------------------------------

/// Visible actions for [plugin]: the plugin's declared actions in stable
/// order, or empty when the plugin is missing OR disabled (a halted plugin
/// offers no Connect/Down/etc.).
List<PluginAction> visiblePluginActions({
  required PluginManifest? plugin,
  required bool enabled,
}) {
  if (plugin == null || !enabled) return const [];
  final entries = plugin.actions.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((e) => e.value).toList(growable: false);
}

// ---------------------------------------------------------------------------
// pluginStatusLabel — pure helper for the plugins-tab STATUS column
// ---------------------------------------------------------------------------

/// Compute the STATUS column label for the plugins tab. Pure helper so
/// it's testable without rendering the view.
///
/// Rules (in order):
///
///   - marker == null                     → "marker missing"
///   - marker.disabled                    → "disabled"
///   - !marker.disabled, !cfgEnabled      → "off"
///   - !marker.disabled,  cfgEnabled      → "active"
///
/// "pinned" (marker.autoUpdate == false) is orthogonal: when present,
/// appended as " · pinned" suffix. Pin is suppressed for the
/// "marker missing" case where there's no marker to pin.
String pluginStatusLabel({
  required PluginMarker? marker,
  required bool cfgEnabled,
}) {
  final buf = StringBuffer();
  if (marker == null) {
    buf.write('marker missing');
  } else if (marker.disabled) {
    buf.write('disabled');
  } else {
    buf.write(cfgEnabled ? 'active' : 'off');
  }
  if (marker != null && !marker.autoUpdate) {
    buf.write(' · pinned');
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// pluginSigShort — pure helper for the plugins-tab SIG column
// ---------------------------------------------------------------------------

/// Render the marker's pinned signature fingerprint as a short tag for
/// the plugins-tab SIG column. Three states:
///
///   - marker == null                       → "?       "
///   - marker.signatureFingerprint == null  → "(unsign)"
///   - signed                                → first 8 chars of the
///                                              fingerprint after any
///                                              `algo:` prefix
///
/// Pure helper — testable without rendering. The full fingerprint
/// surfaces in the install consent prompt and in the
/// PluginSignatureMismatch UX.
String pluginSigShort(PluginMarker? marker) {
  if (marker == null) return '?       ';
  final fp = marker.signatureFingerprint;
  if (fp == null) return '(unsign)';
  // Strip a leading `SHA256:` / `RSA:` / etc. prefix if present.
  final colon = fp.indexOf(':');
  final body = colon >= 0 ? fp.substring(colon + 1) : fp;
  return body.length >= 8 ? body.substring(0, 8) : body.padRight(8);
}

// ---------------------------------------------------------------------------
// _ConfigureSidebar — left-column section picker
//
// Renders the manifest-driven menu (System + each app + Plugins) as a
// vertical list. Stateless — selection + focus come in as props; the
// parent's onKeyEvent owns navigation.
// ---------------------------------------------------------------------------

/// Selectable row for a plugin-declared action. Renders the action's
/// label + optional description; styled like the field rows above so
/// the operator perceives them as part of the same list. Confirm /
/// input handling happens in [PluginActionView] after Enter — this
/// row is presentation only.
class _ActionRow extends StatelessComponent {
  final PluginAction action;
  final bool selected;

  const _ActionRow({required this.action, required this.selected});

  @override
  Component build(BuildContext context) {
    final cursor = selected ? '> ' : '  ';
    final labelColor = selected
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(220, 220, 220);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$cursor${action.label}',
            style: TextStyle(
              color: labelColor,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (action.description.isNotEmpty)
            Text(
              '    ${action.description}',
              style: const TextStyle(color: Color.fromRGB(140, 140, 150)),
            ),
        ],
      ),
    );
  }
}

class _ConfigureSidebar extends StatelessComponent {
  final List<_MenuEntry> entries;
  final int selectedIndex;
  final bool focused;

  const _ConfigureSidebar({
    required this.entries,
    required this.selectedIndex,
    required this.focused,
  });

  @override
  Component build(BuildContext context) {
    // Focus is conveyed via text-contrast: focused column = active
    // row in accent+bold with `> ` cursor, others in normal idle.
    // Unfocused column = everything drops to dim grey so the eye is
    // pulled to the other side. The right-edge border is a
    // secondary cue (brighter on the focused column).
    const accent = Color.fromRGB(247, 147, 26);
    const idle = Color.fromRGB(180, 180, 200);
    const dim = Color.fromRGB(85, 85, 105);
    const borderActive = Color.fromRGB(140, 140, 180);
    const borderIdle = Color.fromRGB(50, 50, 70);

    return Container(
      width: kSidebarWidth.toDouble(),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      decoration: BoxDecoration(
        border: BoxBorder.all(color: focused ? borderActive : borderIdle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++)
            () {
              final isActive = i == selectedIndex;
              // Cursor + a brighter color stay on the active entry
              // even when the column is unfocused — operator needs
              // "I'm in Bitcoin Core" visible while editing fields
              // in the content pane. Bold is the focused-only cue.
              final prefix = isActive ? '> ' : '  ';
              final color = focused
                  ? (isActive ? accent : idle)
                  : (isActive ? idle : dim);
              return Tappable(
                onTap: () {
                  // Tap = select + focus content. Same as Enter.
                  context.read(selectedServiceIndexProvider.notifier).state = i;
                  context.read(_selectedOptionProvider.notifier).state = 0;
                  context.read(configureFocusedColumnProvider.notifier).state =
                      ConfigureColumn.content;
                },
                child: Text(
                  '$prefix${truncateSidebarLabel(entries[i].label)}',
                  style: TextStyle(
                    color: color,
                    fontWeight: isActive && focused
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              );
            }(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ConfigureContentScroll — vertical scroll wrapper for the content pane
//
// Owns a [ScrollController] and listens for changes to the
// `_selectedOptionProvider`; calls `ensureVisible` on the
// estimated row offset so the active option stays in the viewport
// as the operator walks the list. Wheel events route into the
// same controller for touch / desktop-mouse scroll.
//
// Row-height estimate: every option row is 1 row tall (the editor
// renders `label: [value]` on one line). Plugin catalog rows in
// compact mode are also 1 row (description hidden) + 1 spacer.
// Header offset before the rows is 0 — the content pane has no
// status panel like System → Check does.
// ---------------------------------------------------------------------------

class _ConfigureContentScroll extends StatefulComponent {
  final int selectedOption;
  final Component child;

  const _ConfigureContentScroll({
    required this.selectedOption,
    required this.child,
  });

  @override
  State<_ConfigureContentScroll> createState() =>
      _ConfigureContentScrollState();
}

class _ConfigureContentScrollState extends State<_ConfigureContentScroll> {
  final ScrollController _scroll = ScrollController();
  int? _lastSelected;

  // Per-row estimate: 1 row of label + 1 row spacer (the plugin
  // catalog renders Column children with a SizedBox(height: 1)
  // between rows; manifest fields don't have the spacer but the
  // wider gap is fine — over-estimation just makes ensureVisible
  // scroll a hair more aggressively).
  static const int _rowsPerOption = 2;

  void _maybeScrollToSelected() {
    if (_lastSelected == component.selectedOption) return;
    _lastSelected = component.selectedOption;
    final offset = component.selectedOption * _rowsPerOption;
    Future.microtask(() {
      if (!mounted) return;
      _scroll.ensureVisible(itemOffset: offset.toDouble(), itemExtent: 1);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    _maybeScrollToSelected();
    return MouseRegion(
      onHover: (event) {
        if (event.button == MouseButton.wheelUp) {
          _scroll.scrollUp();
        } else if (event.button == MouseButton.wheelDown) {
          _scroll.scrollDown();
        }
      },
      child: SingleChildScrollView(controller: _scroll, child: component.child),
    );
  }
}

// ---------------------------------------------------------------------------
// _CompactBackHeader — single-pane content header for compact mode
//
// In compact / mobile layout the sidebar and content are mutually
// exclusive (only one is on-screen at a time). When the content is
// showing, this header pins the section name + a `← back` glyph so
// the operator knows Esc / tap-back returns to the sidebar.
// Pure visual today; the Tappable wiring lands in a follow-up.
// ---------------------------------------------------------------------------

class _CompactBackHeader extends StatelessComponent {
  final String label;
  const _CompactBackHeader({required this.label});

  @override
  Component build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      decoration: const BoxDecoration(
        border: BoxBorder(bottom: BorderSide(color: Color.fromRGB(50, 50, 70))),
      ),
      child: Tappable(
        // Tap = back to the section sidebar. Same as Esc.
        onTap: () =>
            context.read(configureFocusedColumnProvider.notifier).state =
                ConfigureColumn.sidebar,
        child: Text(
          '◀ $label',
          style: const TextStyle(
            color: Color.fromRGB(180, 180, 200),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SystemTextOverlay
//
// Inline text-edit overlay for the System block's hostname and timezone
// fields. Self-contained Focusable; parent renders this as an early-return
// takeover (mirrors the PasswordInput pattern) when
// _editingSystemFieldProvider is non-null.
// ---------------------------------------------------------------------------

/// Confirm takeover for removing an installed plugin via the "Remove
/// plugin" action row.
/// Mirrors the `nixblitz plugin remove` CLI: the hard-delete + plugins.list
/// regen happen immediately on confirm, but the node only changes on the
/// next Apply (where the plugin's teardown also runs). Modal: swallows all
/// keys except y / n / Esc.
class _PluginRemoveConfirmView extends StatefulComponent {
  final String pluginId;
  final String pluginName;
  final PluginService pluginService;
  final VoidCallback onConfirmed;
  final VoidCallback onCancel;

  const _PluginRemoveConfirmView({
    required this.pluginId,
    required this.pluginName,
    required this.pluginService,
    required this.onConfirmed,
    required this.onCancel,
  });

  @override
  State<_PluginRemoveConfirmView> createState() =>
      _PluginRemoveConfirmViewState();
}

class _PluginRemoveConfirmViewState extends State<_PluginRemoveConfirmView> {
  // Guard against a double-trigger; a plain instance var, not a provider
  // (nocterm pitfall #1 — provider sets mid-handler discard the stack).
  bool _working = false;

  @override
  Component build(BuildContext context) {
    final comp = component;
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyY) {
            if (_working) return true;
            _working = true;
            // remove() has no awaits — its body (deleteSync + plugins.list
            // regen) runs synchronously on call, so the deletion is done
            // before onConfirmed() refreshes the list. catchError logs the
            // rare filesystem failure without blocking the UI.
            comp.pluginService.remove(comp.pluginId).catchError((
              Object e,
              StackTrace st,
            ) {
              LogService.error(
                'configure: remove ${comp.pluginId} failed',
                e,
                st,
              );
            });
            comp.onConfirmed();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyN ||
              event.logicalKey == LogicalKey.escape) {
            comp.onCancel();
            return true;
          }
          // Modal — swallow every other key.
          return true;
        } catch (e, st) {
          LogService.error('Remove confirm key handler failed', e, st);
          return true;
        }
      },
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            border: BoxBorder.all(color: const Color.fromRGB(247, 147, 26)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Remove ${comp.pluginName}?',
                style: const TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              const Text(
                "This stages the removal. The plugin's service keeps running\n"
                'until you apply — it is only gone from the node after the\n'
                'next Apply (which runs its teardown first).',
                style: TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
              const SizedBox(height: 1),
              const Text(
                '[y] Remove    [n / Esc] Cancel',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemTextOverlay extends StatefulComponent {
  final String label;
  final String initialValue;
  final void Function(String) onSubmit;
  final VoidCallback onCancel;

  const _SystemTextOverlay({
    required this.label,
    required this.initialValue,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<_SystemTextOverlay> createState() => _SystemTextOverlayState();
}

class _SystemTextOverlayState extends State<_SystemTextOverlay> {
  late String _buffer;

  @override
  void initState() {
    super.initState();
    _buffer = component.initialValue;
  }

  @override
  Component build(BuildContext context) {
    final comp = component;
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            comp.onCancel();
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            comp.onSubmit(_buffer);
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            if (_buffer.isNotEmpty) {
              setState(
                () => _buffer = _buffer.substring(0, _buffer.length - 1),
              );
            }
            return true;
          }
          // Paste — single-line hostname / timezone; strip
          // whitespace since neither field permits embedded spaces
          // or newlines.
          if (event.logicalKey == LogicalKey.keyV && event.modifiers.ctrl) {
            final pasted = ClipboardManager.paste();
            if (pasted != null && pasted.isNotEmpty) {
              setState(() => _buffer += pasted.replaceAll(RegExp(r'\s+'), ''));
            }
            return true;
          }
          final ch = event.character;
          if (ch != null && ch.length == 1) {
            final code = ch.codeUnitAt(0);
            if (code >= 0x20 && code <= 0x7E) {
              setState(() => _buffer += ch);
            }
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('System text overlay key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit: ${comp.label}',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            TextOptionEditor(
              label: comp.label,
              value: '${_buffer}_',
              focused: true,
            ),
            const SizedBox(height: 1),
            const Text(
              'Enter to save, Esc to cancel.',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}
