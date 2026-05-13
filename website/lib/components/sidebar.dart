import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

class Sidebar extends StatelessComponent {
  const Sidebar({super.key});

  static const Map<String, String> docs = {
    '/docs/installation': 'installation',
    '/docs/updates': 'updates',
    '/docs/architecture': 'architecture',
    '/docs/plugins': 'plugins',
  };

  @override
  Component build(BuildContext context) {
    final currentPath = context.url;

    return nav(classes: 'sticky top-32 space-y-1', [
      h4(
        classes: 'font-bold mb-3 px-3 text-xs tracking-widest uppercase',
        styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
        [Component.text('docs')],
      ),
      ...docs.entries.map(
        (entry) => a(
          classes:
              'keybind block px-3 py-1.5${currentPath == entry.key ? ' active' : ''}',
          href: entry.key,
          [
            span(classes: 'key', [Component.text('[>]')]),
            Component.text(' ${entry.value}'),
          ],
        ),
      ),
    ]);
  }
}
