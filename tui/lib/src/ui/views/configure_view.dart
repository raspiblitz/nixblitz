import 'dart:convert';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/option_editor.dart';
import '../widgets/password_input.dart';
import '../../providers/ui_state_provider.dart';
import 'configure/field_editor.dart';
import 'plugin_config_view.dart';
import 'plugin_install_view.dart';
import 'plugin_refresh_all_view.dart';
import 'plugin_refresh_view.dart';

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

/// When non-null, the Configure view delegates to [PluginConfigView]
/// for the plugin with this `dirName`. `null` means the main tabbed
/// view is showing.
final _editingPluginDirNameProvider = StateProvider<String?>((ref) => null);

/// When true, the Configure view delegates to [PluginInstallView] —
/// the consent-driven install wizard. Toggled by `i` on the Plugins
/// tab and reset when the install view dismisses.
final _installingPluginProvider = StateProvider<bool>((ref) => false);

/// Non-null while the Configure view is delegating to [PluginRefreshView]
/// for the named plugin id. Set by `r` on the Plugins tab and reset
/// when the refresh view dismisses.
final _refreshingPluginProvider = StateProvider<String?>((ref) => null);

/// True while the Configure view is delegating to [PluginRefreshAllView]
/// (the bulk refresh flow). Toggled by `R` (shift-r) on the Plugins
/// tab and reset when the refresh-all view dismisses.
final _refreshingAllPluginsProvider = StateProvider<bool>((ref) => false);

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
enum _ConfigureColumn { sidebar, content }

final _focusedColumnProvider = StateProvider<_ConfigureColumn>(
  (ref) => _ConfigureColumn.sidebar,
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
      return PluginInstallView(
        pluginService: context.read(pluginServiceProvider),
        onDismiss: () =>
            context.read(_installingPluginProvider.notifier).state = false,
      );
    }

    // ── Plugin refresh takeover ──────────────────────────────────────
    final refreshingPluginId = context.watch(_refreshingPluginProvider);
    if (refreshingPluginId != null) {
      return PluginRefreshView(
        pluginService: context.read(pluginServiceProvider),
        pluginId: refreshingPluginId,
        onDismiss: () =>
            context.read(_refreshingPluginProvider.notifier).state = null,
      );
    }

    // ── Plugin refresh-all takeover ──────────────────────────────────
    final refreshingAll = context.watch(_refreshingAllPluginsProvider);
    if (refreshingAll) {
      return PluginRefreshAllView(
        pluginService: context.read(pluginServiceProvider),
        onDismiss: () =>
            context.read(_refreshingAllPluginsProvider.notifier).state = false,
      );
    }

    // ── Main view ────────────────────────────────────────────────────
    final configAsync = context.watch(configProvider);
    final serviceIndex = context.watch(selectedServiceIndexProvider);
    final selectedOption = context.watch(_selectedOptionProvider);
    final statusMessage = context.watch(_statusMessageProvider);
    final editingPluginDir = context.watch(_editingPluginDirNameProvider);
    final editingField = context.watch(_editingFieldProvider);
    // Yield focus while a modal popup is up — sudo / help.
    final modalActive = context.watch(modalActiveProvider);
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
        // If the editingPluginDir references a plugin that's been
        // uninstalled out-of-band, clear the stale id so the
        // Plugins section's right pane falls back to preview mode.
        if (editingPluginDir != null) {
          final manifests = context.watch(installedPluginsProvider);
          final stillThere = manifests.any((m) => m.id == editingPluginDir);
          if (!stillThere) {
            context.read(_editingPluginDirNameProvider.notifier).state = null;
          }
        }

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
        final options = _buildOptions(
          context,
          config,
          currentEntry,
          selectedOption,
          pendingKeys: pendingKeys,
        );
        final focusedColumn = context.watch(_focusedColumnProvider);
        // Width = widest label
        //       + 2 ("> " cursor prefix)
        //       + 4 (EdgeInsets.symmetric horizontal: 2 each side)
        //       + 2 (border deflate — nocterm's DecoratedBox does
        //            constraints.deflate(EdgeInsets.all(1)) for ANY
        //            non-empty border, so a right-only BorderSide
        //            still costs one column on the left as well).
        final sidebarWidth =
            menuEntries.map((e) => e.label.length).fold<int>(8, _max) + 8;

        return Focusable(
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
                if (focusedColumn == _ConfigureColumn.sidebar) {
                  if (serviceIndex < menuEntries.length - 1) {
                    context.read(selectedServiceIndexProvider.notifier).state =
                        serviceIndex + 1;
                    context.read(_selectedOptionProvider.notifier).state = 0;
                  }
                } else {
                  final max = options.length - 1;
                  if (selectedOption < max) {
                    context.read(_selectedOptionProvider.notifier).state =
                        selectedOption + 1;
                  }
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyK ||
                  event.logicalKey == LogicalKey.arrowUp) {
                if (focusedColumn == _ConfigureColumn.sidebar) {
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
                if (focusedColumn == _ConfigureColumn.sidebar) {
                  context.read(_focusedColumnProvider.notifier).state =
                      _ConfigureColumn.content;
                } else {
                  _handleEnter(context, config, currentEntry, selectedOption);
                }
                return true;
              }

              // [i] on the Plugins section opens the install wizard.
              // Gated to content focus + _PluginsEntry so it doesn't
              // shadow other intents.
              if (event.logicalKey == LogicalKey.keyI &&
                  currentEntry is _PluginsEntry &&
                  focusedColumn == _ConfigureColumn.content) {
                context.read(_installingPluginProvider.notifier).state = true;
                return true;
              }
              // [r] / [R] on the Plugins section — refresh single / all.
              // Distinguishing case: shift-r (capital R) is bulk;
              // plain r refreshes only the highlighted row.
              if (event.logicalKey == LogicalKey.keyR &&
                  currentEntry is _PluginsEntry &&
                  focusedColumn == _ConfigureColumn.content) {
                final shifted = event.character == 'R';
                if (shifted) {
                  context.read(_refreshingAllPluginsProvider.notifier).state =
                      true;
                } else {
                  final manifests = context.read(installedPluginsProvider);
                  if (selectedOption < manifests.length) {
                    context.read(_refreshingPluginProvider.notifier).state =
                        manifests[selectedOption].id;
                  }
                }
                return true;
              }

              // Esc: content → sidebar, sidebar → dashboard. The
              // arrow keys (`←/→/h/l`) are reserved for the top
              // menu and intentionally bubble past this handler.
              if (event.logicalKey == LogicalKey.escape) {
                if (focusedColumn == _ConfigureColumn.content) {
                  context.read(_focusedColumnProvider.notifier).state =
                      _ConfigureColumn.sidebar;
                } else {
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ConfigureSidebar(
                      entries: menuEntries,
                      selectedIndex: serviceIndex.clamp(
                        0,
                        menuEntries.length - 1,
                      ),
                      focused: focusedColumn == _ConfigureColumn.sidebar,
                      width: sidebarWidth,
                    ),
                    Expanded(
                      child: Container(
                        // Right pane gets its own full-rectangle border
                        // so focus is conveyed via border color (same
                        // idiom as the sidebar). Adjacent sidebar+content
                        // borders sit side-by-side at the seam — slight
                        // visual heaviness but unambiguous: whichever
                        // rectangle glows is where j/k goes.
                        decoration: BoxDecoration(
                          border: BoxBorder.all(
                            color: focusedColumn == _ConfigureColumn.content
                                ? const Color.fromRGB(140, 140, 180)
                                : const Color.fromRGB(50, 50, 70),
                          ),
                        ),
                        child: currentEntry is _PluginsEntry
                            ? _buildPluginsContent(
                                context,
                                selectedOption,
                                editingPluginDir,
                              )
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: options,
                                ),
                              ),
                      ),
                    ),
                  ],
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

    // Plugins tab: drill into selected plugin's config form.
    // installedPluginsProvider sorts by id, so the index here matches
    // the row order rendered by `_buildPluginsOptions`. The header row
    // it draws is purely visual — selectedOption indexes the data list,
    // not the rendered widget list.
    if (currentEntry is _PluginsEntry) {
      final manifests = context.read(installedPluginsProvider);
      if (selectedOption < manifests.length) {
        context.read(_editingPluginDirNameProvider.notifier).state =
            manifests[selectedOption].id;
      }
      return;
    }

    // Manifest entry: generic field dispatch.
    if (currentEntry is _ManifestEntry) {
      final manifest = currentEntry.manifest;
      if (selectedOption >= manifest.fields.length) return;
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

  /// Handle Enter for the System tab (typed block — hostname, timezone,
  /// platform, shell, password).
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
        const platforms = ['pi5', 'x86', 'vm'];
        final next =
            (platforms.indexOf(config.system.platform) + 1) % platforms.length;
        final updated = config.copyWith(
          system: config.system.copyWith(platform: platforms[next]),
        );
        context.read(configProvider.notifier).updateConfig(updated);
      case 3:
        const shells = ['bash', 'nushell'];
        final next = (shells.indexOf(config.system.shell) + 1) % shells.length;
        final updated = config.copyWith(
          system: config.system.copyWith(shell: shells[next]),
        );
        context.read(configProvider.notifier).updateConfig(updated);
      case 4:
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
      _SystemEntry() => _buildSystemOptions(config, selectedIndex, isPending),
      _ManifestEntry(:final manifest) => _buildManifestOptions(
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
    NixblitzConfig config,
    int selectedIndex,
    bool Function(String) isPending,
  ) {
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
        label: 'platform',
        value: config.system.platform,
        options: const ['pi5', 'x86', 'vm'],
        focused: selectedIndex == 2,
        pending: isPending('system.platform'),
      ),
      SelectOptionEditor(
        label: 'shell',
        value: config.system.shell,
        options: const ['bash', 'nushell'],
        focused: selectedIndex == 3,
        pending: isPending('system.shell'),
      ),
      TextOptionEditor(
        label: 'password',
        value: 'Press Enter to change',
        focused: selectedIndex == 4,
        // No pending marker — password is not a config field.
      ),
    ];
  }

  // ---------- Generic manifest walker ----------

  List<Component> _buildManifestOptions(
    NixblitzConfig config,
    AppManifest manifest,
    int selectedIndex,
    bool Function(String) isPending,
  ) {
    final appConfig = config.appConfig(manifest.id);
    return [
      for (var i = 0; i < manifest.fields.length; i++)
        FieldDisplayRow(
          field: manifest.fields[i],
          currentValue: appConfig[manifest.fields[i].name],
          selected: selectedIndex == i,
          pending: isPending('${manifest.id}.${manifest.fields[i].name}'),
        ),
    ];
  }

  // ---------- Plugins (two-column inline layout) ----------

  /// Right-pane renderer for the Plugins section. Splits the
  /// available width into:
  ///
  ///   [plugin name list]  │  [config preview / inline form]
  ///
  /// The name list is always visible. The right subcolumn shows a
  /// read-only preview of the highlighted plugin's config while
  /// [editingPluginDir] is null; once the operator hits Enter the
  /// provider is set and the right subcolumn swaps in the full
  /// [PluginConfigView] (which owns its own Focusable + key
  /// handling). Dismissing the form clears the provider and the
  /// preview returns.
  Component _buildPluginsContent(
    BuildContext context,
    int selectedIndex,
    String? editingPluginDir,
  ) {
    final manifests = context.watch(installedPluginsProvider);
    if (manifests.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '(no plugins installed)',
              style: TextStyle(color: Color.fromRGB(150, 150, 170)),
            ),
            SizedBox(height: 1),
            Text(
              '[i] install',
              style: TextStyle(color: Color.fromRGB(140, 140, 150)),
            ),
          ],
        ),
      );
    }

    final clamped = selectedIndex.clamp(0, manifests.length - 1);
    final selected = manifests[clamped];

    // Widest plugin name + 2 ("> " cursor prefix)
    //                    + 4 (EdgeInsets.symmetric horizontal: 2 each side)
    //                    + 2 (nocterm border deflate — see the
    //                         outer sidebar's width comment).
    final nameColWidth =
        manifests.map((m) => m.name.length).fold<int>(8, _max) + 8;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: nameColWidth.toDouble(),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
          // Plugin list = its own bordered pane inside the Plugins
          // section's right column. Idle color — the OUTER content
          // pane's border is the one that intensifies on focus,
          // so we don't double-light the seam here.
          decoration: const BoxDecoration(
            border: BoxBorder(
              top: BorderSide(color: Color.fromRGB(50, 50, 70)),
              right: BorderSide(color: Color.fromRGB(50, 50, 70)),
              bottom: BorderSide(color: Color.fromRGB(50, 50, 70)),
              left: BorderSide(color: Color.fromRGB(50, 50, 70)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < manifests.length; i++)
                Text(
                  '${i == clamped ? "> " : "  "}${manifests[i].name}',
                  style: TextStyle(
                    color: i == clamped
                        ? const Color.fromRGB(247, 147, 26)
                        : const Color.fromRGB(150, 150, 180),
                    fontWeight: i == clamped
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              const SizedBox(height: 1),
              const Text(
                '[i] install',
                style: TextStyle(color: Color.fromRGB(120, 120, 140)),
              ),
            ],
          ),
        ),
        Expanded(
          child: editingPluginDir != null
              ? PluginConfigView(
                  // Keyed on the plugin id so swapping plugins
                  // resets internal state (selected row, editing
                  // overlay…) instead of leaking it across plugins.
                  key: ValueKey('plugin-config-$editingPluginDir'),
                  pluginId: editingPluginDir,
                  onDismiss: () =>
                      context
                              .read(_editingPluginDirNameProvider.notifier)
                              .state =
                          null,
                )
              : _buildPluginPreview(context, selected),
        ),
      ],
    );
  }

  /// Read-only preview of [manifest]'s current config. Rendered in
  /// the right subcolumn when no plugin form is active. Mirrors the
  /// label/value layout of the full form so the operator can scan
  /// values before drilling in.
  Component _buildPluginPreview(BuildContext context, PluginManifest manifest) {
    final config = context.watch(configProvider).value;
    final appCfg = config?.appConfig(manifest.id) ?? const {};
    final fields = manifest.configSchema?.fields ?? const [];

    final baseDir = context.read(baseDirProvider);
    final marker = readMarker('$baseDir/plugins/${manifest.id}');
    final cfgEnabled = config?.isAppEnabled(manifest.id) ?? false;
    final statusLabel = pluginStatusLabel(
      marker: marker,
      cfgEnabled: cfgEnabled,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            manifest.name,
            style: const TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          if (manifest.description.isNotEmpty)
            Text(
              manifest.description,
              style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
            ),
          Text(
            'status: $statusLabel',
            style: const TextStyle(color: Color.fromRGB(140, 140, 150)),
          ),
          const SizedBox(height: 1),
          if (fields.isEmpty)
            const Text(
              '(no configurable fields)',
              style: TextStyle(color: Color.fromRGB(150, 150, 170)),
            )
          else
            for (final f in fields)
              Text(
                '${f.label}: ${appCfg[f.name] ?? "(default)"}',
                style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
          const SizedBox(height: 1),
          const Text(
            '[Enter] edit',
            style: TextStyle(color: Color.fromRGB(120, 120, 140)),
          ),
        ],
      ),
    );
  }

  static int _max(int a, int b) => a > b ? a : b;
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

class _ConfigureSidebar extends StatelessComponent {
  final List<_MenuEntry> entries;
  final int selectedIndex;
  final bool focused;
  final int width;

  const _ConfigureSidebar({
    required this.entries,
    required this.selectedIndex,
    required this.focused,
    required this.width,
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
      width: width.toDouble(),
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
              final showCursor = isActive && focused;
              final prefix = showCursor ? '> ' : '  ';
              final color = focused ? (isActive ? accent : idle) : dim;
              return Text(
                '$prefix${entries[i].label}',
                style: TextStyle(
                  color: color,
                  fontWeight: showCursor ? FontWeight.bold : FontWeight.normal,
                ),
              );
            }(),
        ],
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
