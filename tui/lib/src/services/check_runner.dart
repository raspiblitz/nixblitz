import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

/// Mode of the currently-running `nixblitz check` subprocess (`light`
/// / `heavy`), or `null` if none. UI uses this to render the "Running
/// … check" spinner and to gate the re-trigger handler so the operator
/// can't queue overlapping checks.
final runningCheckProvider = StateProvider<String?>((ref) => null);

/// Bumped each time a check subprocess exits. Views watching this know
/// to re-read `update-status.json` after a check completes.
final checkRefreshTickProvider = StateProvider<int>((ref) => 0);

/// Path to the persisted check result that the systemd timers and the
/// in-TUI `runCheckSubprocess` both write into.
const String _statusPath = '/var/lib/nixblitz-tui/update-status.json';

/// Status-file age beyond which TUI startup auto-fires a light check.
/// The daily timer covers steady-state nodes; this threshold catches
/// the "I just updated and want fresh status, not yesterday's
/// snapshot" case without making the operator wait for the next
/// timer fire.
const Duration _kStaleThreshold = Duration(minutes: 30);

/// Per-process guard. `_Shell` rebuilds on every provider change, so
/// we'd otherwise fire a startup check on every keystroke.
bool _startupCheckFired = false;

/// Fire `nixblitz check light` in the background if the cached status
/// is missing or older than [_kStaleThreshold]. Idempotent: at most
/// one auto-trigger per process. Best-effort — never throws.
void maybeAutoStartupCheck(BuildContext ctx) {
  if (_startupCheckFired) return;
  _startupCheckFired = true;
  try {
    final f = File(_statusPath);
    if (f.existsSync()) {
      final age = DateTime.now().toUtc().difference(
        f.statSync().modified.toUtc(),
      );
      if (age < _kStaleThreshold) {
        LogService.info(
          'update-status.json age=${age.inMinutes}m < '
          '${_kStaleThreshold.inMinutes}m; skipping auto-startup check',
        );
        return;
      }
    }
    LogService.info(
      'update-status is stale or missing; '
      'auto-firing nixblitz check light at startup',
    );
    runCheckSubprocess(ctx, 'light');
  } catch (e, st) {
    LogService.error('Auto-startup check failed', e, st);
  }
}

/// Spawn `nixblitz check <mode>` as a background subprocess. Updates
/// [runningCheckProvider] for the duration and bumps
/// [checkRefreshTickProvider] on exit so anyone watching the cached
/// status re-reads it.
void runCheckSubprocess(BuildContext ctx, String mode) {
  if (ctx.read(runningCheckProvider) != null) return;
  ctx.read(runningCheckProvider.notifier).state = mode;
  LogService.info('System check started: nixblitz check $mode');

  Process.start('nixblitz', ['check', mode])
      .then((proc) async {
        // Drain stdout/stderr so they don't backpressure the
        // subprocess. The cached update-status.json is what gets
        // read after — actual stdout content isn't shown inline.
        proc.stdout.drain<void>();
        proc.stderr.drain<void>();
        final code = await proc.exitCode;
        LogService.info('System check exited: $mode (code $code)');
        ctx.read(runningCheckProvider.notifier).state = null;
        ctx.read(checkRefreshTickProvider.notifier).state++;
      })
      .catchError((Object e, StackTrace st) {
        LogService.error('System check failed to start: $mode', e, st);
        ctx.read(runningCheckProvider.notifier).state = null;
      });
}

/// Return value of [readRootFlakeInputs] when the file is missing
/// or unparseable — distinguished from "empty list" so the caller
/// can render a clear error instead of a blank list.
class RootInputsResult {
  const RootInputsResult({required this.inputs, required this.error});
  final List<LockedInput> inputs;

  /// `null` on success; otherwise a short, operator-readable string
  /// explaining what went wrong (missing file / parse error).
  final String? error;
}

/// Enumerate the operator's root flake inputs from
/// `<baseDir>/flake.lock`. Wraps [UpdateCheckService.parseRootInputs]
/// with file-level error handling so the Check panel can render
/// rows even when the daily lightweight check hasn't populated
/// `update-status.json` yet.
RootInputsResult readRootFlakeInputs(String baseDir) {
  try {
    final lockFile = File('$baseDir/flake.lock');
    if (!lockFile.existsSync()) {
      return RootInputsResult(
        inputs: const [],
        error: 'no flake.lock at $baseDir',
      );
    }
    final lock =
        jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
    return RootInputsResult(
      inputs: UpdateCheckService.parseRootInputs(lock),
      error: null,
    );
  } catch (e) {
    return RootInputsResult(inputs: const [], error: 'flake.lock parse: $e');
  }
}
