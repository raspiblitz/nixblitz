import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import 'dashboard/bitcoin_tile.dart';
import 'dashboard/hardware_tile.dart';
import 'dashboard/lightning_tile.dart';
import 'dashboard/plugin_tile.dart';
import 'dashboard/system_tile.dart';
import 'dashboard/tile_layout.dart';

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

  /// Build one [PluginTile] per active plugin whose manifest declares
  /// a `dashboard` block. Sorted alphabetically by manifest title for
  /// stable layout regardless of install order. Plugins whose
  /// manifests fail to parse are silently skipped (logged); the
  /// dashboard staying functional matters more than surfacing
  /// per-plugin manifest errors here.
  List<Component> _pluginTiles(BuildContext context, NixblitzConfig config) {
    final svc = context.read(pluginServiceProvider);
    final entries = <({String dirName, String title, String accent})>[];
    for (final p in config.plugins) {
      if (p.uninstalledAt != null || !p.enabled) continue;
      try {
        final manifest = svc.readManifest(p.dirName);
        final spec = manifest.dashboard;
        if (spec == null) continue;
        entries.add(
          (dirName: p.dirName, title: spec.title, accent: spec.accentColorHex),
        );
      } catch (e, st) {
        LogService.warn('dashboard: skipping plugin ${p.dirName}: $e');
        LogService.error('manifest read', e, st);
      }
    }
    entries.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return [
      for (final e in entries)
        PluginTile(
          dirName: e.dirName,
          fallbackTitle: e.title,
          accentColorHex: e.accent,
        ),
    ];
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
                    final cols = columnsFor(constraints.maxWidth);
                    final pluginTiles = _pluginTiles(context, config);
                    final tiles = <Component>[
                      const SystemTile(),
                      const HardwareTile(),
                      const BitcoinTile(),
                      const LightningTile(),
                      ...pluginTiles,
                    ];
                    return Focusable(
                      focused: true,
                      onKeyEvent: _handleScrollKey,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: tileRows(tiles, cols),
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
