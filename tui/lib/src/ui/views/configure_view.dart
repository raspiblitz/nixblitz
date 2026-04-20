import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/option_editor.dart';
import '../../providers/ui_state_provider.dart';

final _selectedOptionProvider = StateProvider<int>((ref) => 0);

class ConfigureView extends StatelessComponent {
  const ConfigureView({super.key});

  @override
  Component build(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final serviceIndex = context.watch(selectedServiceIndexProvider);
    final selectedOption = context.watch(_selectedOptionProvider);

    return configAsync.when(
      loading: () => const Center(child: Text('Loading...')),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (config) {
        final services = [
          'system',
          'bitcoind',
          'lnd',
          'cln',
          'blitz-api',
          'blitz-web',
        ];
        final currentService = services[serviceIndex];
        final options = _buildOptions(config, currentService, selectedOption);

        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            try {
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
            const networks = ['mainnet', 'testnet', 'signet'];
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
            options: const ['mainnet', 'testnet', 'signet'],
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
      default:
        return [const Text('Unknown service')];
    }
  }
}
