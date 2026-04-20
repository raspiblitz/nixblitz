import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

/// A reusable yes/no confirmation prompt rendered as a selectable list.
class ConfirmPrompt extends StatelessComponent {
  final String title;
  final String? warning;
  final List<String> details;
  final String confirmLabel;
  final String cancelLabel;
  final int selectedIndex;
  final ValueChanged<int> onHighlight;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ConfirmPrompt({
    required this.title,
    this.warning,
    this.details = const [],
    this.confirmLabel = 'Yes, proceed',
    this.cancelLabel = 'No, go back',
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
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (selectedIndex < 1) onHighlight(1);
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (selectedIndex > 0) onHighlight(0);
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            if (selectedIndex == 0) {
              onConfirm();
            } else {
              onCancel();
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.escape) {
            onCancel();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Confirm prompt key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            if (warning != null) ...[
              const SizedBox(height: 1),
              Text(
                warning!,
                style: const TextStyle(
                  color: Color.fromRGB(255, 80, 80),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            if (details.isNotEmpty) ...[
              const SizedBox(height: 1),
              ...details.map(
                (d) => Text(d, style: const TextStyle(color: Color.fromRGB(200, 200, 200))),
              ),
            ],
            const SizedBox(height: 1),
            _ConfirmOption(
              label: confirmLabel,
              focused: selectedIndex == 0,
            ),
            _ConfirmOption(
              label: cancelLabel,
              focused: selectedIndex == 1,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmOption extends StatelessComponent {
  final String label;
  final bool focused;

  const _ConfirmOption({required this.label, required this.focused});

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    return Text(
      '$prefix$label',
      style: TextStyle(color: color, fontWeight: focused ? FontWeight.bold : FontWeight.normal),
    );
  }
}
