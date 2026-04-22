import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../widgets/service_card.dart';

class DashboardView extends StatelessComponent {
  const DashboardView({super.key});

  @override
  Component build(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final statusAsync = context.watch(serviceStatusProvider);
    final pendingAsync = context.watch(pendingChangesProvider);

    return configAsync.when(
      loading: () => const Center(child: Text('Loading config...')),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (config) {
        final pendingCount = pendingAsync.maybeWhen(
          data: (lines) => lines.length,
          orElse: () => 0,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    config.system.hostname,
                    style: const TextStyle(
                      color: Color.fromRGB(220, 220, 220),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${config.system.platform} | ${config.bitcoind.network}',
                    style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                  ),
                ],
              ),
            ),
            if (pendingCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '! $pendingCount pending '
                  '${pendingCount == 1 ? "change" : "changes"} '
                  '— press [a] to review',
                  style: const TextStyle(color: Color.fromRGB(247, 147, 26)),
                ),
              ),
            const SizedBox(height: 1),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: statusAsync.when(
                loading: () => const Text('Checking services...'),
                error: (e, _) => Text('Could not read services: $e'),
                data: (statuses) {
                  final statusMap = {
                    for (final s in statuses) s.name: s,
                  };

                  ServiceStatus statusFor(String name) =>
                      statusMap[name] ??
                      ServiceStatus(name: name, state: ServiceState.unknown);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        ServiceCard(status: statusFor('bitcoind'), isDisabled: !config.bitcoind.enabled),
                        const SizedBox(width: 4),
                        ServiceCard(status: statusFor('lnd'), isDisabled: !config.lnd.enabled),
                      ]),
                      Row(children: [
                        ServiceCard(status: statusFor('clightning'), isDisabled: !config.cln.enabled),
                        const SizedBox(width: 4),
                        ServiceCard(status: statusFor('blitz-api'), isDisabled: !config.blitzApi.enabled),
                      ]),
                      ServiceCard(status: statusFor('blitz-web'), isDisabled: !config.blitzWeb.enabled),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
