import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

class ServiceCard extends StatelessComponent {
  final ServiceStatus status;
  final bool isDisabled;

  const ServiceCard({super.key, required this.status, this.isDisabled = false});

  @override
  Component build(BuildContext context) {
    final Color stateColor;
    final String stateIcon;

    if (isDisabled) {
      stateColor = const Color.fromRGB(100, 100, 120);
      stateIcon = '-';
    } else {
      switch (status.state) {
        case ServiceState.running:
          stateColor = const Color.fromRGB(110, 220, 110);
          stateIcon = '*';
        case ServiceState.failed:
          stateColor = const Color.fromRGB(255, 80, 80);
          stateIcon = '!';
        case ServiceState.activating:
          stateColor = const Color.fromRGB(247, 147, 26);
          stateIcon = '~';
        default:
          stateColor = const Color.fromRGB(100, 100, 120);
          stateIcon = 'x';
      }
    }

    final label = isDisabled ? 'disabled' : status.stateLabel;

    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            '${status.name}:',
            style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
          ),
        ),
        Text('$stateIcon $label', style: TextStyle(color: stateColor)),
      ],
    );
  }
}
