import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:common/common.dart';

import '../build_info.dart';

/// `nixblitz check` — probe upstream + run the unified update
/// check. Invoked by the systemd timer that surfaces "X updates
/// available" on the dashboard, and by the in-TUI `[c]` action
/// which spawns this same binary.
///
/// Exits 0 when the check ran (even if it found inputs ahead);
/// non-zero only on infrastructural failure (network, parse, missing
/// flake.lock, nix subprocess failure).
class CheckCommand extends Command<int> {
  CheckCommand(this.baseDir);

  final String baseDir;

  @override
  final String name = 'check';

  @override
  final String description =
      'Run an update check now and stage candidate updates for Apply.';

  @override
  Future<int> run() async {
    final svc = UpdateCheckService(
      flakePath: baseDir,
      statusPath: updateStatusPath,
      runningGitHash: buildGitHash,
    );
    try {
      return await svc.runCheck();
    } catch (e) {
      stderr.writeln('error: $e');
      return 1;
    } finally {
      svc.close();
    }
  }
}
