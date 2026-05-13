import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  static const _systemPath = '/run/current-system/sw/bin:/run/wrappers/bin';

  /// Run [action]. [inputs] holds operator-supplied values keyed by
  /// [PluginActionInput.name] — they're transported to the spawned
  /// process as env vars (`command:`) or via a transient
  /// EnvironmentFile under `/run/nixblitz/` (`unit:`). Missing inputs
  /// arrive as empty strings; the runner does not validate against
  /// the action's declared `inputs` list (the TUI's prompt UI is
  /// responsible for that).
  ({Stream<String> output, Future<int> exitCode}) run(
    PluginAction action, {
    Map<String, String> inputs = const {},
  }) {
    if (action.unit != null) {
      return _runUnit(action, inputs);
    }
    return _runCommand(action, inputs);
  }

  ({Stream<String> output, Future<int> exitCode}) _runCommand(
    PluginAction action,
    Map<String, String> inputs,
  ) {
    final controller = StreamController<String>();

    final exitCodeFuture = () async {
      final wrappedCommand =
          r'export PATH="' + _systemPath + r':${PATH:-}"; ' + action.command!;
      final timeout = Duration(seconds: action.timeoutSeconds);

      controller.add('> bash -c "${action.command}"\n');

      // Inherit the parent env, then layer the operator-supplied
      // inputs on top as NIXBLITZ_INPUT_<NAME>. Plugins read these
      // from inside their script — they never appear on the command
      // line (so `ps -ef` doesn't leak secrets) or in our log
      // output (we never echo the values).
      final env = {
        ...Platform.environment,
        for (final input in action.inputs)
          input.envVarName: inputs[input.name] ?? '',
      };

      Process process;
      try {
        process = await Process.start('bash', [
          '-c',
          wrappedCommand,
        ], environment: env);
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
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(
            controller.add,
            onDone: () => stdoutDone.isCompleted ? null : stdoutDone.complete(),
            cancelOnError: true,
          );
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(
            controller.add,
            onDone: () => stderrDone.isCompleted ? null : stderrDone.complete(),
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
    PluginAction action,
    Map<String, String> inputs,
  ) {
    final controller = StreamController<String>();
    final unit = action.unit!;

    final exitCodeFuture = () async {
      final timeout = Duration(seconds: action.timeoutSeconds);
      // 2-second backdate so journalctl picks up startup messages
      // emitted right at the unit-start moment.
      final sinceUnix = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 2;

      // Inputs land in a transient EnvironmentFile so they're never
      // visible in argv (ps -ef) or in the unit's static
      // definition. Plugins opt into reading them by declaring
      // `EnvironmentFile=-/run/nixblitz/<stem>-input.env` in their
      // service body. The leading `-` is important — the file is
      // absent for actions that have no inputs, and the unit must
      // still start cleanly in that case.
      final envFilePath = _envFilePathFor(unit);
      final hasInputs = action.inputs.isNotEmpty;
      if (hasInputs) {
        final written = await _writeInputsEnvFile(
          envFilePath: envFilePath,
          action: action,
          inputs: inputs,
        );
        if (!written) {
          controller.add(
            'plugin-action: failed to stage inputs at $envFilePath\n',
          );
          controller.add('plugin-action: exit 1\n');
          await controller.close();
          return 1;
        }
      }

      controller.add('> sudo systemctl start --wait $unit\n');
      final start = await sudoSession.runOneShot([
        'systemctl',
        'start',
        '--wait',
        unit,
      ], timeout: timeout);
      if (start.stderr.isNotEmpty) {
        controller.add(start.stderr);
        if (!start.stderr.endsWith('\n')) controller.add('\n');
      }

      if (hasInputs) {
        // Best-effort cleanup. The unit has already consumed the
        // values; leaving the file behind would expose the secret
        // until the next reboot clears /run. Failures here are
        // logged, not fatal — the action's own exit code wins.
        await _deleteInputsEnvFile(envFilePath);
      }

      controller.add('--- journalctl -u $unit ---\n');
      final logRes = await sudoSession.runOneShot([
        'journalctl',
        '-u',
        unit,
        '--since',
        '@$sinceUnix',
        '--no-pager',
        '--output=cat',
      ], timeout: const Duration(seconds: 10));
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

  /// Path the runner writes inputs to, and the plugin's unit reads
  /// from via `EnvironmentFile=-...`. Stem strips `.service` so a
  /// unit literally named `tailscale-connect-preauth.service` maps
  /// to `/run/nixblitz/tailscale-connect-preauth-input.env`.
  static String _envFilePathFor(String unit) {
    final stem = unit.endsWith('.service')
        ? unit.substring(0, unit.length - '.service'.length)
        : unit;
    return '/run/nixblitz/$stem-input.env';
  }

  /// Writes a `KEY=value` env file at [envFilePath] via sudo. Uses
  /// `install` so the file lands with mode 600 owned by root in one
  /// shot — no race window where the file exists with a permissive
  /// mode. Returns false on any sudo failure; the caller logs and
  /// bails so the unit never starts with stale or missing inputs.
  Future<bool> _writeInputsEnvFile({
    required String envFilePath,
    required PluginAction action,
    required Map<String, String> inputs,
  }) async {
    // Build the env-file content. Values are written as
    // `KEY=value` lines without surrounding quotes — systemd's
    // EnvironmentFile parser handles bare values fine and the
    // quoteless form sidesteps shell-escaping bugs in the unit
    // script. Newlines / NULs in inputs are rejected at the TUI
    // prompt layer, so we don't need to escape them here.
    final lines = StringBuffer();
    for (final input in action.inputs) {
      final value = inputs[input.name] ?? '';
      lines.writeln('${input.envVarName}=$value');
    }
    final bytes = Uint8List.fromList(utf8.encode(lines.toString()));

    // mkdir -p then install -m 600 /dev/stdin <dest>. Two
    // sudo calls is uglier than one but `install --owner` can't
    // chain a stdin read into a non-existent parent directory.
    final mkdir = await sudoSession.runOneShot(const [
      'install',
      '-d',
      '-m',
      '700',
      '/run/nixblitz',
    ]);
    if (mkdir.exitCode != 0) {
      LogService.warn(
        'plugin-action: mkdir /run/nixblitz failed: ${mkdir.stderr}',
      );
      return false;
    }
    final write = await sudoSession.runOneShot([
      'install',
      '-m',
      '600',
      '/dev/stdin',
      envFilePath,
    ], stdinBytes: bytes);
    if (write.exitCode != 0) {
      LogService.warn(
        'plugin-action: write $envFilePath failed: ${write.stderr}',
      );
      return false;
    }
    return true;
  }

  Future<void> _deleteInputsEnvFile(String envFilePath) async {
    final rm = await sudoSession.runOneShot(['rm', '-f', envFilePath]);
    if (rm.exitCode != 0) {
      LogService.warn(
        'plugin-action: cleanup of $envFilePath failed: ${rm.stderr}',
      );
    }
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
    final wrapped = r'export PATH="' + _systemPath + r':${PATH:-}"; ' + command;

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
    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen(
          stdoutBuf.write,
          onDone: () => stdoutDone.isCompleted ? null : stdoutDone.complete(),
          cancelOnError: true,
        );
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen(
          stderrBuf.write,
          onDone: () => stderrDone.isCompleted ? null : stderrDone.complete(),
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
