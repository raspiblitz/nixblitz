import 'package:test/test.dart';
import 'package:tui/src/ui/views/dashboard/tile_layout.dart';

void main() {
  group('assignColumns', () {
    test('one column gets all tiles in order', () {
      expect(assignColumns(5, 1), [
        [0, 1, 2, 3, 4],
      ]);
    });

    test('zero tiles produces empty columns', () {
      expect(assignColumns(0, 2), [<int>[], <int>[]]);
    });

    test('single row stays left-aligned (N <= cols)', () {
      // With only one row of tiles, there is no orphan to worry
      // about; right-shift would push a single tile away from
      // col 0 for no reason. The shift only kicks in when there's
      // a *partial last* row (i.e. more than one row and a
      // remainder).
      expect(assignColumns(1, 2), [
        [0],
        <int>[],
      ]);
      expect(assignColumns(2, 3), [
        [0],
        [1],
        <int>[],
      ]);
    });

    test('full grid (N % cols == 0) is plain round-robin', () {
      // No partial last row → no shift, every column the same height.
      expect(assignColumns(4, 2), [
        [0, 2],
        [1, 3],
      ]);
      expect(assignColumns(6, 3), [
        [0, 3],
        [1, 4],
        [2, 5],
      ]);
    });

    test('cols=2, odd N puts the orphan in the right column', () {
      // The original bug report: tile 6 (the odd-one-out) sat
      // alone at the bottom of col 0 with col 1 ending earlier.
      // After the fix, col 1 gains it instead.
      expect(assignColumns(7, 2), [
        [0, 2, 4],
        [1, 3, 5, 6],
      ]);
      expect(assignColumns(3, 2), [
        [0],
        [1, 2],
      ]);
      expect(assignColumns(5, 2), [
        [0, 2],
        [1, 3, 4],
      ]);
    });

    test('cols=3, partial last row right-aligns; no middle gap', () {
      // The cols=3 / N=5 regression case. A naive "move last to
      // shortest column" rule turned (2,2,1) into (2,1,2) — the
      // middle column ended up shorter than both neighbours,
      // producing a visually weird hole between filled columns.
      // Right-aligning the partial row keeps the gap contiguous
      // on the LEFT instead.
      expect(assignColumns(5, 3), [
        [0],
        [1, 3],
        [2, 4],
      ]);
      // N=4 / cols=3: last row has just one tile; it lands in
      // the rightmost column, leaving cols 0 + 1 empty at the
      // bottom — gap fully contiguous on the left.
      expect(assignColumns(4, 3), [
        [0],
        [1],
        [2, 3],
      ]);
      // N=7 / cols=3: last row also single, rightmost.
      expect(assignColumns(7, 3), [
        [0, 3],
        [1, 4],
        [2, 5, 6],
      ]);
    });

    test('every column has at most one more tile than the smallest', () {
      // Property-style sanity: across a range of inputs, the
      // count imbalance between any two columns is ≤ 1. Catches
      // future regressions where a "smarter" rule overcorrects
      // and leaves some column much shorter than the others.
      for (var cols = 1; cols <= 4; cols++) {
        for (var n = 0; n <= 12; n++) {
          final result = assignColumns(n, cols);
          if (result.isEmpty) continue;
          final lengths = result.map((c) => c.length).toList();
          final hi = lengths.reduce((a, b) => a > b ? a : b);
          final lo = lengths.reduce((a, b) => a < b ? a : b);
          expect(
            hi - lo,
            lessThanOrEqualTo(1),
            reason: 'imbalanced columns for n=$n cols=$cols: $lengths',
          );
        }
      }
    });

    test('every column reads top-to-bottom in increasing tile index', () {
      // Tiles within a column must stay in ascending order so
      // the dashboard reads in the same order as the source list.
      // A rule that swaps order within a column would be a bug.
      for (var cols = 1; cols <= 4; cols++) {
        for (var n = 0; n <= 12; n++) {
          for (final col in assignColumns(n, cols)) {
            for (var k = 1; k < col.length; k++) {
              expect(
                col[k],
                greaterThan(col[k - 1]),
                reason: 'column out of order for n=$n cols=$cols: $col',
              );
            }
          }
        }
      }
    });
  });
}
