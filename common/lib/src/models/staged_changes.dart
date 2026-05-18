import 'package:common/src/models/update_status.dart' show PluginAhead;

/// Snapshot of what the Apply view would commit + rebuild right now.
///
/// Populated by [UpdateCheckService] each time the periodic timer
/// fires (or the operator triggers `[c]heck` from the Apply view),
/// consumed by the Apply view's review screen, cleared by Apply on a
/// successful rebuild.
///
/// Staging is independent of the user's flake working tree: the
/// candidate `flake.lock` lives in the staging dir until Apply
/// promotes it, so a daily timer fire never mutates
/// `~/nixblitz/flake.lock` behind the operator's back. The
/// "fetched but not yet upgraded" half of an apt-update / apt-upgrade
/// split, adapted for nix.
class StagedChanges {
  const StagedChanges({
    this.lockBumpAvailable = false,
    this.pluginPins = const [],
    this.nvdDiff,
    this.newToplevel,
    this.checkedAt,
  });

  factory StagedChanges.empty() => const StagedChanges();

  /// True when a candidate `flake.lock` is present in staging — i.e.
  /// the last check discovered at least one input had moved.
  final bool lockBumpAvailable;

  /// Plugin pins to apply on the next Apply. Empty when no
  /// auto-update plugin has moved upstream since the last check.
  final List<PluginAhead> pluginPins;

  /// Cached `nvd diff` output for the staged state. Rendered in the
  /// Apply review screen so the operator sees per-package version
  /// deltas before confirming. Null when the last check failed to
  /// produce a diff (eval error, nvd missing, etc.).
  final String? nvdDiff;

  /// Store path of the would-be system toplevel for the staged state.
  /// Lets the Apply view re-run `nvd diff` cheaply without another
  /// full eval.
  final String? newToplevel;

  /// When the staging dir was last populated, used for the
  /// "checked Xh ago" hint on the review screen. UTC.
  final DateTime? checkedAt;

  bool get isEmpty => !lockBumpAvailable && pluginPins.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// Total number of pending categories — 1 for the lock bump (if
  /// any) plus one per staged plugin pin. Used by the dashboard
  /// banner copy.
  int get count => (lockBumpAvailable ? 1 : 0) + pluginPins.length;
}
