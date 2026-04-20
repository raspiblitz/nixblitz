import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

/// An inline popup that shows a list of options for the user to pick from.
/// j/k navigates, Enter confirms, Esc cancels.
class SelectPopup extends StatelessComponent {
  final String title;
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onHighlight;
  final ValueChanged<int> onConfirm;
  final VoidCallback onCancel;

  const SelectPopup({
    required this.title,
    required this.options,
    required this.selectedIndex,
    required this.onHighlight,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            onCancel();
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            onConfirm(selectedIndex);
            return true;
          }
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (selectedIndex < options.length - 1) {
              onHighlight(selectedIndex + 1);
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (selectedIndex > 0) {
              onHighlight(selectedIndex - 1);
            }
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Select popup key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        decoration: BoxDecoration(
          border: BoxBorder.all(color: const Color.fromRGB(247, 147, 26)),
          color: const Color.fromRGB(36, 36, 54),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            ...List.generate(options.length, (i) {
              final isSelected = i == selectedIndex;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: isSelected ? const Color.fromRGB(247, 147, 26) : null,
                ),
                child: Text(
                  options[i],
                  style: TextStyle(
                    color: isSelected
                        ? const Color.fromRGB(0, 0, 0)
                        : const Color.fromRGB(200, 200, 200),
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              );
            }),
            Text(
              '↑/↓ select  Enter confirm  Esc cancel',
              style: const TextStyle(color: Color.fromRGB(120, 120, 140)),
            ),
          ],
        ),
      ),
    );
  }
}
