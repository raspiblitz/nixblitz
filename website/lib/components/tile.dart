import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

/// A bordered TUI-style tile. Mirrors the chrome of the actual NixBlitz
/// dashboard tiles: 1px border, header strip with a coloured title on the
/// left and an optional status on the right, padded body below.
///
/// `titleColor` and `statusColor` accept the TUI palette tokens defined in
/// `web/input.css` (`orange`, `cyan`, `magenta`, `ok`, `warn`, `err`,
/// `muted`). `titleColor` defaults to orange (the dashboard's System tile);
/// `statusColor` defaults to `ok` when status text is supplied.
class Tile extends StatelessComponent {
  final String title;
  final String? status;
  final String? titleColor;
  final String? statusColor;
  final String? extraClasses;
  final List<Component> children;

  const Tile({
    required this.title,
    this.status,
    this.titleColor,
    this.statusColor,
    this.extraClasses,
    required this.children,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final tileClasses = ['tile', ?extraClasses].join(' ');
    final titleClass = 'tile-title tile-title-${titleColor ?? 'orange'}';
    final statusClass = 'tile-status tile-status-${statusColor ?? 'ok'}';

    return div(classes: tileClasses, [
      div(classes: 'tile-header', [
        span(classes: titleClass, [Component.text(title)]),
        if (status != null)
          span(classes: statusClass, [Component.text(status!)]),
      ]),
      div(classes: 'tile-body', children),
    ]);
  }
}
