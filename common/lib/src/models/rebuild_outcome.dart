/// Classifies the result of `sudo nixos-rebuild switch` so the TUI
/// can distinguish the common "mostly OK, but a service failed to
/// start" case from a hard build/activation failure.
///
/// Motivation: a plugin (or any service module) can declare a unit
/// that fails its first start — bad credentials, network issue,
/// misconfiguration. nixos-rebuild still activates the new system
/// but exits non-zero. Treating that as "Update Failed" in the UI
/// hides the fact that the config IS applied.
library;

enum RebuildOutcome {
  /// Exit 0. Build, activation, and unit start-up all succeeded.
  success,

  /// Build + activation succeeded (the system is running the new
  /// config), but one or more systemd units failed to (re)start
  /// during activation. Exit non-zero.
  partial,

  /// Build or activation failed. The system is NOT on the new
  /// config (or is in an inconsistent state; nixos-rebuild rolled
  /// back if it got that far). Exit non-zero.
  failure,
}

class RebuildResult {
  final RebuildOutcome outcome;

  /// Names of systemd units that failed during activation, as
  /// reported by nixos-rebuild's
  /// `warning: the following units failed: …` line. Empty when no
  /// such line was observed.
  final List<String> failedUnits;

  const RebuildResult({
    required this.outcome,
    required this.failedUnits,
  });

  /// Classify from the captured rebuild output + exit code.
  static RebuildResult classify(List<String> outputLines, int exitCode) {
    if (exitCode == 0) {
      return const RebuildResult(
        outcome: RebuildOutcome.success,
        failedUnits: [],
      );
    }

    final blob = outputLines.join('\n');
    final activated = _activationMarker.hasMatch(blob);
    final failedUnits = _extractFailedUnits(blob);

    // Activation ran AND we found concrete failing units → partial.
    // (Activation alone without concrete failed-unit markers could
    // still be a real failure — e.g. an activation script that
    // crashed mid-run, which nixos-rebuild reports differently.)
    if (activated && failedUnits.isNotEmpty) {
      return RebuildResult(
        outcome: RebuildOutcome.partial,
        failedUnits: failedUnits,
      );
    }
    return RebuildResult(
      outcome: RebuildOutcome.failure,
      failedUnits: failedUnits,
    );
  }

  // nixos-rebuild prints this line once activation starts. Its
  // presence is a reliable signal that the switch actually happened.
  static final _activationMarker = RegExp(
    r'^activating the configuration\.\.\.',
    multiLine: true,
  );

  static List<String> _extractFailedUnits(String output) {
    // Format: "warning: the following units failed: foo.service bar.service"
    // (whitespace-separated, one per failed unit, on a single line).
    final re = RegExp(
      r'warning: the following units failed: (.+)$',
      multiLine: true,
    );
    final match = re.firstMatch(output);
    if (match == null) return const [];
    return match
        .group(1)!
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }
}
