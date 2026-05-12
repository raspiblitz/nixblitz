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
          width: 72,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            border: BoxBorder.all(color: const Color.fromRGB(247, 147, 26)),
            color: const Color.fromRGB(24, 24, 36),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Center(
                child: Text(
                  'NixBlitz Help',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color.fromRGB(247, 147, 26),
                  ),
                ),
              ),
              Divider(),
              _Section('Top menu'),
              _HelpItem(keyLabel: '←/→ h/l', desc: 'Switch views'),
              _HelpItem(keyLabel: 'c / D', desc: 'Jump to Configure / Debug'),
              _HelpItem(
                keyLabel: 'a / u',
                desc: 'Jump to System (Apply / Update)',
              ),
              Divider(),
              _Section('Inside Configure / System'),
              _HelpItem(
                keyLabel: 'j/k ↑/↓',
                desc: 'Move in the focused column',
              ),
              _HelpItem(
                keyLabel: 'Enter',
                desc: 'Sidebar → content; content → edit/run row',
              ),
              _HelpItem(
                keyLabel: 'Esc',
                desc: 'Content → sidebar; sidebar → Dashboard',
              ),
              Divider(),
              _Section('Modals / overlays'),
              _HelpItem(keyLabel: 'y / n', desc: 'Confirm / cancel'),
              _HelpItem(keyLabel: 'Esc', desc: 'Dismiss without changes'),
              Divider(),
              _Section('Global'),
              _HelpItem(keyLabel: '?', desc: 'Toggle this help'),
              _HelpItem(keyLabel: 'q', desc: 'Quit'),
              Divider(),
              Center(
                child: Text(
                  'The footer strip shows the keys live for whatever\n'
                  "you're focused on. Press Esc or ? to close.",
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

class _Section extends StatelessComponent {
  final String title;
  const _Section(this.title);

  @override
  Component build(BuildContext context) {
    return Center(
      child: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Color.fromRGB(200, 200, 200),
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 16,
          child: Text(
            keyLabel,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Color.fromRGB(255, 200, 100),
            ),
          ),
        ),
        Expanded(
          child: Text(
            ': $desc',
            style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
          ),
        ),
      ],
    );
  }
}
