import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../ui/widgets/select_popup.dart';
import '../dev_app.dart';

const _options = ['Apple', 'Banana', 'Cherry', 'Date', 'Elderberry'];

final _selectIndexProvider = StateProvider<int>((ref) => 0);
final _selectResultProvider = StateProvider<String>((ref) => '');

class SelectPopupDemoView extends StatelessComponent {
  const SelectPopupDemoView({super.key});

  @override
  Component build(BuildContext context) {
    final selectedIndex = context.watch(_selectIndexProvider);
    final result = context.watch(_selectResultProvider);

    if (result.isNotEmpty) {
      return Focusable(
        focused: true,
        onKeyEvent: (event) {
          try {
            if (event.logicalKey == LogicalKey.escape ||
                event.logicalKey == LogicalKey.enter) {
              context.read(_selectResultProvider.notifier).state = '';
              context.read(_selectIndexProvider.notifier).state = 0;
              context.read(currentDevViewProvider.notifier).state =
                  DevView.menu;
              return true;
            }
            return false;
          } catch (e, st) {
            LogService.error('Select popup demo result handler failed', e, st);
            return true;
          }
        },
        child: Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select Popup Demo — Result',
                style: TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              Text('Selected: $result'),
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

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Select Popup Demo',
            style: TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          SelectPopup(
            title: 'Pick a fruit',
            options: _options,
            selectedIndex: selectedIndex,
            onHighlight: (index) {
              context.read(_selectIndexProvider.notifier).state = index;
            },
            onConfirm: (index) {
              context.read(_selectResultProvider.notifier).state =
                  _options[index];
            },
            onCancel: () {
              context.read(currentDevViewProvider.notifier).state =
                  DevView.menu;
            },
          ),
        ],
      ),
    );
  }
}
