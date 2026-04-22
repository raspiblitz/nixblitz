import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../ui/widgets/password_input.dart';
import '../dev_app.dart';

final _passwordResultProvider = StateProvider<String>((ref) => '');

class PasswordInputDemoView extends StatelessComponent {
  const PasswordInputDemoView({super.key});

  @override
  Component build(BuildContext context) {
    final result = context.watch(_passwordResultProvider);

    if (result.isNotEmpty) {
      return Focusable(
        focused: true,
        onKeyEvent: (event) {
          try {
            if (event.logicalKey == LogicalKey.escape ||
                event.logicalKey == LogicalKey.enter) {
              context.read(_passwordResultProvider.notifier).state = '';
              context.read(currentDevViewProvider.notifier).state =
                  DevView.menu;
              return true;
            }
            return false;
          } catch (e, st) {
            LogService.error('Password demo result handler failed', e, st);
            return true;
          }
        },
        child: Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Password Input Demo — Result',
                style: TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              Text('You entered a password of length ${result.length}'),
              Text('Preview: $result'),
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

    return PasswordInput(
      title: 'Password Input Demo',
      subtitle:
          'Try entering a password. Tab to peek. Esc to cancel back to menu.',
      minLength: 8,
      requireConfirmation: true,
      onSubmit: (password) {
        context.read(_passwordResultProvider.notifier).state = password;
      },
      onCancel: () {
        context.read(currentDevViewProvider.notifier).state = DevView.menu;
      },
    );
  }
}
