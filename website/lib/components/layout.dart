import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

import '../build_info.dart';

/// Forge URL the `[r] Repo` keybind opens.
const _kRepoUrl = 'https://github.com/raspiblitz/nixblitz';

/// Top-level navigation rendered both as keybind links under the header
/// strip and as the footer hint bar. Each entry is `(key, label, href,
/// external)`. Internal hrefs are stored unprefixed; [href] applies the
/// configured BASE_PATH at render time so the same constant works for
/// both root-served and subpath-served builds.
const List<({String key, String label, String href, bool external})> _navItems =
    [
      (key: 'h', label: 'Home', href: '/', external: false),
      (key: 'd', label: 'Docs', href: '/docs/installation', external: false),
      (key: 'c', label: 'Changelog', href: '/changelog', external: false),
      (key: 'r', label: 'Repo', href: _kRepoUrl, external: true),
    ];

/// Three-segment TUI header — `NIXBLITZ | <breadcrumb> | <version>` — plus
/// a row of bracketed keybind links. Mirrors the actual TUI's dashboard
/// header chrome (compare `examples_redesign/screenshots/dashboard.png`).
class NavBar extends StatelessComponent {
  const NavBar({super.key});

  @override
  Component build(BuildContext context) {
    // context.url comes back with the base-path prefix when the site
    // is served from a subpath. Strip it so the rest of the routing
    // logic can work in internal-path terms.
    final currentPath = internalPath(context.url);

    return header(classes: 'tui-header', [
      div(classes: 'tui-header-row', [
        a(href: href('/'), classes: 'tui-brand', [Component.text('NIXBLITZ')]),
        div(classes: 'tui-breadcrumb', [
          Component.text(_breadcrumb(currentPath)),
        ]),
        div(classes: 'tui-version', [Component.text(buildVersionString)]),
      ]),
      nav(classes: 'tui-keybind-nav', [
        for (final item in _navItems) _keybindLink(item, currentPath),
      ]),
    ]);
  }

  String _breadcrumb(String path) {
    if (path == '/') return 'home';
    if (path == '/changelog') return 'changelog';
    if (path.startsWith('/docs/')) {
      final slug = path.substring('/docs/'.length);
      return 'docs | $slug';
    }
    return path;
  }

  Component _keybindLink(
    ({String key, String label, String href, bool external}) item,
    String currentPath,
  ) {
    final isActive = !item.external && _isActiveRoute(item.href, currentPath);
    // External URLs pass through verbatim; internal hrefs get the
    // BASE_PATH prefix.
    final renderedHref = item.external ? item.href : href(item.href);
    return a(
      href: renderedHref,
      classes: 'keybind${isActive ? ' active' : ''}',
      attributes: item.external
          ? {'target': '_blank', 'rel': 'noopener noreferrer'}
          : null,
      [
        span(classes: 'key', [Component.text('[${item.key}]')]),
        Component.text(' ${item.label}'),
      ],
    );
  }

  bool _isActiveRoute(String href, String currentPath) {
    if (href == '/') return currentPath == '/';
    if (href.startsWith('/docs/')) return currentPath.startsWith('/docs/');
    return currentPath == href || currentPath.startsWith('$href/');
  }
}

/// Footer keybind hint bar — mirrors the TUI's bottom row of shortcuts.
class Footer extends StatelessComponent {
  const Footer({super.key});

  @override
  Component build(BuildContext context) {
    return footer(classes: 'tui-footer', [
      for (final item in _navItems) _hint(item),
    ]);
  }

  Component _hint(
    ({String key, String label, String href, bool external}) item,
  ) {
    final renderedHref = item.external ? item.href : href(item.href);
    return a(
      href: renderedHref,
      classes: 'keybind',
      attributes: item.external
          ? {'target': '_blank', 'rel': 'noopener noreferrer'}
          : null,
      [
        span(classes: 'key', [Component.text('[${item.key}]:')]),
        Component.text(' ${item.label}'),
      ],
    );
  }
}
