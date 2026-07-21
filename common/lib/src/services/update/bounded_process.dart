import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Like [Process.run] but bounded by [timeout].
///
/// [Process.run] gives no handle on the child, so a wedged subprocess
/// can never be interrupted — an offline `nix flake update` blocks
/// forever on its git/https fetch to the forge and the caller's
/// `await` never returns. This variant drives the child through
/// [Process.start] so that on timeout it is SIGKILLed and a
/// [TimeoutException] carrying an actionable [label] is thrown instead
/// of hanging.
///
/// stdout and stderr are drained concurrently — mirroring
/// `readPluginAppVersion` — so a chatty child can't deadlock on a full
/// pipe buffer while we await its exit. The returned [ProcessResult]
/// is shaped exactly like [Process.run]'s (`exitCode`, `stdout` and
/// `stderr` as decoded strings) so a call site can swap one for the
/// other unchanged.
Future<ProcessResult> runBounded(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
  String? label,
}) async {
  final proc = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
  final stderrFuture = proc.stderr.transform(utf8.decoder).join();

  var timedOut = false;
  final exitCode = await proc.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
      return -1;
    },
  );

  if (timedOut) {
    // The child was just killed; reap its now-closing pipes in the
    // background so we leave no dangling stream subscriptions, and
    // discard whatever partial output it managed to produce.
    unawaited(stdoutFuture.catchError((_) => ''));
    unawaited(stderrFuture.catchError((_) => ''));
    throw TimeoutException(
      '${label ?? '$executable ${arguments.join(' ')}'} timed out after '
      '${timeout.inSeconds}s — the network may be unreachable '
      '(check tailscale / connectivity to the forge).',
      timeout,
    );
  }

  return ProcessResult(
    proc.pid,
    exitCode,
    await stdoutFuture,
    await stderrFuture,
  );
}
