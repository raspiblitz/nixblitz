import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import 'dashboard/bitcoin_tile.dart';
import 'dashboard/hardware_tile.dart';
import 'dashboard/lightning_tile.dart';
import 'dashboard/plugin_tile.dart';
import 'dashboard/system_tile.dart';
import 'dashboard/tile_layout.dart';
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
    final svc = context.read(pluginServiceProvider);
    final entries = <({String dirName, String title, String accent})>[];
    for (final p in config.plugins) {
      if (p.uninstalledAt != null || !p.enabled) continue;
      try {
        final manifest = svc.readManifest(p.dirName);
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
  /// the daily / weekly systemd timers) and renders a banner when
  /// either check found something to surface. No banner when the
  /// file is missing (fresh install), no inputs ahead, or all the
  /// timers have run cleanly with nothing to report.
  List<Component> _buildUpdateAvailableBanner() {
    final status = readUpdateStatus();
    final lines = <Component>[];

    final light = status.lightweight;
    if (light != null && light.ok && light.inputsAhead.isNotEmpty) {
      final n = light.inputsAhead.length;
      final names = light.inputsAhead.map((e) => e.name).take(3).join(', ');
      final more = n > 3 ? ' (+${n - 3} more)' : '';
      final ago = _humanizeAge(light.checkedAt);
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

    final heavy = status.heavy;
    if (heavy != null &&
        heavy.ok &&
        !heavy.noChanges &&
        heavy.diffText.trim().isNotEmpty) {
      final firstLine = heavy.diffText
          .split('\n')
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      final ago = _humanizeAge(heavy.checkedAt);
      lines.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            'preview ($ago): $firstLine',
            style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ),
      );
    }

    return lines;
  }

  /// Surfaces template-content drift between the binary and
  /// `~/nixblitz/`. Triggered when an updated TUI binary ships
  /// new template content without bumping the config schema —
  /// the case the page-size-16k fix slipped through. Operator
  /// presses [r] (handled in app.dart's dashboard branch) to
  /// refresh + advance to the apply view.
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
              'from this binary — press [r] to refresh',
              style: const TextStyle(color: Color.fromRGB(255, 200, 80)),
            ),
            const Text(
              '  refresh writes the binary\'s embedded copies over '
              'the on-disk files, leaves the tree dirty for [a] Apply',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    ];
  }

  static String _humanizeAge(DateTime t) {
    final diff = DateTime.now().toUtc().difference(t.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
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
                    style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                  ),
                ],
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
              ),
            ..._buildUpdateAvailableBanner(),
            ..._buildDriftBanner(context),
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
