import 'package:common/src/services/git_service.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/sbom_service.dart';

/// Outcome of the commit-on-success step.
enum ApplyCommitOutcome { committed, nothingToCommit, sbomFailed }

/// Commit-on-success: run AFTER a successful rebuild. Refresh the SBOM from the
/// now-live system and, only if that succeeds, commit everything (config + lock
/// + SBOM) as one commit. **Strict**: an SBOM-generation failure aborts the
/// commit — the change stays in the working tree (recoverable, retried next
/// Apply) rather than recording a state without its SBOM.
///
/// Both the TUI Apply flow and the CLI `update` path call this so the commit
/// model lives in one place (no pre-rebuild commit, no drift between paths).
/// See docs/superpowers/specs/2026-06-28-sbom-version-tracking-design.md.
Future<ApplyCommitOutcome> generateSbomAndCommit({
  required GitService git,
  required String baseDir,
  required String message,
  SbomService sbom = const SbomService(),
}) async {
  final ok = await sbom.generate(
    closure: '/run/current-system',
    outPath: '$baseDir/sbom.cdx.json',
  );
  if (!ok) {
    LogService.warn(
      'apply: SBOM generation failed — rebuilt but NOT committing (strict)',
    );
    return ApplyCommitOutcome.sbomFailed;
  }
  final committed = await git.commitAll(message);
  return committed
      ? ApplyCommitOutcome.committed
      : ApplyCommitOutcome.nothingToCommit;
}
