import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../ui/widgets/confirm_prompt.dart';
import '../dev_app.dart';

final _confirmSelectionProvider = StateProvider<int>((ref) => 1);
final _confirmResultProvider = StateProvider<String>((ref) => '');

class ConfirmPromptDemoView extends StatelessComponent {
  const ConfirmPromptDemoView({super.key});

  @override
  Component build(BuildContext context) {
    final selection = context.watch(_confirmSelectionProvider);
    final result = context.watch(_confirmResultProvider);

    if (result.isNotEmpty) {
      return Focusable(
        focused: true,
        onKeyEvent: (event) {
          try {
            if (event.logicalKey == LogicalKey.escape ||
                event.logicalKey == LogicalKey.enter) {
              context.read(_confirmResultProvider.notifier).state = '';
              context.read(_confirmSelectionProvider.notifier).state = 1;
              context.read(currentDevViewProvider.notifier).state =
                  DevView.menu;
              return true;
            }
            return false;
          } catch (e, st) {
            LogService.error('Confirm demo result handler failed', e, st);
            return true;
          }
        },
        child: Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Confirm Prompt Demo — Result',
                style: TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              Text('User selected: $result'),
              const SizedBox(height: 1),
              const Text(
                '[Enter/Esc] back to menu',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            ],
          ),
        ),
      );
    }

    return ConfirmPrompt(
      title: 'Confirm Prompt Demo',
      warning: 'This would do something destructive!',
      details: ['Example detail line 1', 'Example detail line 2'],
      confirmLabel: 'Yes, do the thing',
      cancelLabel: 'No, cancel',
      selectedIndex: selection,
      onHighlight: (index) {
        context.read(_confirmSelectionProvider.notifier).state = index;
      },
      onConfirm: () {
        context.read(_confirmResultProvider.notifier).state = 'CONFIRM';
      },
      onCancel: () {
        context.read(_confirmResultProvider.notifier).state = 'CANCEL';
      },
    );
  }
}
