import 'dart:async';
import 'dart:io';

import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/sudo_session.dart';

/// Runs plugin-declared actions with streaming output + a timeout.
/// Mirrors the `(Stream<String> output, Future<int> exitCode)` shape
/// that `SystemService.rebuild` already uses, so the TUI can plug
/// it into the existing ScrollableLog rendering.
///
/// Actions are discriminated by their privilege level:
///
/// - `command:` actions run as the admin user via `bash -c`. No sudo.
///   Used for read-only or per-user verbs.
/// - `unit:` actions dispatch a Type=oneshot systemd service via
///   [SudoSession]. Output is captured by streaming the unit's
///   journal lines after `systemctl start --wait` returns.
///
/// Conventional exit codes used outside the child:
/// - 124  the action was killed by the timeout watchdog (matches
///        `timeout(1)` semantics)
/// - 137  child still alive after SIGTERM; SIGKILL fired
class PluginActionRunner {
  PluginActionRunner({required this.sudoSession});

  final SudoSession sudoSession;

  /// Grace period between SIGTERM and SIGKILL when the watchdog
  /// kills a timed-out action.
  static const _sigKillGrace = Duration(seconds: 5);

  /// PATH preamble injected into every `command:` action's bash
  /// script. Ensures commands referencing binaries from
  /// `environment.systemPackages` (e.g. our dogfood
  /// `lnbits-plugin-reset-db`) resolve regardless of inherited PATH.
  ///
  /// `/run/current-system/sw/bin` — system-level packages.
  /// `/run/wrappers/bin` — setuid wrappers.
  static const _systemPath =
      '/run/current-system/sw/bin:/run/wrappers/bin';

  ({Stream<String> output, Future<int> exitCode}) run(PluginAction action) {
    if (action.unit != null) {
      return _runUnit(action);
    }
    return _runCommand(action);
  }

  ({Stream<String> output, Future<int> exitCode}) _runCommand(
      PluginAction action) {
    final controller = StreamController<String>();

    final exitCodeFuture = () async {
      final wrappedCommand =
          r'export PATH="' + _systemPath + r':${PATH:-}"; ' +
              action.command!;
      final timeout = Duration(seconds: action.timeoutSeconds);

      controller.add('> bash -c "${action.command}"\n');

      Process process;
      try {
        process = await Process.start('bash', ['-c', wrappedCommand]);
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

      final reportedCode = timedOut ? 124 : actualCode;
      controller.add('plugin-action: exit $reportedCode\n');
      await controller.close();
      return reportedCode;
    }();

    return (output: controller.stream, exitCode: exitCodeFuture);
  }

  /// Dispatches a `unit:` action via SudoSession. Runs
  /// `systemctl start --wait <unit>` (blocks until the Type=oneshot
  /// service finishes) and then dumps the unit's journal since the
  /// invocation started, so the operator can see what the unit did.
  ///
  /// Caller is expected to have already authenticated sudo via
  /// [SudoSession.ensureFresh]. If the timestamp expired, the very
  /// first sudo call inside this method will fail with exit ≠ 0
  /// and the action surfaces as failed.
  ({Stream<String> output, Future<int> exitCode}) _runUnit(
      PluginAction action) {
    final controller = StreamController<String>();
    final unit = action.unit!;

    final exitCodeFuture = () async {
      final timeout = Duration(seconds: action.timeoutSeconds);
      // 2-second backdate so journalctl picks up startup messages
      // emitted right at the unit-start moment.
      final sinceUnix =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 2;

      controller.add('> sudo systemctl start --wait $unit\n');
      final start = await sudoSession.runOneShot(
        ['systemctl', 'start', '--wait', unit],
        timeout: timeout,
      );
      if (start.stderr.isNotEmpty) {
        controller.add(start.stderr);
        if (!start.stderr.endsWith('\n')) controller.add('\n');
      }

      controller.add('--- journalctl -u $unit ---\n');
      final logRes = await sudoSession.runOneShot(
        [
          'journalctl', '-u', unit,
          '--since', '@$sinceUnix',
          '--no-pager', '--output=cat',
        ],
        timeout: const Duration(seconds: 10),
      );
      if (logRes.stdout.isNotEmpty) {
        controller.add(logRes.stdout);
        if (!logRes.stdout.endsWith('\n')) controller.add('\n');
      }

      controller.add('plugin-action: exit ${start.exitCode}\n');
      await controller.close();
      return start.exitCode;
    }();

    return (output: controller.stream, exitCode: exitCodeFuture);
  }

  /// One-shot variant for code paths that need to consume the
  /// command's output as a single buffered string instead of a
  /// live stream. Used by `PluginDashboardService` to poll
  /// tile-state commands every N seconds and parse the JSON output.
  ///
  /// Always runs as the admin user (no sudo) — tile polls run on a
  /// 30s timer and must not surface password prompts to the operator.
  /// Plugins that need privileged tile data ship a setuid wrapper or
  /// a group-readable file.
  ///
  /// Exit code conventions match [run]: actual child exit code,
  /// or 124 if the watchdog killed it on timeout.
  Future<({int exitCode, String stdout, String stderr})> runOneShot({
    required String command,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final wrapped =
        r'export PATH="' + _systemPath + r':${PATH:-}"; ' + command;

    Process process;
    try {
      process = await Process.start('bash', ['-c', wrapped]);
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
