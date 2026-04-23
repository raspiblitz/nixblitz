import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import 'dashboard/bitcoin_tile.dart';
import 'dashboard/hardware_tile.dart';
import 'dashboard/lightning_tile.dart';
import 'dashboard/system_tile.dart';

class DashboardView extends StatefulComponent {
  const DashboardView({super.key});

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // Responsive column count. Under 80 cols the labels get cramped
  // side-by-side; at 140+ there's enough horizontal room for 3.
  int _columnsFor(double width) {
    if (width < 80) return 1;
    if (width < 140) return 2;
    return 3;
  }

  /// Group tiles into N-wide rows, padding the last row so every tile
  /// in the flex layout gets an equal share.
  List<Component> _tileRows(List<Component> tiles, int cols) {
    final rows = <Component>[];
    for (var i = 0; i < tiles.length; i += cols) {
      final slice = tiles.sublist(i, (i + cols).clamp(0, tiles.length));
      final children = <Component>[];
      for (var j = 0; j < cols; j++) {
        if (j > 0) children.add(const SizedBox(width: 2));
        children.add(
          Expanded(
            child: j < slice.length
                ? slice[j]
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ));
      rows.add(const SizedBox(height: 1));
    }
    return rows;
  }

  bool _handleScrollKey(KeyboardEvent event) {
    final k = event.logicalKey;
    if (k == LogicalKey.arrowUp || k == LogicalKey.keyK) {
      _scroll.scrollUp();
      return true;
    }
    if (k == LogicalKey.arrowDown || k == LogicalKey.keyJ) {
      _scroll.scrollDown();
      return true;
    }
    if (k == LogicalKey.pageUp) {
      _scroll.pageUp();
      return true;
    }
    if (k == LogicalKey.pageDown) {
      _scroll.pageDown();
      return true;
    }
    if (k == LogicalKey.home) {
      _scroll.scrollToStart();
      return true;
    }
    if (k == LogicalKey.end) {
      _scroll.scrollToEnd();
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final pendingAsync = context.watch(pendingChangesProvider);

    return configAsync.when(
      loading: () => const Center(child: Text('Loading config...')),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (config) {
        final pendingCount = pendingAsync.maybeWhen(
          data: (lines) => lines.length,
          orElse: () => 0,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    config.system.hostname,
                    style: const TextStyle(
                      color: Color.fromRGB(220, 220, 220),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${config.system.platform} | ${config.bitcoind.network}',
                    style: const TextStyle(
                      color: Color.fromRGB(150, 150, 180),
                    ),
                  ),
                ],
              ),
            ),
            if (pendingCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '! $pendingCount pending '
                  '${pendingCount == 1 ? "change" : "changes"} '
                  '— press [a] to review',
                  style: const TextStyle(color: Color.fromRGB(247, 147, 26)),
                ),
              ),
            const SizedBox(height: 1),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cols = _columnsFor(constraints.maxWidth);
                    final tiles = <Component>[
                      const SystemTile(),
                      const HardwareTile(),
                      const BitcoinTile(),
                      const LightningTile(),
                    ];
                    return Focusable(
                      focused: true,
                      onKeyEvent: _handleScrollKey,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _tileRows(tiles, cols),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
