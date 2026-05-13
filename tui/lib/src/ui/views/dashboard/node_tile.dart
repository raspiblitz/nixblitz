import 'package:nocterm/nocterm.dart';

import '../../widgets/tile.dart';

/// Node-status tile: collapses what used to be a multi-line wall of
/// text at the top of the dashboard (apply-state line, pending-changes
/// banner, updates-available banner) into one boxed tile that lives
/// in the dashboard grid alongside Bitcoin / Lightning / Hardware /
/// System.
///
/// Both the operator's own edits and upstream input bumps end in the
/// same `nixos-rebuild` operation underneath — `[u]` Update is just
/// `nix flake update && [a] Apply`. The tile reflects that: one
/// "X to apply" status label in the title bar, with `system updates`
/// and `config changes` rows in the body breaking down WHERE the
/// changes came from. No per-row coloring; the labels do the
/// disambiguation.
///
/// Action prompts (`[a]` Apply, `[u]` Update) deliberately do NOT
/// appear inside the tile — they live in the dashboard's keybind
/// footer. Tiles are passive readouts.
class NodeTile extends StatelessComponent {
  /// Total terminal-row footprint of this tile, used by
  /// [tileRows] / [assignColumnsByHeight] for height-balanced
  /// column packing. 4 content rows (uptime, last apply, system
  /// updates, config changes) plus chrome (border, title, padding,
  /// spacer), plus an optional "unapplied rebuild" row.
  static int tileHeightFor({bool unappliedRebuild = false}) =>
      10 + (unappliedRebuild ? 1 : 0);

  final String hostname;
  final int? uptimeSec;
  final String? appliedAgoText;
  final int configChangesCount;
  final List<String> configChangesNames;
  final int systemUpdatesCount;
  final List<String> systemUpdateSources;

  /// HEAD has commits beyond what `/run/current-system` was built
  /// from. Catches the "operator quit between `git commit` and
  /// `nixos-rebuild` exit-0" case — see
  /// `apply_view._recordApplied` for where the baseline is written.
  final bool unappliedRebuild;

  const NodeTile({
    super.key,
    required this.hostname,
    this.uptimeSec,
    this.appliedAgoText,
    this.configChangesCount = 0,
    this.configChangesNames = const [],
    this.systemUpdatesCount = 0,
    this.systemUpdateSources = const [],
    this.unappliedRebuild = false,
  });

  static const _orange = Color.fromRGB(247, 147, 26);
  static const _green = Color.fromRGB(110, 220, 110);
  static const _white = Color.fromRGB(220, 220, 220);

  @override
  Component build(BuildContext context) {
    final rows = <TileRow>[];

    if (uptimeSec != null) {
      rows.add(TileRow('uptime', _formatUptime(uptimeSec!)));
    }

    rows.add(TileRow('last apply', appliedAgoText ?? 'never'));
    rows.add(
      TileRow(
        'system updates',
        _formatNamed(systemUpdatesCount, systemUpdateSources),
      ),
    );
    rows.add(
      TileRow(
        'config changes',
        _formatNamed(configChangesCount, configChangesNames),
      ),
    );
    if (unappliedRebuild) {
      rows.add(const TileRow('unapplied rebuild', 'yes'));
    }

    final total =
        systemUpdatesCount + configChangesCount + (unappliedRebuild ? 1 : 0);

    return Tile(
      title: hostname,
      accent: _white,
      statusLabel: total > 0 ? '$total to apply' : 'all applied',
      statusColor: total > 0 ? _orange : _green,
      rows: rows,
    );
  }

  static String _formatNamed(int count, List<String> names) {
    if (names.isEmpty) return '$count';
    final shown = names.take(2).join(', ');
    final remaining = count - 2;
    if (remaining > 0) return '$count ($shown, +$remaining)';
    return '$count ($shown)';
  }

  /// Compact uptime like the existing `formatDuration` helper but
  /// scaled to fit a tile value column: `42s` / `7m` / `21h 7m` /
  /// `2d 16h`. Mirrors what the system tile already shows so the row
  /// looks at home next to it.
  static String _formatUptime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final remMinutes = minutes % 60;
    if (hours < 24) return '${hours}h ${remMinutes}m';
    final days = hours ~/ 24;
    final remHours = hours % 24;
    return '${days}d ${remHours}h';
  }
}
