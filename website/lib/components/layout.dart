import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

/// Static version slug shown in the right-hand header segment. Bumped by
/// hand at release time; matches the `<repo>` tag the public site is
/// built from.
const _kVersion = 'v0.1.0';

/// Forge URL the `[r] Repo` keybind opens.
const _kRepoUrl = 'https://forge.f44.fyi/f44/nixblitz_ng';

/// Top-level navigation rendered both as keybind links under the header
/// strip and as the footer hint bar. Each entry is `(key, label, href,
/// external)`. The same data drives both; keep them in sync.
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
    final currentPath = context.url;

    return header(classes: 'tui-header', [
      div(classes: 'tui-header-row', [
        a(href: '/', classes: 'tui-brand', [Component.text('NIXBLITZ')]),
        div(classes: 'tui-breadcrumb', [
          Component.text(_breadcrumb(currentPath)),
        ]),
        div(classes: 'tui-version', [Component.text(_kVersion)]),
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
    return a(
      href: item.href,
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
    return a(
      href: item.href,
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
