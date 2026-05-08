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

    // ── Main view ────────────────────────────────────────────────────
    final configAsync = context.watch(configProvider);
    final serviceIndex = context.watch(selectedServiceIndexProvider);
    final selectedOption = context.watch(_selectedOptionProvider);
    final statusMessage = context.watch(_statusMessageProvider);
    final editingPluginDir = context.watch(_editingPluginDirNameProvider);
    final editingField = context.watch(_editingFieldProvider);
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
        // Plugin form takes over the whole view when the user has
        // drilled into one — bypasses the tab grid key handling.
        if (editingPluginDir != null) {
          // The drilled-in plugin is identified by its id; look up the
          // manifest from installedPluginsProvider. If it's gone (the
          // operator removed it in a parallel session), drop the
          // selection and fall back to the tab grid below.
          final manifests = context.watch(installedPluginsProvider);
          final manifest = manifests
              .where((m) => m.id == editingPluginDir)
              .firstOrNull;
          if (manifest == null) {
            // Stale selection (plugin removed in a race). Drop it.
            context.read(_editingPluginDirNameProvider.notifier).state = null;
          } else {
            return PluginConfigView(
              pluginId: manifest.id,
              onDismiss: () =>
                  context.read(_editingPluginDirNameProvider.notifier).state =
                      null,
            );
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

        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            try {
              // Clear status message on any key press.
              if (statusMessage.isNotEmpty) {
                context.read(_statusMessageProvider.notifier).state = '';
              }

              if (event.logicalKey == LogicalKey.keyJ ||
                  event.logicalKey == LogicalKey.arrowDown) {
                final max = options.length - 1;
                if (selectedOption < max) {
                  context.read(_selectedOptionProvider.notifier).state =
                      selectedOption + 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyK ||
                  event.logicalKey == LogicalKey.arrowUp) {
                if (selectedOption > 0) {
                  context.read(_selectedOptionProvider.notifier).state =
                      selectedOption - 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyH ||
                  event.logicalKey == LogicalKey.arrowLeft) {
                if (serviceIndex > 0) {
                  context.read(selectedServiceIndexProvider.notifier).state =
                      serviceIndex - 1;
                  context.read(_selectedOptionProvider.notifier).state = 0;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyL ||
                  event.logicalKey == LogicalKey.arrowRight) {
                if (serviceIndex < menuEntries.length - 1) {
                  context.read(selectedServiceIndexProvider.notifier).state =
                      serviceIndex + 1;
                  context.read(_selectedOptionProvider.notifier).state = 0;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.enter ||
                  event.logicalKey == LogicalKey.space) {
                _handleEnter(context, config, currentEntry, selectedOption);
                return true;
              }
              // [i] on the Plugins tab opens the install wizard.
              // Gated to _PluginsEntry so it doesn't shadow text-edit
              // intent on other tabs.
              if (event.logicalKey == LogicalKey.keyI &&
                  currentEntry is _PluginsEntry) {
                context.read(_installingPluginProvider.notifier).state = true;
                return true;
              }
              // [r] on the Plugins tab refreshes the highlighted plugin
              // (clones HEAD, compares signature, advances pin or hard-fails
              // on key rotation). Same gate as [i] — Plugins tab only.
              if (event.logicalKey == LogicalKey.keyR &&
                  currentEntry is _PluginsEntry) {
                final manifests = context.read(installedPluginsProvider);
                if (selectedOption < manifests.length) {
                  context.read(_refreshingPluginProvider.notifier).state =
                      manifests[selectedOption].id;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.escape) {
                context.read(currentViewProvider.notifier).state =
                    AppView.dashboard;
                return true;
              }
              return false;
            } catch (e, st) {
              LogService.error('Configure view key handler failed', e, st);
              return true;
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Row(
                  children: [
                    Text(
                      'Configure: ',
                      style: const TextStyle(
                        color: Color.fromRGB(247, 147, 26),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    // Service tabs (manifest-driven)
                    ...List.generate(menuEntries.length, (i) {
                      final isActive = i == serviceIndex;
                      return Row(
                        children: [
                          Text(
                            menuEntries[i].label,
                            style: TextStyle(
                              color: isActive
                                  ? const Color.fromRGB(247, 147, 26)
                                  : const Color.fromRGB(120, 120, 140),
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          if (i < menuEntries.length - 1)
                            Text(
                              ' | ',
                              style: const TextStyle(
                                color: Color.fromRGB(80, 80, 100),
                              ),
                            ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 1),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: options,
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
      _PluginsEntry() => _buildPluginsOptions(ctx, selectedIndex),
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

  // ---------- Plugins ----------

  List<Component> _buildPluginsOptions(
    BuildContext context,
    int selectedIndex,
  ) {
    const dim = Color.fromRGB(140, 140, 150);
    const hintRow = Text(
      '[i] install new   [r] refresh selected   [Enter] configure selected',
      style: TextStyle(color: dim),
    );

    final manifests = context.watch(installedPluginsProvider);
    if (manifests.isEmpty) {
      return const [
        Text(
          '(no plugins installed)',
          style: TextStyle(color: Color.fromRGB(150, 150, 170)),
        ),
        SizedBox(height: 1),
        hintRow,
      ];
    }

    // Join each manifest with its on-disk marker so the operator
    // sees branch / rev / status at a glance. The markers live at
    // <baseDir>/plugins/<id>/.nixblitz-installed.json — fs read is
    // synchronous + cheap, fine for a render-time call.
    final baseDir = context.read(baseDirProvider);
    final pluginsRoot = '$baseDir/plugins';
    final markers = {
      for (final m in manifests) m.id: readMarker('$pluginsRoot/${m.id}'),
    };

    // Resolved config — used to surface the operator's per-plugin
    // `app_configs[id].enabled` toggle in the STATUS column. Distinct
    // from `marker.disabled` (which controls plugins.list inclusion):
    // a plugin can be in plugins.list (NixOS evaluates its module)
    // but have `enabled: false`, in which case the module shouldn't
    // start its service.
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;

    // Compute column widths from the actual data.
    final idWidth = manifests.map((m) => m.id.length).fold<int>(6, _max);
    final branchWidth = markers.values
        .map((m) => (m?.branch ?? '').length)
        .fold<int>(6, _max);

    const focusedColor = Color.fromRGB(247, 147, 26);
    const normal = Color.fromRGB(200, 200, 200);

    final rows = <Component>[
      Text(
        '  ${'PLUGIN'.padRight(idWidth)}  ${'BRANCH'.padRight(branchWidth)}  REV       STATUS',
        style: const TextStyle(color: dim),
      ),
    ];

    for (var i = 0; i < manifests.length; i++) {
      final m = manifests[i];
      final marker = markers[m.id];
      final focused = selectedIndex == i;

      final id = m.id.padRight(idWidth);
      final branch = (marker?.branch ?? '?').padRight(branchWidth);
      final rev = marker == null
          ? '?       '
          : (marker.rev.length >= 8
                ? marker.rev.substring(0, 8)
                : marker.rev.padRight(8));

      // STATUS surfaces three independent operator-visible bits:
      //   - marker present? (system-level: plugin is registered)
      //   - marker.disabled? (operator excluded it from plugins.list)
      //   - app_configs[id].enabled? (the plugin's own start/stop gate)
      //
      // See [pluginStatusLabel] for the resolution rules.
      final cfgEnabled = config?.isAppEnabled(m.id) ?? false;
      final status = pluginStatusLabel(marker: marker, cfgEnabled: cfgEnabled);

      rows.add(
        Text(
          '${focused ? "> " : "  "}$id  $branch  $rev  $status',
          style: TextStyle(color: focused ? focusedColor : normal),
        ),
      );
    }

    rows.add(const SizedBox(height: 1));
    rows.add(hintRow);

    return rows;
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
