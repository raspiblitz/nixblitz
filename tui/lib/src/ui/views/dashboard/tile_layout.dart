import 'package:nocterm/nocterm.dart';

/// How many tile columns fit at [width]. Below 80 cols labels get
/// cramped side-by-side; at 140+ there's enough horizontal room
/// for 3.
int columnsFor(double width) {
  if (width < 80) return 1;
  if (width < 140) return 2;
  return 3;
}

/// Lay out [tiles] in a [cols]-wide masonry: each column is a
/// stack of tiles abutting top-to-bottom; tiles are distributed
/// to columns by index (`tile[i] → column[i % cols]`).
///
/// Why masonry instead of per-row pairing: nocterm has no
/// `IntrinsicHeight` and `CrossAxisAlignment.stretch` in an
/// unbounded vertical context (e.g. inside a scroll view) collapses
/// or explodes. With masonry the rows-vs-columns problem doesn't
/// exist — each column lays out independently, content-sized, no
/// gaps from "shorter neighbor in the same row".
///
/// The visible cost: tiles don't horizontally align past their
/// first row. That trades neat rectangular grids for compact
/// vertical stacking, which the dashboard cares more about (the
/// real-world content distribution puts a 2-row Hardware tile
/// next to a 6-row System tile and that asymmetry isn't going
/// away).
///
/// Returns a single-element list (the layout root) so callers can
/// keep treating this as "the body" of a scrollable column.
List<Component> tileRows(List<Component> tiles, int cols) {
  if (tiles.isEmpty) return const [];

  // Single column: just stack everything top to bottom.
  if (cols <= 1) {
    return [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: tiles,
      ),
    ];
  }

  final columns = List.generate(cols, (_) => <Component>[]);
  for (var i = 0; i < tiles.length; i++) {
    columns[i % cols].add(tiles[i]);
  }

  final rowChildren = <Component>[];
  for (var c = 0; c < cols; c++) {
    if (c > 0) rowChildren.add(const SizedBox(width: 1));
    rowChildren.add(
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: columns[c],
        ),
      ),
    );
  }

  return [
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rowChildren,
    ),
  ];
}
