import 'package:test/test.dart';
import 'package:tui/src/ui/views/dashboard/tile_layout.dart';

void main() {
  group('assignColumnsByHeight', () {
    test('one column gets all tiles in order', () {
      expect(assignColumnsByHeight([5, 3, 4, 2, 6], 1), [
        [0, 1, 2, 3, 4],
      ]);
    });

    test('zero tiles produces empty columns', () {
      expect(assignColumnsByHeight([], 2), [<int>[], <int>[]]);
    });

    test('zero or negative cols returns empty', () {
      expect(assignColumnsByHeight([5, 3], 0), <List<int>>[]);
      expect(assignColumnsByHeight([5, 3], -1), <List<int>>[]);
    });

    test('uniform heights pack like round-robin in input order', () {
      // With identical heights every column is equally short before
      // each placement; ties break to the leftmost column, so the
      // result is plain round-robin into columns.
      expect(assignColumnsByHeight([10, 10, 10, 10], 2), [
        [0, 2],
        [1, 3],
      ]);
      expect(assignColumnsByHeight([10, 10, 10, 10, 10, 10], 3), [
        [0, 3],
        [1, 4],
        [2, 5],
      ]);
    });

    test('uniform heights with N % cols != 0: orphan goes leftmost', () {
      // Greedy on a tie picks col 0, so an odd-count partial last
      // row places extra tiles in the leftmost columns first.
      // (For visual end-of-list "right gap" framing under uniform
      // heights, callers that prefer that posture should sort
      // input order; the layout is order-respecting.)
      expect(assignColumnsByHeight([10, 10, 10], 2), [
        [0, 2],
        [1],
      ]);
      expect(assignColumnsByHeight([10, 10, 10, 10, 10], 3), [
        [0, 3],
        [1, 4],
        [2],
      ]);
    });

    test('balances by total height when heights vary', () {
      // The motivating real-world case: NodeTile + Hardware on the
      // left + System; Bitcoin + Lightning on the right. Inputs
      // ordered [Node(10), Bitcoin(14), Hardware(10), Lightning(16),
      // System(12)] should balance to col0=Node+Hardware+System (32)
      // and col1=Bitcoin+Lightning (30) — close to even, not the
      // 16-vs-30 split count-balanced layouts produce.
      final heights = [10, 14, 10, 16, 12];
      final result = assignColumnsByHeight(heights, 2);
      expect(result, [
        [0, 2, 4],
        [1, 3],
      ]);
      final col0Total = result[0].fold<int>(0, (s, i) => s + heights[i]);
      final col1Total = result[1].fold<int>(0, (s, i) => s + heights[i]);
      expect((col0Total - col1Total).abs(), lessThan(5));
    });

    test('column heights stay balanced across varied inputs', () {
      // Property check: across a range of heights and column counts,
      // the difference between the tallest and shortest column total
      // never exceeds the largest single tile placed. Greedy can't
      // beat that bound because the worst case is the last tile
      // landing on top of a column that was already the shortest.
      final cases = <List<int>>[
        [3, 5, 7, 11],
        [10, 10, 10, 10, 10, 10, 10],
        [20, 1, 1, 1, 1, 1],
        [5, 8, 13, 21, 34, 55],
        [4, 4, 4, 4, 4, 4, 4, 4, 4],
      ];
      for (final heights in cases) {
        for (var cols = 2; cols <= 4; cols++) {
          final result = assignColumnsByHeight(heights, cols);
          final totals = result
              .map((col) => col.fold<int>(0, (s, i) => s + heights[i]))
              .toList();
          final hi = totals.reduce((a, b) => a > b ? a : b);
          final lo = totals.reduce((a, b) => a < b ? a : b);
          final maxTile = heights.reduce((a, b) => a > b ? a : b);
          expect(
            hi - lo,
            lessThanOrEqualTo(maxTile),
            reason: 'imbalance for heights=$heights cols=$cols totals=$totals',
          );
        }
      }
    });

    test('every column reads top-to-bottom in increasing tile index', () {
      // Tiles within a column must stay in ascending order so the
      // dashboard reads in the same order as the source list.
      final heights = [4, 9, 2, 7, 5, 3, 8, 1, 6];
      for (var cols = 1; cols <= 4; cols++) {
        for (final col in assignColumnsByHeight(heights, cols)) {
          for (var k = 1; k < col.length; k++) {
            expect(
              col[k],
              greaterThan(col[k - 1]),
              reason: 'column out of order for cols=$cols: $col',
            );
          }
        }
      }
    });
  });
}
