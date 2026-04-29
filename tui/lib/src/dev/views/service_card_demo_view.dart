import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../ui/widgets/service_card.dart';
import '../dev_app.dart';

class ServiceCardDemoView extends StatelessComponent {
  const ServiceCardDemoView({super.key});

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            context.read(currentDevViewProvider.notifier).state = DevView.menu;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Service card demo key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Service Card Demo',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const ServiceCard(
              status: ServiceStatus(
                name: 'bitcoind',
                state: ServiceState.running,
              ),
            ),
            const ServiceCard(
              status: ServiceStatus(name: 'lnd', state: ServiceState.stopped),
            ),
            const ServiceCard(
              status: ServiceStatus(
                name: 'clightning',
                state: ServiceState.failed,
              ),
            ),
            const ServiceCard(
              status: ServiceStatus(
                name: 'blitz-api',
                state: ServiceState.activating,
              ),
            ),
            const ServiceCard(
              status: ServiceStatus(
                name: 'blitz-web',
                state: ServiceState.unknown,
              ),
            ),
            const ServiceCard(
              status: ServiceStatus(
                name: 'disabled-svc',
                state: ServiceState.running,
              ),
              isDisabled: true,
            ),
            const SizedBox(height: 2),
            const Text(
              '[Esc] back to menu',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}
