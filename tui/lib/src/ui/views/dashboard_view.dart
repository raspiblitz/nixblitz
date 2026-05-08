import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'dashboard/node_tile.dart';
import 'dashboard/plugin_tile.dart';
import 'dashboard/tile_layout.dart';
import 'dashboard/tile_renderer.dart';
import '../format.dart';
import '../../providers/ui_state_provider.dart';

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

  /// Build one [PluginTile] per installed plugin whose manifest
  /// declares a `dashboard` block. Sorted alphabetically by
  /// manifest title for stable layout regardless of install order.
  /// Plugins whose manifests fail to parse are silently skipped
  /// (logged); the dashboard staying functional matters more than
  /// surfacing per-plugin manifest errors here.
  List<Component> _pluginTiles(BuildContext context) {
    final manifests = context.watch(installedPluginsProvider);
    final entries = <({String id, String title, String accent})>[];
    for (final m in manifests) {
      final spec = m.dashboard;
      if (spec == null) continue;
      entries.add((id: m.id, title: spec.title, accent: spec.accentColorHex));
    }
    entries.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return [
      for (final e in entries)
        PluginTile(
          dirName: e.id,
          fallbackTitle: e.title,
          accentColorHex: e.accent,
        ),
    ];
  }

  Component _buildNodeTile(BuildContext context, NixblitzConfig config) {
    final lastApply = context.watch(lastApplyTimeProvider);
    final appliedAgoText = lastApply.maybeWhen(
      data: (t) => t == null ? null : humanizeAge(t),
      orElse: () => null,
    );

    final updateStatus = readUpdateStatus();
    final light = updateStatus.lightweight;
    final updateSources = <String>[];
    if (light != null && light.ok && light.inputsAhead.isNotEmpty) {
      // filterStillAhead drops phantom updates whose lock has
      // already advanced since the cached check.
      final stillAhead = UpdateCheckService.filterStillAhead(
        light.inputsAhead,
        flakePath: context.read(baseDirProvider),
      );
      updateSources.addAll(stillAhead.map((e) => e.name));
    }
    final drift = context.watch(templatesDriftProvider);
    final systemUpdatesCount = updateSources.length + (drift.hasDrift ? 1 : 0);

    // Count is unique sections (apps with edits), not key-count.
    final pendingKeys = context.watch(pendingChangeKeysProvider);
    final configSections = <String>{};
    for (final k in pendingKeys) {
      final dot = k.indexOf('.');
      configSections.add(dot >= 0 ? k.substring(0, dot) : k);
    }
    final configChangesNames = configSections.toList()..sort();

    return NodeTile(
      hostname: config.system.hostname,
      uptimeSec: _readUptimeSec(context),
      appliedAgoText: appliedAgoText,
      systemUpdatesCount: systemUpdatesCount,
      systemUpdateSources: updateSources,
      configChangesCount: configChangesNames.length,
      configChangesNames: configChangesNames,
    );
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

        // Build one TileRenderer per bundled manifest, each wired to
        // its live snapshot. The snapshot is seeded from the cache so
        // a late subscriber sees data immediately (no flicker through
        // loading state on re-entry).
        final manifests = context.watch(tileManifestsProvider);
        final bundledTiles = <Component>[
          for (final m in manifests)
            TileRenderer(
              manifest: m,
              snapshot:
                  context.watch(tileSnapshotProvider(m.id)).value ??
                  const TileSnapshot(),
            ),
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Identity-continuity caveat — see plugin-trust-models.md §5.4.
            if (pendingCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: const Text(
                  'review pending edits before applying — '
                  'an external process may have modified the tracked tree',
                  style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cols = columnsFor(constraints.maxWidth);
                    final pluginTiles = _pluginTiles(context);
                    final tiles = <Component>[
                      _buildNodeTile(context, config),
                      ...bundledTiles,
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

/// Reads the system tile's `uptime_sec` from the cache without
/// throwing when no event has arrived yet.
int? _readUptimeSec(BuildContext context) {
  final cache = context.read(tileDataCacheProvider);
  final v = cache.snapshotFor('system').data['uptime_sec'];
  return v is num ? v.toInt() : null;
}
