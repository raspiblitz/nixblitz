import 'dart:io';

import 'package:common/src/services/log_service.dart';

/// Outcome of a [runCheckedSync] invocation. Mirrors the shape callers
/// previously read off a raw [ProcessResult], minus the `dynamic`
/// stdout/stderr typing.
class RunResult {
  const RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

String _fmt(String executable, List<String> args) =>
    args.isEmpty ? executable : '$executable ${args.join(' ')}';

/// Shared shaping for [runCheckedSync] / [runChecked]: type the
/// stdout/stderr, log the invocation + exit code uniformly, and
/// optionally throw on failure.
RunResult _shape(
  String executable,
  List<String> args,
  ProcessResult r,
  bool throwOnError,
) {
  final code = r.exitCode;
  final stdout = (r.stdout as String?) ?? '';
  final stderr = (r.stderr as String?) ?? '';
  LogService.info('run: ${_fmt(executable, args)} → exit $code');
  if (code != 0) {
    final detail = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    LogService.warn('run failed: ${_fmt(executable, args)} → $detail');
    if (throwOnError) {
      throw ProcessException(
        executable,
        args,
        detail.isEmpty ? 'command failed' : detail,
        code,
      );
    }
  }
  return RunResult(exitCode: code, stdout: stdout, stderr: stderr);
}

/// Run [executable] with [args] synchronously, log the invocation and
/// its exit code uniformly, and return a typed [RunResult].
///
/// This is the one place the `tui` package's synchronous flows (nocterm
/// key handlers and confirm callbacks, where async callbacks don't run
/// — see the nocterm pitfalls in CLAUDE.md) reach the system. Keeping
/// the [Process] call in `common` upholds the architecture rule that the
/// UI package never spawns processes itself, while staying synchronous.
///
/// On a non-zero exit the failure is logged. Pass [throwOnError] to also
/// throw a [ProcessException] (with the captured stderr/stdout as the
/// message) instead of returning the failed result — useful for
/// sequences that should abort on the first failure.
RunResult runCheckedSync(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool throwOnError = false,
}) {
  final r = Process.runSync(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  return _shape(executable, args, r, throwOnError);
}

/// Async twin of [runCheckedSync], for flows that are already async
/// (e.g. the debug views' background fetches). Same logging + optional
/// throw-on-failure behaviour.
Future<RunResult> runChecked(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool throwOnError = false,
}) async {
  final r = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  return _shape(executable, args, r, throwOnError);
}

/// Write [content] to [path] and mark it executable (`chmod +x`).
/// Used for the throwaway helper scripts the debug tools drop under
/// `/tmp`. Synchronous so it's safe from a nocterm key handler.
void writeExecutableScriptSync(String path, String content) {
  File(path).writeAsStringSync(content);
  runCheckedSync('chmod', ['+x', path]);
}
