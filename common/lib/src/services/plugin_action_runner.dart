import 'dart:async';
import 'dart:io';

import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/log_service.dart';

/// Runs plugin-declared actions with streaming output + a timeout.
/// Mirrors the `(Stream<String> output, Future<int> exitCode)` shape
/// that `SystemService.rebuild` already uses, so the TUI can plug
/// it into the existing ScrollableLog rendering.
///
/// Conventional exit codes used outside the child:
/// - 124  the action was killed by the timeout watchdog (matches
///        `timeout(1)` semantics)
/// - 137  child still alive after SIGTERM; SIGKILL fired
class PluginActionRunner {
  /// Grace period between SIGTERM and SIGKILL when the watchdog
  /// kills a timed-out action.
  static const _sigKillGrace = Duration(seconds: 5);

  /// PATH preamble injected into every action's bash script. Ensures
  /// commands referencing binaries from `environment.systemPackages`
  /// (e.g. our dogfood `lnbits-plugin-reset-db`) resolve regardless
  /// of whether sudo strips the inherited PATH.
  ///
  /// `/run/current-system/sw/bin` — system-level packages.
  /// `/run/wrappers/bin` — setuid wrappers (sudo, mount, etc.).
  /// `/etc/profiles/per-user/<u>/bin` is intentionally NOT included
  /// — actions run either as the operator (whose login PATH still
  /// covers it) or as root (where per-user profiles don't apply).
  static const _systemPath =
      '/run/current-system/sw/bin:/run/wrappers/bin';

  ({Stream<String> output, Future<int> exitCode}) run(PluginAction action) {
    final controller = StreamController<String>();

    final exitCodeFuture = () async {
      // Prepend a deterministic PATH so binaries from
      // environment.systemPackages always resolve.
      final wrappedCommand =
          r'export PATH="' + _systemPath + r':${PATH:-}"; ' + action.command;
      final List<String> argv = action.runAsRoot
          // sudo -n: non-interactive — fail fast if a password
          // would have been required. Same idiom we use in
          // BlitzApiClient and elsewhere.
          ? ['-n', 'bash', '-c', wrappedCommand]
          : ['-c', wrappedCommand];
      final String exe = action.runAsRoot ? 'sudo' : 'bash';

      final timeout = Duration(seconds: action.timeoutSeconds);

      controller.add('> ${action.runAsRoot ? "sudo " : ""}bash -c '
          '"${action.command}"\n');

      Process process;
      try {
        process = await Process.start(exe, argv);
      } catch (e, st) {
        LogService.error(
          'PluginActionRunner: spawn failed for ${action.label}',
          e,
          st,
        );
        controller.add('failed to spawn: $e\n');
        await controller.close();
        return 127;
      }

      // Watchdog: SIGTERM at the timeout limit, SIGKILL after grace.
      // When the child completes naturally we cancel both timers
      // to avoid signaling an unrelated reused PID.
      var timedOut = false;
      Timer? termTimer;
      Timer? killTimer;
      termTimer = Timer(timeout, () {
        timedOut = true;
        controller.add(
          'plugin-action: timeout (${timeout.inSeconds}s) — '
          'sending SIGTERM\n',
        );
        process.kill(ProcessSignal.sigterm);
        killTimer = Timer(_sigKillGrace, () {
          controller.add('plugin-action: SIGKILL (still alive)\n');
          process.kill(ProcessSignal.sigkill);
        });
      });

      // Stream stdout + stderr line-merged. Matches what Apply +
      // Update views consume. We track each stream's completion
      // via a Completer so we can drain pending data before
      // closing the controller — process.exitCode can resolve
      // before the last stdio chunks have been delivered, and
      // adding to a closed controller throws.
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      process.stdout.transform(const SystemEncoding().decoder).listen(
            controller.add,
            onDone: () =>
                stdoutDone.isCompleted ? null : stdoutDone.complete(),
            cancelOnError: true,
          );
      process.stderr.transform(const SystemEncoding().decoder).listen(
            controller.add,
            onDone: () =>
                stderrDone.isCompleted ? null : stderrDone.complete(),
            cancelOnError: true,
          );

      final actualCode = await process.exitCode;
      await stdoutDone.future;
      await stderrDone.future;
      termTimer.cancel();
      killTimer?.cancel();

      // Emulate `timeout(1)` exit-code convention so the UI can
      // distinguish "process exited with rc != 0" from "we killed
      // it for taking too long."
      final reportedCode = timedOut ? 124 : actualCode;
      controller.add('plugin-action: exit $reportedCode\n');
      await controller.close();
      return reportedCode;
    }();

    return (output: controller.stream, exitCode: exitCodeFuture);
  }

  /// One-shot variant of [run] for code paths that need to consume
  /// the command's output as a single buffered string instead of a
  /// live stream. Used by `PluginDashboardService` to poll
  /// tile-state commands every N seconds and parse the JSON output.
  ///
  /// Mirrors [run]'s sudo wrapping + PATH preamble + watchdog so
  /// that whatever a plugin author can do in an action, they can
  /// also do as a tile poll. Returns stdout + stderr **separately**
  /// (unlike [run] which interleaves them) because tile-output
  /// parsing only cares about stdout.
  ///
  /// Exit code conventions match [run]: actual child exit code,
  /// or 124 if the watchdog killed it on timeout.
  Future<({int exitCode, String stdout, String stderr})> runOneShot({
    required String command,
    bool runAsRoot = false,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final wrapped =
        r'export PATH="' + _systemPath + r':${PATH:-}"; ' + command;
    final argv = runAsRoot
        ? ['-n', 'bash', '-c', wrapped]
        : ['-c', wrapped];
    final exe = runAsRoot ? 'sudo' : 'bash';

    Process process;
    try {
      process = await Process.start(exe, argv);
    } catch (e, st) {
      LogService.error('PluginActionRunner.runOneShot: spawn failed', e, st);
      return (exitCode: 127, stdout: '', stderr: 'spawn failed: $e');
    }

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    process.stdout.transform(const SystemEncoding().decoder).listen(
          stdoutBuf.write,
          onDone: () =>
              stdoutDone.isCompleted ? null : stdoutDone.complete(),
          cancelOnError: true,
        );
    process.stderr.transform(const SystemEncoding().decoder).listen(
          stderrBuf.write,
          onDone: () =>
              stderrDone.isCompleted ? null : stderrDone.complete(),
          cancelOnError: true,
        );

    var timedOut = false;
    Timer? termTimer;
    Timer? killTimer;
    termTimer = Timer(timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      killTimer = Timer(_sigKillGrace, () {
        process.kill(ProcessSignal.sigkill);
      });
    });

    final actual = await process.exitCode;
    await stdoutDone.future;
    await stderrDone.future;
    termTimer.cancel();
    killTimer?.cancel();

    return (
      exitCode: timedOut ? 124 : actual,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );
  }
}
