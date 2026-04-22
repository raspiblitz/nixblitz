import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../ui/widgets/spinner.dart';
import '../dev_app.dart';

class SpinnerDemoView extends StatelessComponent {
  const SpinnerDemoView({super.key});

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
          LogService.error('Spinner demo key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Spinner Demo',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text('Default spinner (orange, no label):'),
            Spinner(),
            const SizedBox(height: 1),
            const Text('With a label:'),
            Spinner(label: 'Loading something slow...'),
            const SizedBox(height: 1),
            const Text('Custom color (green):'),
            Spinner(
              color: const Color.fromRGB(110, 220, 110),
              label: 'Green spinner',
            ),
            const SizedBox(height: 1),
            const Text('Custom color (red):'),
            Spinner(
              color: const Color.fromRGB(255, 80, 80),
              label: 'Red spinner',
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
