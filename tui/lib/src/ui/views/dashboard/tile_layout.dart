import 'package:nocterm/nocterm.dart';

/// A dashboard tile bundled with the row-count it expects to occupy.
/// The packer balances columns by *total height*, not tile count, so
/// callers pass an estimate of each tile's vertical footprint
/// (chrome + body rows) alongside the widget.
typedef SizedTile = ({Component widget, int height});

/// How many tile columns fit at [width]. Below 80 cols labels get
/// cramped side-by-side; at 140+ there's enough horizontal room
/// for 3.
int columnsFor(double width) {
  if (width < 80) return 1;
  if (width < 140) return 2;
  return 3;
}

/// Pure column-assignment for [tileRows]. Returns the list of tile
/// indices that land in each column, top-to-bottom.
///
/// Algorithm: shortest-fit greedy. Iterate input order; place each
/// tile into the column with the currently-smallest total height
/// (ties → leftmost column). This is the standard approach for
/// content-balanced masonry layouts and lets the dashboard cope
/// with real-world content where one tile (Lightning) is twice as
/// tall as another (Hardware).
///
/// Order within a column always matches input order, so the
/// dashboard reads top-to-bottom in the same order tiles were
/// supplied. Cross-column reading order is column-major (down
/// the first column, then the next).
///
/// Earlier shapes of this function balanced *count* (each column
/// gets the same number of tiles, with the last partial row
/// right-aligned). That looked fine when tile heights were
/// similar but stranded short tiles in one column while the
/// other clipped past the viewport when heights diverged.
/// Height-aware packing fixes that at the cost of slightly more
/// computation (linear in tiles × cols, vs. constant before).
List<List<int>> assignColumnsByHeight(List<int> heights, int cols) {
  if (cols <= 0) return const [];
  if (heights.isEmpty) return List.generate(cols, (_) => const <int>[]);
  if (cols == 1) {
    return [List.generate(heights.length, (i) => i)];
  }

  final colHeights = List.filled(cols, 0);
  final colTiles = List.generate(cols, (_) => <int>[]);

  for (var i = 0; i < heights.length; i++) {
    var minCol = 0;
    for (var c = 1; c < cols; c++) {
      if (colHeights[c] < colHeights[minCol]) minCol = c;
    }
    colTiles[minCol].add(i);
    colHeights[minCol] += heights[i];
  }

  return colTiles;
}

/// Lay out [tiles] in a [cols]-wide masonry: each column is a
/// stack of tiles abutting top-to-bottom; tiles are distributed
/// to columns by [assignColumnsByHeight] above.
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
List<Component> tileRows(List<SizedTile> tiles, int cols) {
  if (tiles.isEmpty) return const [];

  if (cols <= 1) {
    return [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: tiles.map((t) => t.widget).toList(),
      ),
    ];
  }

  final heights = tiles.map((t) => t.height).toList();
  final assignments = assignColumnsByHeight(heights, cols);
  final columns = [
    for (final indices in assignments)
      [for (final i in indices) tiles[i].widget],
  ];

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
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: rowChildren),
  ];
}
