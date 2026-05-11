import 'package:common/common.dart';

/// Per-action gating result for the System Update menu.
class ActionState {
  const ActionState({required this.enabled, required this.subtitle});
  final bool enabled;
  final String subtitle;
}

/// Computed state for the two gated actions in `_buildSelectMode`.
class UpdateActionStates {
  const UpdateActionStates({required this.tuiOnly, required this.entireSystem});
  final ActionState tuiOnly;
  final ActionState entireSystem;
}

/// Returns true when [status.heavy]'s `diffText` should be treated
/// as stale.
///
/// Heavy is stale when a more recent lightweight check found the
/// live `flake.lock` already at upstream — meaning a `nix flake
/// update` would now be a no-op, regardless of what heavy was
/// diffing against at its `checkedAt` time. Without this filter we
/// surface "1 change pending" hours after the operator already
/// ran an Update and caught the lock up.
///
/// [liveInputsAhead] is the renderer-filtered (`filterStillAhead`)
/// list — passed in rather than computed here so this function
/// stays pure and the heavy I/O of reading `flake.lock` lives at
/// the call site.
bool isHeavyDiffStale(
  UpdateStatus status, {
  required List<InputAhead> liveInputsAhead,
}) {
  final heavy = status.heavy;
  final light = status.lightweight;
  if (heavy == null || light == null || !light.ok) return false;
  if (!light.checkedAt.isAfter(heavy.checkedAt)) return false;
  return liveInputsAhead.isEmpty;
}

/// Pure function — no I/O, no providers — derives the action panel's
/// gating from a snapshot of `update-status.json`.
///
/// [tuiInputName] is the name of the flake input that pins the TUI
/// binary (`nixblitz` for the default install). Filtering it out of
/// the "flake inputs" status row and into the "TUI binary" row is
/// done in the renderer; this function only consumes [LightCheck].
///
/// [liveInputsAhead] is the renderer-filtered (`filterStillAhead`)
/// view of `light.inputsAhead`. Used to detect when the heavy diff
/// has been invalidated by a lock advance since heavy ran.
///
/// [now] is injected for testability.
UpdateActionStates computeUpdateActionStates(
  UpdateStatus status, {
  required String tuiInputName,
  required List<InputAhead> liveInputsAhead,
  DateTime? now,
}) {
  final wallClock = now ?? DateTime.now().toUtc();

  // ── tuiOnly ────────────────────────────────────────────────
  final light = status.lightweight;
  final tuiAhead = liveInputsAhead
      .where((i) => i.name == tuiInputName)
      .toList();

  final ActionState tuiOnly;
  if (tuiAhead.isNotEmpty) {
    tuiOnly = const ActionState(
      enabled: true,
      subtitle: 'TUI repo is ahead — rebuild advances it',
    );
  } else if (light == null) {
    // No light check has run yet — don't block the user. Let them
    // rebuild if they want; surface the missing data instead of a
    // hard "disabled" state.
    tuiOnly = const ActionState(enabled: true, subtitle: 'no light check yet');
  } else {
    tuiOnly = const ActionState(enabled: false, subtitle: 'up to date');
  }

  // ── entireSystem ────────────────────────────────────────────
  final heavy = status.heavy;
  late final ActionState entire;
  if (heavy == null) {
    entire = const ActionState(
      enabled: true,
      subtitle: 'no full check yet — press [C] to run one',
    );
  } else if (!heavy.ok) {
    entire = ActionState(
      enabled: true,
      subtitle: 'last full check failed: ${_briefError(heavy.error)}',
    );
  } else if (heavy.noChanges ||
      isHeavyDiffStale(status, liveInputsAhead: liveInputsAhead)) {
    final heavyStale =
        wallClock.difference(heavy.checkedAt) > const Duration(days: 14);
    final liveAheadNonTui = liveInputsAhead
        .where((i) => i.name != tuiInputName)
        .toList();
    if (heavyStale && liveAheadNonTui.isNotEmpty) {
      entire = const ActionState(
        enabled: true,
        subtitle: 'may have changes — heavy check stale (>14d)',
      );
    } else {
      entire = const ActionState(
        enabled: false,
        subtitle: 'no changes pending',
      );
    }
  } else {
    final n = _countDiffChanges(heavy.diffText);
    entire = ActionState(
      enabled: true,
      subtitle: n == 1 ? '1 change pending' : '$n changes pending',
    );
  }

  return UpdateActionStates(tuiOnly: tuiOnly, entireSystem: entire);
}

/// Condense a heavy-check error blob into a single short line for
/// the action subtitle. The raw error is the full stderr from
/// `nix flake update` (or wherever) — multi-line, full of retry
/// warnings, stack traces, store paths. Useful for the log file,
/// awful in a one-line menu subtitle.
///
/// Strategy: scan lines, prefer one that looks like a concrete
/// "Could not resolve host" / "404" / "permission denied" tail,
/// otherwise the first non-empty line. Clip to a width that won't
/// wrap most terminals. Full error stays on `HeavyCheck.error` for
/// log-driven diagnosis.
String _briefError(String? raw) {
  if (raw == null || raw.trim().isEmpty) return 'unknown';
  final lines = raw
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return 'unknown';

  // Network-flavored summary takes precedence over the framing
  // line ("nix flake update failed (exit 1): warning: error: …")
  // because the framing tells you what tool failed, not what went
  // wrong.
  for (final l in lines) {
    if (l.contains('Could not resolve host')) {
      return 'no network (DNS resolution failed)';
    }
    if (l.contains('Network is unreachable') ||
        l.contains('Connection refused') ||
        l.contains('Connection timed out')) {
      return 'no network';
    }
  }

  final first = lines.first;
  const maxLen = 100;
  return first.length <= maxLen ? first : '${first.substring(0, maxLen - 1)}…';
}

/// Counts `[U./A./R.]` lines — same heuristic as the inline diff
/// renderer in `update_view.dart`. Kept inline (not imported) so
/// `action_gating.dart` has no nocterm dependency.
int _countDiffChanges(String diffText) {
  var n = 0;
  for (final line in diffText.split('\n')) {
    if (line.startsWith('[U.') ||
        line.startsWith('[U]') ||
        line.startsWith('[A.') ||
        line.startsWith('[A]') ||
        line.startsWith('[R.') ||
        line.startsWith('[R]')) {
      n++;
    }
  }
  return n;
}
