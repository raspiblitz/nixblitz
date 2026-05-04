import 'dart:io';

import 'package:args/args.dart';
import 'package:common/common.dart';

/// Entry point for `nixblitz check {light,heavy}`. Runs outside the
/// TUI — invoked by the systemd timers that surface "X updates
/// available" on the dashboard.
///
/// Exits 0 when the check ran (even if it found inputs ahead);
/// non-zero only on infrastructural failure (network, parse, missing
/// flake.lock).
Future<int> runCheckCli(ArgResults checkArgs, String baseDir) async {
  final sub = checkArgs.command;
  if (sub == null) {
    stderr.writeln('Usage: nixblitz check <light|heavy>');
    return 2;
  }

  final updateCheckService = UpdateCheckService(
    flakePath: baseDir,
    statusPath: updateStatusPath,
  );
  try {
    switch (sub.name) {
      case 'light':
        final code = await updateCheckService.runLightweight();
        return code;
      case 'heavy':
        final code = await updateCheckService.runHeavy();
        return code;
      default:
        stderr.writeln('unknown verb: ${sub.name}');
        return 2;
    }
  } catch (e) {
    stderr.writeln('error: $e');
    return 1;
  } finally {
    updateCheckService.close();
  }
}
