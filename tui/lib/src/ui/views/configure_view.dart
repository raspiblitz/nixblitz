import 'dart:convert';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/option_editor.dart';
import '../widgets/password_input.dart';
import '../../providers/ui_state_provider.dart';
import 'plugin_config_view.dart';

final _selectedOptionProvider = StateProvider<int>((ref) => 0);
final _changingPasswordProvider = StateProvider<bool>((ref) => false);
final _statusMessageProvider = StateProvider<String>((ref) => '');

/// When non-null, the Configure view delegates to [PluginConfigView]
/// for the plugin with this `dirName`. `null` means the main tabbed
/// view is showing.
final _editingPluginDirNameProvider =
    StateProvider<String?>((ref) => null);

class ConfigureView extends StatelessComponent {
  const ConfigureView({super.key});

  @override
  Component build(BuildContext context) {
    final changingPassword = context.watch(_changingPasswordProvider);

    if (changingPassword) {
      return PasswordInput(
        title: 'Change Admin Password',
        subtitle: 'Enter a new password for the admin user.',
        minLength: 8,
        requireConfirmation: true,
        onSubmit: (password) {
          // sudo timestamp is already fresh (we ran ensureFresh before
          // entering this view), so chpasswd runs silently.
          final session = context.read(sudoSessionProvider);
          final stdin =
              Uint8List.fromList(utf8.encode('admin:$password\n'));
          session
              .runOneShot(['chpasswd'], stdinBytes: stdin)
              .then((res) {
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
            context.read(_changingPasswordProvider.notifier).state =
                false;
          });
        },
        onCancel: () {
          context.read(_changingPasswordProvider.notifier).state = false;
        },
      );
    }

    final configAsync = context.watch(configProvider);
    final serviceIndex = context.watch(selectedServiceIndexProvider);
    final selectedOption = context.watch(_selectedOptionProvider);
    final statusMessage = context.watch(_statusMessageProvider);
    final editingPluginDir = context.watch(_editingPluginDirNameProvider);

    return configAsync.when(
      loading: () => const Center(child: Text('Loading...')),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (config) {
        // Plugin form takes over the whole view when the user has
        // drilled into one — bypasses the tab grid key handling.
        if (editingPluginDir != null) {
          final entry = config.plugins
              .where((p) => p.dirName == editingPluginDir &&
                  p.uninstalledAt == null)
              .firstOrNull;
          if (entry == null) {
            // Stale selection (plugin removed in a race). Drop it.
            context.read(_editingPluginDirNameProvider.notifier).state = null;
          } else {
            return PluginConfigView(
              entry: entry,
              onDismiss: () => context
                  .read(_editingPluginDirNameProvider.notifier)
                  .state = null,
            );
          }
        }

        final services = [
          'system',
          'bitcoind',
          'lnd',
          'cln',
          'blitz-api',
          'blitz-web',
          'plugins',
        ];
        final currentService = services[serviceIndex];
        final options = _buildOptions(
          config,
          currentService,
          selectedOption,
        );

        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            try {
              // Clear status message on any key press
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
                if (serviceIndex < services.length - 1) {
                  context.read(selectedServiceIndexProvider.notifier).state =
                      serviceIndex + 1;
                  context.read(_selectedOptionProvider.notifier).state = 0;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.enter ||
                  event.logicalKey == LogicalKey.space) {
                // Password change is a special action, not a config toggle.
                // Authenticate sudo first so chpasswd later runs silently.
                if (currentService == 'system' && selectedOption == 3) {
                  final session = context.read(sudoSessionProvider);
                  session.ensureFresh().then((ok) {
                    if (ok) {
                      context
                          .read(_changingPasswordProvider.notifier)
                          .state = true;
                    } else {
                      context.read(_statusMessageProvider.notifier).state =
                          'sudo authorization required to change password.';
                    }
                  });
                  return true;
                }
                // Plugins tab: Enter drills into the selected plugin's
                // per-plugin config form.
                if (currentService == 'plugins') {
                  final active = config.plugins
                      .where((p) => p.uninstalledAt == null)
                      .toList();
                  if (selectedOption < active.length) {
                    context
                            .read(_editingPluginDirNameProvider.notifier)
                            .state =
                        active[selectedOption].dirName;
                  }
                  return true;
                }
                final updated = _toggleOption(
                  config,
                  currentService,
                  selectedOption,
                );
                if (updated != null) {
                  context.read(configProvider.notifier).updateConfig(updated);
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
                    // Service tabs
                    ...List.generate(services.length, (i) {
                      final isActive = i == serviceIndex;
                      return Row(
                        children: [
                          Text(
                            services[i],
                            style: TextStyle(
                              color: isActive
                                  ? const Color.fromRGB(247, 147, 26)
                                  : const Color.fromRGB(120, 120, 140),
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          if (i < services.length - 1)
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

  /// Toggle a bool or cycle a select option. Returns updated config, or null if not editable.
  NixblitzConfig? _toggleOption(
    NixblitzConfig config,
    String service,
    int optionIndex,
  ) {
    switch (service) {
      case 'bitcoind':
        switch (optionIndex) {
          case 0:
            return config.copyWith(
              bitcoind: config.bitcoind.copyWith(
                enabled: !config.bitcoind.enabled,
              ),
            );
          case 1:
            const networks = ['mainnet', 'regtest'];
            final next =
                (networks.indexOf(config.bitcoind.network) + 1) %
                networks.length;
            return config.copyWith(
              bitcoind: config.bitcoind.copyWith(network: networks[next]),
            );
          case 2:
            return config.copyWith(
              bitcoind: config.bitcoind.copyWith(
                pruned: !config.bitcoind.pruned,
              ),
            );
          // prune size (index 3) needs text input, skip for now
        }
      case 'lnd':
        switch (optionIndex) {
          case 0:
            return config.copyWith(
              lnd: config.lnd.copyWith(enabled: !config.lnd.enabled),
            );
          // alias (index 1) needs text input, skip for now
        }
      case 'cln':
        if (optionIndex == 0) {
          return config.copyWith(
            cln: config.cln.copyWith(enabled: !config.cln.enabled),
          );
        }
      case 'blitz-api':
        if (optionIndex == 0) {
          return config.copyWith(
            blitzApi: config.blitzApi.copyWith(
              enabled: !config.blitzApi.enabled,
            ),
          );
        }
      case 'blitz-web':
        if (optionIndex == 0) {
          return config.copyWith(
            blitzWeb: config.blitzWeb.copyWith(
              enabled: !config.blitzWeb.enabled,
            ),
          );
        }
      case 'system':
        switch (optionIndex) {
          case 2:
            const platforms = ['pi4', 'pi5', 'x86', 'vm'];
            final next =
                (platforms.indexOf(config.system.platform) + 1) %
                platforms.length;
            return config.copyWith(
              system: config.system.copyWith(platform: platforms[next]),
            );
          // hostname and timezone need text input, skip for now
          // case 3 (password) is handled separately in the key handler
        }
    }
    return null;
  }

  List<Component> _buildOptions(
    NixblitzConfig config,
    String service,
    int selectedIndex,
  ) {
    switch (service) {
      case 'system':
        return [
          TextOptionEditor(
            label: 'hostname',
            value: config.system.hostname,
            focused: selectedIndex == 0,
          ),
          TextOptionEditor(
            label: 'timezone',
            value: config.system.timezone,
            focused: selectedIndex == 1,
          ),
          SelectOptionEditor(
            label: 'platform',
            value: config.system.platform,
            options: const ['pi4', 'pi5', 'x86', 'vm'],
            focused: selectedIndex == 2,
          ),
          TextOptionEditor(
            label: 'password',
            value: 'Press Enter to change',
            focused: selectedIndex == 3,
          ),
        ];
      case 'bitcoind':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.bitcoind.enabled,
            focused: selectedIndex == 0,
          ),
          SelectOptionEditor(
            label: 'network',
            value: config.bitcoind.network,
            options: const ['mainnet', 'regtest'],
            focused: selectedIndex == 1,
          ),
          BoolOptionEditor(
            label: 'pruned',
            value: config.bitcoind.pruned,
            focused: selectedIndex == 2,
          ),
          NumberOptionEditor(
            label: 'prune size',
            value: config.bitcoind.pruneSizeGb,
            unit: 'GB',
            focused: selectedIndex == 3,
          ),
        ];
      case 'lnd':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.lnd.enabled,
            focused: selectedIndex == 0,
          ),
          TextOptionEditor(
            label: 'alias',
            value: config.lnd.alias,
            focused: selectedIndex == 1,
          ),
        ];
      case 'cln':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.cln.enabled,
            focused: selectedIndex == 0,
          ),
        ];
      case 'blitz-api':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.blitzApi.enabled,
            focused: selectedIndex == 0,
          ),
        ];
      case 'blitz-web':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.blitzWeb.enabled,
            focused: selectedIndex == 0,
          ),
        ];
      case 'plugins':
        final active = config.plugins
            .where((p) => p.uninstalledAt == null)
            .toList();
        if (active.isEmpty) {
          return const [
            Text(
              '(no plugins installed — use `nixblitz plugin add <url>`)',
              style: TextStyle(color: Color.fromRGB(150, 150, 170)),
            ),
          ];
        }
        return List.generate(active.length, (i) {
          final p = active[i];
          final focused = selectedIndex == i;
          final prefix = focused ? '> ' : '  ';
          final color = focused
              ? const Color.fromRGB(247, 147, 26)
              : const Color.fromRGB(200, 200, 200);
          final pin = p.pinnedRev.length >= 7
              ? p.pinnedRev.substring(0, 7)
              : p.pinnedRev;
          return Text(
            '$prefix${p.dirName}  [$pin] — ${p.id}',
            style: TextStyle(color: color),
          );
        });
      default:
        return [const Text('Unknown service')];
    }
  }
}
