import 'package:nocterm/nocterm.dart';

/// One key/value row inside a [Tile]. Value gets right-aligned with a
/// reasonable-looking gap; the label takes the left column.
class TileRow {
  final String label;
  final String value;
  final Color? valueColor;

  const TileRow(this.label, this.value, {this.valueColor});
}

/// A boxed status card used on the dashboard. Deliberately minimal —
/// a coloured top rule + title, N key/value rows, optional footer for
/// error states.
///
/// When [child] is provided it is rendered as the body instead of [rows].
/// This allows [TileRenderer] to inject a fully-built primitive widget tree
/// while keeping the tile chrome (border, title bar, footer) consistent.
class Tile extends StatelessComponent {
  final String title;
  final Color accent;
  final String? statusLabel;
  final Color? statusColor;
  final List<TileRow> rows;
  final String? footer;
  final Color? footerColor;

  /// Optional child widget. When non-null, renders as the tile body instead
  /// of [rows]. Callers that do not pass [child] are unaffected.
  final Component? child;

  const Tile({
    super.key,
    required this.title,
    required this.accent,
    this.statusLabel,
    this.statusColor,
    this.rows = const [],
    this.footer,
    this.footerColor,
    this.child,
  });

  @override
  Component build(BuildContext context) {
    final body =
        child ??
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows.map(_renderRow).toList(),
        );

    return Container(
      padding: const EdgeInsets.only(left: 1, right: 1, top: 1, bottom: 1),
      decoration: BoxDecoration(
        border: BoxBorder(
          top: BorderSide(color: accent),
          bottom: BorderSide(color: const Color.fromRGB(60, 60, 80)),
          left: BorderSide(color: const Color.fromRGB(60, 60, 80)),
          right: BorderSide(color: const Color.fromRGB(60, 60, 80)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(color: accent, fontWeight: FontWeight.bold),
              ),
              if (statusLabel != null)
                Text(
                  statusLabel!,
                  style: TextStyle(
                    color: statusColor ?? const Color.fromRGB(150, 150, 180),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 1),
          body,
          if (footer != null) ...[
            const SizedBox(height: 1),
            Text(
              footer!,
              style: TextStyle(
                color: footerColor ?? const Color.fromRGB(255, 120, 120),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Component _renderRow(TileRow r) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          r.label,
          style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
        Text(
          r.value,
          style: TextStyle(
            color: r.valueColor ?? const Color.fromRGB(220, 220, 220),
          ),
        ),
      ],
    );
  }
}
