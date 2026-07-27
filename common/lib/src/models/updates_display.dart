import 'package:common/src/models/update_status.dart';

/// Per-row status on the simplified Updates screen.
enum UpdateRowStatus { upToDate, updateAvailable, notChecked }

/// View-model for the Updates panel, derived from a [CheckResult]. Pure:
/// the mapper takes the already-filtered ahead-input count so it does no
/// IO and stays unit-testable. See
/// docs/superpowers/specs/2026-06-28-updates-screen-simplify-design.md.
class UpdatesDisplay {
  /// "NixBlitz" = all non-plugin flake inputs rolled up. updateAvailable
  /// when any input is still ahead.
  final UpdateRowStatus nixblitz;

  /// "Plugins" = the auto-update plugin probe.
  final UpdateRowStatus plugins;

  /// Count behind the Plugins row ("N updates available").
  final int pluginsAheadCount;

  /// Plain-language note about the net effect of applying, or null when
  /// there is nothing to say (everything up to date).
  final String? applyNote;

  /// Whether the "What's changing…" drill-down has anything to show.
  final bool detailsAvailable;

  /// Plain-language probe error, or null when the last check was ok / absent.
  final String? error;

  const UpdatesDisplay({
    required this.nixblitz,
    required this.plugins,
    required this.pluginsAheadCount,
    required this.applyNote,
    required this.detailsAvailable,
    required this.error,
  });
}

/// Map a [CheckResult] (+ the count of inputs still ahead after
/// `filterStillAhead`) to the Updates panel view-model.
UpdatesDisplay mapUpdatesDisplay({
  required CheckResult? result,
  required int aheadInputCount,
}) {
  if (result == null) {
    return const UpdatesDisplay(
      nixblitz: UpdateRowStatus.notChecked,
      plugins: UpdateRowStatus.notChecked,
      pluginsAheadCount: 0,
      applyNote: null,
      detailsAvailable: false,
      error: null,
    );
  }
  if (!result.ok) {
    return UpdatesDisplay(
      nixblitz: UpdateRowStatus.notChecked,
      plugins: UpdateRowStatus.notChecked,
      pluginsAheadCount: 0,
      applyNote: null,
      detailsAvailable: false,
      error: result.error ?? "Couldn't check for updates",
    );
  }

  final pluginsCount = result.pluginsAhead.length;
  // Two movement signals, either one lights the row: the network
  // probe's rev comparison (aheadInputCount), and the check's own
  // semantic lock diff (lockInputsMoved). The latter is the ONLY
  // signal on offline-installed nodes — their nixblitz input is a
  // `path:` pin the probe cannot query, so the probe alone showed
  // "up to date" while a staged update sat in the log.
  final nixblitzAhead =
      aheadInputCount > 0 || result.lockInputsMoved.isNotEmpty;
  final pluginsAhead = pluginsCount > 0;
  final hasDiff = result.diffText.trim().isNotEmpty;

  final String? note;
  if (result.compileNeeded) {
    final n = result.wouldBuild.length;
    note =
        'Applying builds $n package${n == 1 ? '' : 's'} on the node first '
        '— can be slow on a Pi.';
  } else if (!result.noChanges && hasDiff) {
    note = 'Applying downloads prebuilt packages (no local build).';
  } else if (nixblitzAhead || pluginsAhead) {
    note =
        'Inputs moved but the built system is unchanged — applying re-pins, '
        'nothing rebuilds.';
  } else {
    note = null;
  }

  return UpdatesDisplay(
    nixblitz: nixblitzAhead
        ? UpdateRowStatus.updateAvailable
        : UpdateRowStatus.upToDate,
    plugins: pluginsAhead
        ? UpdateRowStatus.updateAvailable
        : UpdateRowStatus.upToDate,
    pluginsAheadCount: pluginsCount,
    applyNote: note,
    detailsAvailable:
        nixblitzAhead ||
        pluginsAhead ||
        result.wouldBuild.isNotEmpty ||
        hasDiff,
    error: null,
  );
}
