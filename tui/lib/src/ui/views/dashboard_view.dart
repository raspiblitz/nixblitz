import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'dashboard/dashboard_chrome.dart';
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

  /// Build one [PluginTile] per active plugin whose manifest declares
  /// a `dashboard` block. Sorted alphabetically by manifest title for
  /// stable layout regardless of install order. Plugins whose
  /// manifests fail to parse are silently skipped (logged); the
  /// dashboard staying functional matters more than surfacing
  /// per-plugin manifest errors here.
  List<Component> _pluginTiles(BuildContext context, NixblitzConfig config) {
    final pluginService = context.read(pluginServiceProvider);
    final entries = <({String dirName, String title, String accent})>[];
    for (final p in config.plugins) {
      if (p.uninstalledAt != null || !p.enabled) continue;
      try {
        final manifest = pluginService.readManifest(p.dirName);
        final spec = manifest.dashboard;
        if (spec == null) continue;
        entries.add((
          dirName: p.dirName,
          title: spec.title,
          accent: spec.accentColorHex,
        ));
      } catch (e, st) {
        LogService.warn('dashboard: skipping plugin ${p.dirName}: $e');
        LogService.error('manifest read', e, st);
      }
    }
    entries.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return [
      for (final e in entries)
        PluginTile(
          dirName: e.dirName,
          fallbackTitle: e.title,
          accentColorHex: e.accent,
        ),
    ];
  }

  /// Reads `/var/lib/nixblitz-tui/update-status.json` (populated by
  /// the daily / weekly systemd timers) and renders a single
  /// "updates available" line when the lightweight check found
  /// flake inputs whose upstream HEAD has moved past the locked
  /// rev. The richer per-package preview (from the heavy check)
  /// is surfaced inside the Update menu, not on the dashboard —
  /// the dashboard's job is to nudge, not to enumerate.
  ///
  /// Cross-checks the cached `inputsAhead` against the live
  /// `flake.lock` so we don't keep nagging "updates available" for
  /// inputs whose lock has already advanced (e.g. after the
  /// operator ran Update once between scheduled checks). Without
  /// this, the dashboard banner would report a phantom update and
  /// the Update flow's `nix flake update` would correctly say
  /// "Nothing to apply" — confusing.
  List<Component> _buildUpdateAvailableBanner(BuildContext context) {
    final status = readUpdateStatus();
    final lines = <Component>[];

    final light = status.lightweight;
    if (light != null && light.ok && light.inputsAhead.isNotEmpty) {
      final stillAhead = UpdateCheckService.filterStillAhead(
        light.inputsAhead,
        flakePath: context.read(baseDirProvider),
      );
      if (stillAhead.isNotEmpty) {
        final n = stillAhead.length;
        final names = stillAhead.map((e) => e.name).take(3).join(', ');
        final more = n > 3 ? ' (+${n - 3} more)' : '';
        final ago = humanizeAge(light.checkedAt);
        lines.add(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              'updates available: $names$more — '
              'checked $ago — press [u] Update',
              style: const TextStyle(color: Color.fromRGB(120, 200, 220)),
            ),
          ),
        );
      }
    }

    return lines;
  }

  /// Surfaces template-content drift between the binary and
  /// `~/nixblitz/`. Triggered when an updated TUI binary ships
  /// new template content without bumping the config schema —
  /// the case the page-size-16k fix slipped through. Apply and
  /// Update both auto-rewrite drifted templates as a preflight,
  /// so the operator just needs to run either one.
  List<Component> _buildDriftBanner(BuildContext context) {
    final drift = context.watch(templatesDriftProvider);
    if (!drift.hasDrift) return const [];
    final n = drift.totalChanged;
    return [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '! $n template '
              '${n == 1 ? "file differs" : "files differ"} '
              '— TUI was upgraded, run [a] Apply or [u] Update to rebuild',
              style: const TextStyle(color: Color.fromRGB(255, 200, 80)),
            ),
            const Text(
              '  Apply and Update auto-rewrite drifted templates '
              'before rebuilding',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    ];
  }

  /// Renders the green "all applied — Xm ago" caption when the
  /// working tree is clean and HEAD has a commit. Empty list
  /// when HEAD is missing (fresh install, pre-first-Apply) so we
  /// don't surface a confusing "applied …" line on a repo that's
  /// never been applied.
  List<Component> _buildAllAppliedLine(BuildContext context) {
    final lastApply = context.watch(lastApplyTimeProvider);
    final ago = lastApply.maybeWhen(
      data: (t) => t == null ? null : humanizeAge(t),
      orElse: () => null,
    );
    if (ago == null) return const [];
    return [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          '~ all applied — last apply $ago',
          style: const TextStyle(color: Color.fromRGB(110, 220, 110)),
        ),
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: DashboardChrome(
                hostname: config.system.hostname,
                platform: config.system.platform,
                network: config.appOption<String>('bitcoind', 'network'),
                uptimeSec: _readUptimeSec(context),
                appliedAgo:
                    null, // Stub; future task wires git_provider's last-applied
              ),
            ),
            if (pendingCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '! $pendingCount pending '
                      '${pendingCount == 1 ? "change" : "changes"} '
                      '— press [a] to review',
                      style: const TextStyle(
                        color: Color.fromRGB(247, 147, 26),
                      ),
                    ),
                    // Identity-continuity caveat (Approach A,
                    // §5.4 Layer 1 of plugin-trust-models.md): the
                    // dirty tree could be the operator's own edits
                    // OR an out-of-band tamper. The TUI can't tell
                    // from the diff alone; flag the dual reading
                    // so the operator reviews unfamiliar entries.
                    const Text(
                      '  if you don\'t recognise these, an external '
                      'process may have modified the tracked tree',
                      style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                    ),
                  ],
                ),
              )
            else
              ..._buildAllAppliedLine(context),
            ..._buildUpdateAvailableBanner(context),
            ..._buildDriftBanner(context),
            const SizedBox(height: 1),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cols = columnsFor(constraints.maxWidth);
                    final pluginTiles = _pluginTiles(context, config);
                    final tiles = <Component>[...bundledTiles, ...pluginTiles];
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
