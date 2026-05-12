import 'dart:convert';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/option_editor.dart';
import '../widgets/password_input.dart';
import '../../providers/ui_state_provider.dart';
import '../layout.dart';
import 'configure/field_editor.dart';
import 'configure/plugin_catalog.dart';
import 'plugin_install_view.dart';

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

    // ── Main view ────────────────────────────────────────────────────
    final configAsync = context.watch(configProvider);
    final serviceIndex = context.watch(selectedServiceIndexProvider);
    final selectedOption = context.watch(_selectedOptionProvider);
    final statusMessage = context.watch(_statusMessageProvider);
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
        // System / Manifest entries: options.length. Plugins: catalog
        // entries not yet installed + 1 (the "Install from URL…" row).
        // _buildOptions returns an empty list for Plugins because its
        // body is rendered separately via _buildPluginsContent.
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
        } else {
          contentRowCount = options.length;
        }

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
              // _handleEnter); refresh/remove live in System → Apply
              // and the `nixblitz plugin` CLI respectively.

              // Esc: content → sidebar, sidebar → dashboard. The
              // arrow keys (`←/→/h/l`) are reserved for the top
              // menu and intentionally bubble past this handler.
              if (event.logicalKey == LogicalKey.escape) {
                if (focusedColumn == ConfigureColumn.content) {
                  context.read(configureFocusedColumnProvider.notifier).state =
                      ConfigureColumn.sidebar;
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
                      focused: focusedColumn == ConfigureColumn.sidebar,
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
                            color: focusedColumn == ConfigureColumn.content
                                ? const Color.fromRGB(140, 140, 180)
                                : const Color.fromRGB(50, 50, 70),
                          ),
                        ),
                        child: currentEntry is _PluginsEntry
                            ? _buildPluginsContent(
                                context,
                                selectedOption,
                                focusedColumn == ConfigureColumn.content,
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
    final installed = context
        .watch(installedPluginsProvider)
        .map((m) => m.id)
        .toSet();
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

    final children = <Component>[
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
              final showCursor = isActive && focused;
              final prefix = showCursor ? '> ' : '  ';
              final color = focused ? (isActive ? accent : idle) : dim;
              return Text(
                '$prefix${truncateSidebarLabel(entries[i].label)}',
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
