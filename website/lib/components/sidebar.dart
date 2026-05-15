import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

import '../build_info.dart';

class Sidebar extends StatelessComponent {
  const Sidebar({super.key});

  /// Internal paths (unprefixed). [href] applies the BASE_PATH prefix
  /// at render time; [internalPath] strips it from the request URL for
  /// the active-route check.
  static const Map<String, String> docs = {
    '/docs/installation': 'installation',
    '/docs/updates': 'updates',
    '/docs/architecture': 'architecture',
    '/docs/plugins': 'plugins',
  };

  @override
  Component build(BuildContext context) {
    final currentPath = internalPath(context.url);

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
          href: href(entry.key),
          [
            span(classes: 'key', [Component.text('[>]')]),
            Component.text(' ${entry.value}'),
          ],
        ),
      ),
    ]);
  }
}
