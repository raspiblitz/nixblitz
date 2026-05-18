import 'dart:io';

import 'package:args/args.dart';
import 'package:common/common.dart';

/// Entry point for `nixblitz check`. Runs outside the TUI — invoked
/// by the systemd timer that surfaces "X updates available" on the
/// dashboard, or by the in-TUI `[c]` action which spawns this same
/// binary.
///
/// Exits 0 when the check ran (even if it found inputs ahead);
/// non-zero only on infrastructural failure (network, parse, missing
/// flake.lock, nix subprocess failure).
Future<int> runCheckCli(ArgResults checkArgs, String baseDir) async {
  if (checkArgs.command != null) {
    stderr.writeln(
      'nixblitz check no longer takes a subcommand — the previous '
      "`light` / `heavy` split has been collapsed into a single run.\n"
      'Usage: nixblitz check',
    );
    return 2;
  }

  final updateCheckService = UpdateCheckService(
    flakePath: baseDir,
    statusPath: updateStatusPath,
  );
  try {
    return await updateCheckService.runCheck();
  } catch (e) {
    stderr.writeln('error: $e');
    return 1;
  } finally {
    updateCheckService.close();
  }
}
