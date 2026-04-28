import 'package:nocterm/nocterm.dart';

/// How many tile columns fit at [width]. Below 80 cols labels get
/// cramped side-by-side; at 140+ there's enough horizontal room
/// for 3.
int columnsFor(double width) {
  if (width < 80) return 1;
  if (width < 140) return 2;
  return 3;
}

/// Pure column-assignment for [tileRows]. Given [n] tiles and
/// [cols] columns, return the list of tile indices that land in
/// each column, top-to-bottom.
///
/// Conceptually the layout is a `rows x cols` grid filled
/// row-major. Strict round-robin would leave a partial last row
/// LEFT-aligned, which strands an orphan tile alone in the bottom
/// of the leftmost column when other columns ended earlier — reads
/// as "something missing." Right-aligning the partial last row
/// pushes the gap into the BOTTOM-LEFT corner(s), where it reads
/// as the natural end of a list.
///
/// A naive "move the last tile to the shortest column" rule (an
/// earlier attempt) gets cols=2 right but breaks cols=3 / N=5: it
/// teleports the last tile across the middle column to the
/// rightmost, leaving the middle column as a *between* gap —
/// worse than the original. Right-aligning the entire last
/// partial row keeps the gaps contiguous on the left.
///
/// Not real masonry — tiles have varying heights and we don't
/// track them. Just count-balance with a consistent gap position.
///
/// Public so the layout logic can be tested without rendering;
/// callers in the dashboard go through [tileRows] instead.
List<List<int>> assignColumns(int n, int cols) {
  if (n <= 0 || cols <= 0) return List.generate(cols, (_) => const []);
  if (cols == 1) return [List.generate(n, (i) => i)];

  final rows = (n + cols - 1) ~/ cols;
  final lastRowStart = (rows - 1) * cols;
  final lastRowCount = n - lastRowStart;
  final shift = rows > 1 && lastRowCount < cols
      ? cols - lastRowCount
      : 0;

  final columns = List.generate(cols, (_) => <int>[]);
  for (var i = 0; i < n; i++) {
    final col =
        i < lastRowStart ? i % cols : (i - lastRowStart + shift);
    columns[col].add(i);
  }
  return columns;
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

  final assignments = assignColumns(tiles.length, cols);
  final columns = [
    for (final indices in assignments) [for (final i in indices) tiles[i]],
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
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rowChildren,
    ),
  ];
}
