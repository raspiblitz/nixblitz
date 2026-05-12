import 'package:nocterm/nocterm.dart';

/// One keybind hint in the context-sensitive footer strip.
///
/// Rendered as `[key] action` with the key in slightly brighter
/// text than the action. A list of these forms the strip the shell
/// paints below the body — see [_Shell] in `ui/app.dart`.
class FooterHint {
  const FooterHint({required this.key, required this.action});
  final String key;
  final String action;
}

/// Horizontal strip rendered below each view's body. Lives in the
/// shell rather than per-view so the layout stays uniform; views
/// supply their own hint list via the per-view sub-state providers
/// the shell watches.
class FooterHints extends StatelessComponent {
  final List<FooterHint> hints;

  const FooterHints({super.key, required this.hints});

  @override
  Component build(BuildContext context) {
    if (hints.isEmpty) return const SizedBox.shrink();
    const keyColor = Color.fromRGB(180, 180, 200);
    const actionColor = Color.fromRGB(120, 120, 140);
    const sepColor = Color.fromRGB(80, 80, 100);

    final children = <Component>[];
    for (var i = 0; i < hints.length; i++) {
      if (i > 0) {
        children.add(const Text('  ', style: TextStyle(color: sepColor)));
      }
      children.add(
        Text(
          '[${hints[i].key}]',
          style: const TextStyle(color: keyColor, fontWeight: FontWeight.bold),
        ),
      );
      children.add(const Text(' ', style: TextStyle(color: keyColor)));
      children.add(
        Text(hints[i].action, style: const TextStyle(color: actionColor)),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      decoration: const BoxDecoration(
        border: BoxBorder(top: BorderSide(color: Color.fromRGB(80, 80, 100))),
      ),
      child: Row(children: children),
    );
  }
}
