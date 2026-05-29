import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/plugin/app_version_command.dart';
import 'package:common/src/services/log_service.dart';

/// Runs a plugin's declared [AppVersionCommand] on demand and returns
/// the trimmed first line of stdout as the app version.
///
/// Runs in the plugin's checkout (`<baseDir>/plugins/<id>/`) so a
/// declared `bash app-version.sh` resolves the shipped script. The
/// command is the same trust surface as the plugin's streamers — the
/// operator already granted that at install.
///
/// Returns:
/// - the version string on success (non-empty stdout, exit 0),
/// - `null` when the command fails, times out, or prints nothing.
///
/// `null` means "ran but couldn't determine a version" — callers
/// surface that as "unavailable". A plugin with no command at all
/// should fall back to its packaging version *without* calling this.
Future<String?> readPluginAppVersion({
  required String baseDir,
  required String pluginId,
  required AppVersionCommand cmd,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final dir = '$baseDir/plugins/$pluginId';
  Process? proc;
  try {
    proc = await Process.start(cmd.command, cmd.args, workingDirectory: dir);
    final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
    // Drain stderr so a chatty command can't fill the pipe and block.
    unawaited(proc.stderr.drain<void>());

    final exitCode = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc?.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (exitCode == -1) {
      LogService.warn(
        'app-version: $pluginId timed out after ${timeout.inSeconds}s',
      );
      return null;
    }

    // Take the first non-empty line — version commands sometimes print
    // extra lines (e.g. `tailscale version` prints three).
    final out = (await stdoutFuture)
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (exitCode != 0 || out.isEmpty) {
      LogService.warn(
        'app-version: $pluginId exited $exitCode '
        '(empty output: ${out.isEmpty})',
      );
      return null;
    }
    return out;
  } catch (e, st) {
    LogService.error('app-version: $pluginId failed to run', e, st);
    return null;
  }
}
