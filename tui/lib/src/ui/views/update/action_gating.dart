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

/// Pure function — no I/O, no providers — derives the action panel's
/// gating from a snapshot of `update-status.json`.
///
/// [tuiInputName] is the name of the flake input that pins the TUI
/// binary (`nixblitz` for the default install). Filtering it out of
/// the "flake inputs" status row and into the "TUI binary" row is
/// done in the renderer; this function only consumes [LightCheck].
///
/// [now] is injected for testability.
UpdateActionStates computeUpdateActionStates(
  UpdateStatus status, {
  required String tuiInputName,
  DateTime? now,
}) {
  final wallClock = now ?? DateTime.now().toUtc();

  // ── tuiOnly ────────────────────────────────────────────────
  final light = status.lightweight;
  final tuiAhead = light != null && light.ok
      ? light.inputsAhead.where((i) => i.name == tuiInputName).toList()
      : const <InputAhead>[];

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
      subtitle: 'last full check failed: ${heavy.error ?? "unknown"}',
    );
  } else if (heavy.noChanges) {
    final heavyStale =
        wallClock.difference(heavy.checkedAt) > const Duration(days: 14);
    final lightHasOtherHits =
        (light != null &&
        light.ok &&
        light.inputsAhead.where((i) => i.name != tuiInputName).isNotEmpty);
    if (heavyStale && lightHasOtherHits) {
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
