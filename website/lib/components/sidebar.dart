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
    '/docs/install-pi5': 'pi 5',
    '/docs/install-x86': 'x86',
    '/docs/updates': 'updates',
    '/docs/architecture': 'architecture',
    '/docs/plugins': 'plugins',
  };

  /// Entries rendered as indented children of the one above them
  /// (the platform install guides under the installation chooser).
  static const Set<String> nested = {'/docs/install-pi5', '/docs/install-x86'};

  @override
  Component build(BuildContext context) {
    final currentPath = internalPath(context.url);

    return nav(classes: 'sticky top-32 space-y-1', [
      h4(
        classes: 'font-bold mb-3 px-3 text-xs tracking-widest uppercase',
        styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
        [Component.text('docs')],
      ),
      ...docs.entries.map((entry) {
        final isNested = nested.contains(entry.key);
        return a(
          classes:
              'keybind block ${isNested ? 'py-0.5 pl-8 pr-3' : 'py-1.5 px-3'}'
              '${currentPath == entry.key ? ' active' : ''}',
          href: href(entry.key),
          [
            span(classes: 'key', [Component.text(isNested ? '[·]' : '[>]')]),
            Component.text(' ${entry.value}'),
          ],
        );
      }),
    ]);
  }
}
