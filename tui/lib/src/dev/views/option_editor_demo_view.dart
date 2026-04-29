import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../ui/widgets/option_editor.dart';
import '../dev_app.dart';

class OptionEditorDemoView extends StatelessComponent {
  const OptionEditorDemoView({super.key});

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
          LogService.error('Option editor demo key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Option Editor Demo',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text('Bool editors:'),
            const BoolOptionEditor(
              label: 'enabled',
              value: true,
              focused: true,
            ),
            const BoolOptionEditor(label: 'pruned', value: false),
            const SizedBox(height: 1),
            const Text('Select editors:'),
            const SelectOptionEditor(
              label: 'network',
              value: 'mainnet',
              options: ['mainnet', 'regtest'],
              focused: true,
            ),
            const SelectOptionEditor(
              label: 'platform',
              value: 'pi5',
              options: ['pi5', 'x86', 'vm'],
            ),
            const SizedBox(height: 1),
            const Text('Number editors:'),
            const NumberOptionEditor(
              label: 'prune size',
              value: 550,
              unit: 'GB',
              focused: true,
            ),
            const NumberOptionEditor(label: 'port', value: 8333),
            const SizedBox(height: 1),
            const Text('Text editors:'),
            const TextOptionEditor(
              label: 'hostname',
              value: 'nixblitz',
              focused: true,
            ),
            const TextOptionEditor(label: 'alias', value: 'my-lightning-node'),
            const SizedBox(height: 2),
            const Text(
              '[Esc] back to menu  (these are display-only in the demo)',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}
