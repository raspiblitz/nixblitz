import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

import 'popup_chrome.dart';

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
      child: PopupChrome(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: kPopupAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
            ...List.generate(options.length, (i) {
              final isSelected = i == selectedIndex;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: isSelected ? kPopupAccent : null,
                ),
                child: Text(
                  options[i],
                  style: TextStyle(
                    color: isSelected ? kPopupSelectedFg : kPopupBody,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              );
            }),
            const Text(
              '↑/↓ select  Enter confirm  Esc cancel',
              style: TextStyle(color: kPopupDim),
            ),
          ],
        ),
      ),
    );
  }
}
