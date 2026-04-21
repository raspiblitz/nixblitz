import 'package:nocterm/nocterm.dart';

class HelpPopup extends StatelessComponent {
  final VoidCallback onClose;

  const HelpPopup({required this.onClose});

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape ||
            event.logicalKey == LogicalKey.question) {
          onClose();
          return true;
        }
        return false;
      },
      child: Center(
        child: Container(
          width: 55,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            border: BoxBorder.all(color: const Color.fromRGB(247, 147, 26)),
            color: const Color.fromRGB(24, 24, 36),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Text(
                  'NixBlitz Help',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color.fromRGB(247, 147, 26),
                  ),
                ),
              ),
              const Divider(),
              const Center(
                child: Text(
                  'Navigation',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color.fromRGB(200, 200, 200),
                  ),
                ),
              ),
              _HelpItem(keyLabel: 'j/k, ↑/↓', desc: 'Navigate up/down'),
              _HelpItem(keyLabel: 'Enter', desc: 'Select / Confirm'),
              _HelpItem(keyLabel: 'Esc', desc: 'Back / Cancel'),
              const Divider(),
              const Center(
                child: Text(
                  'Dashboard',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color.fromRGB(200, 200, 200),
                  ),
                ),
              ),
              _HelpItem(keyLabel: 'c', desc: 'Configure services'),
              _HelpItem(keyLabel: 'u', desc: 'Update system'),
              _HelpItem(keyLabel: '?', desc: 'Show/hide this help'),
              _HelpItem(keyLabel: 'q', desc: 'Quit'),
              const Divider(),
              const Center(
                child: Text(
                  'Install',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color.fromRGB(200, 200, 200),
                  ),
                ),
              ),
              _HelpItem(keyLabel: 'y', desc: 'Confirm installation'),
              _HelpItem(keyLabel: 'n', desc: 'Cancel / Go back'),
              const Divider(),
              const Center(
                child: Text(
                  'Press Esc or ? to close',
                  style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HelpItem extends StatelessComponent {
  final String keyLabel;
  final String desc;

  const _HelpItem({required this.keyLabel, required this.desc});

  @override
  Component build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 14,
          child: Text(
            keyLabel,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Color.fromRGB(255, 200, 100),
            ),
          ),
        ),
        Text(': $desc'),
      ],
    );
  }
}
