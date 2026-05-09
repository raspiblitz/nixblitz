import 'dart:math';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

import '../../ui/views/dashboard/tile_layout.dart';
import '../../ui/widgets/tile.dart';
import '../dev_app.dart';

/// Synthetic tile-count / column-count / height-seed cycles. Each
/// hotkey advances its provider's index modulo the cycle length.
final _countIdxProvider = StateProvider<int>((ref) => 1);
final _colsIdxProvider = StateProvider<int>((ref) => 1);
final _seedProvider = StateProvider<int>((ref) => 42);

const _countCycle = <int>[3, 5, 7, 10, 15];
const _colsCycle = <int>[1, 2, 3];

/// Range for synthetic tile heights. Lower bound > chrome overhead
/// so every tile renders something visible; upper bound roughly
/// matches the tallest real tile (Lightning).
const _minTileHeight = 7;
const _maxTileHeight = 18;

const _accentColors = <Color>[
  Color.fromRGB(247, 147, 26), // orange
  Color.fromRGB(120, 200, 220), // cyan
  Color.fromRGB(110, 220, 110), // green
  Color.fromRGB(200, 140, 220), // purple
  Color.fromRGB(255, 200, 80), // amber
  Color.fromRGB(37, 150, 190), // teal
];

class TileLayoutDemoView extends StatelessComponent {
  const TileLayoutDemoView({super.key});

  @override
  Component build(BuildContext context) {
    final countIdx = context.watch(_countIdxProvider);
    final colsIdx = context.watch(_colsIdxProvider);
    final seed = context.watch(_seedProvider);

    final count = _countCycle[countIdx];
    final cols = _colsCycle[colsIdx];
    final heights = _genHeights(count, seed);

    final tiles = <SizedTile>[
      for (var i = 0; i < count; i++)
        (widget: _buildSyntheticTile(i, heights[i]), height: heights[i]),
    ];

    final assignments = assignColumnsByHeight(heights, cols);
    final colTotals = assignments
        .map((col) => col.fold<int>(0, (s, i) => s + heights[i]))
        .toList();
    final maxTotal = colTotals.isEmpty
        ? 0
        : colTotals.reduce((a, b) => a > b ? a : b);
    final minTotal = colTotals.isEmpty
        ? 0
        : colTotals.reduce((a, b) => a < b ? a : b);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          final k = event.logicalKey;
          if (k == LogicalKey.escape) {
            context.read(currentDevViewProvider.notifier).state = DevView.menu;
            return true;
          }
          if (k == LogicalKey.keyN) {
            _cycle(context, _countIdxProvider, _countCycle.length);
            return true;
          }
          if (k == LogicalKey.keyC) {
            _cycle(context, _colsIdxProvider, _colsCycle.length);
            return true;
          }
          if (k == LogicalKey.keyR) {
            context.read(_seedProvider.notifier).state =
                DateTime.now().millisecondsSinceEpoch & 0xfffff;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Tile layout demo key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tile layout demo — $count tiles, $cols column${cols == 1 ? "" : "s"}'
              '   col totals: ${colTotals.join(' / ')}'
              '   imbalance: ${maxTotal - minTotal}',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: tileRows(tiles, cols),
                ),
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              '[n] cycle tile count   [c] cycle column count   '
              '[r] re-randomize heights   [Esc] back',
              style: TextStyle(color: Color.fromRGB(120, 120, 140)),
            ),
          ],
        ),
      ),
    );
  }

  void _cycle(BuildContext context, StateProvider<int> p, int len) {
    final cur = context.read(p);
    context.read(p.notifier).state = (cur + 1) % len;
  }

  /// Real `Tile` widget with H-6 body rows so the on-screen footprint
  /// roughly matches the height value we passed to the layout. Lets
  /// the demo verify visually that height-balanced packing produces
  /// columns that look balanced, not just numerically balanced.
  Component _buildSyntheticTile(int index, int height) {
    final accent = _accentColors[index % _accentColors.length];
    final bodyRows = (height - 6).clamp(0, height);
    return Tile(
      title: 'tile #$index',
      accent: accent,
      statusLabel: 'h=$height',
      rows: [
        for (var r = 0; r < bodyRows; r++) TileRow('row $r', '·' * (1 + r % 5)),
      ],
    );
  }
}

List<int> _genHeights(int count, int seed) {
  final r = Random(seed);
  return List.generate(
    count,
    (_) => _minTileHeight + r.nextInt(_maxTileHeight - _minTileHeight + 1),
  );
}
