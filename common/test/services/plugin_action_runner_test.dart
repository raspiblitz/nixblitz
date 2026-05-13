import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/plugin_action_runner.dart';
import 'package:common/src/services/sudo_session.dart';

class _NoopAuth implements SudoAuthBackend {
  @override
  Future<int> silentVerify() async => 0;
  @override
  Future<int> passwordVerify(Uint8List password) async => 0;
  @override
  Future<int> forget() async => 0;
}

Future<({List<String> output, int exitCode})> _runAndCollect(
  PluginActionRunner svc,
  PluginAction action, {
  Map<String, String> inputs = const {},
}) async {
  final out = <String>[];
  final r = svc.run(action, inputs: inputs);
  r.output.listen(out.add);
  final code = await r.exitCode;
  // Give the stream listener one more microtask to flush trailing
  // events that may land after exitCode resolves.
  await Future<void>.delayed(Duration.zero);
  return (output: out, exitCode: code);
}

void main() {
  group('PluginActionRunner command actions', () {
    final pluginActionRunner = PluginActionRunner(
      sudoSession: SudoSession(authBackend: _NoopAuth()),
    );

    test('happy path: echo command exits 0 with output', () async {
      final action = PluginAction(label: 'echo', command: 'echo hello-world');
      final r = await _runAndCollect(pluginActionRunner, action);
      expect(r.exitCode, 0);
      expect(r.output.join(), contains('hello-world'));
    });

    test('non-zero exit code is captured', () async {
      final action = PluginAction(label: 'fail', command: 'exit 7');
      final r = await _runAndCollect(pluginActionRunner, action);
      expect(r.exitCode, 7);
    });

    test('stderr is interleaved into the output stream', () async {
      final action = PluginAction(label: 'err', command: 'echo to-stderr 1>&2');
      final r = await _runAndCollect(pluginActionRunner, action);
      expect(r.exitCode, 0);
      expect(r.output.join(), contains('to-stderr'));
    });

    test(
      'timeout kills the process with reported exit 124',
      () async {
        final action = PluginAction(
          label: 'hang',
          command: 'sleep 30',
          timeoutSeconds: 1,
        );
        final r = await _runAndCollect(pluginActionRunner, action);
        expect(r.exitCode, 124);
        expect(r.output.join(), contains('timeout'));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('command-not-found surfaces non-zero exit', () async {
      final action = PluginAction(
        label: 'no-such-binary',
        command: 'definitely-not-a-real-command-37281',
      );
      final r = await _runAndCollect(pluginActionRunner, action);
      expect(r.exitCode, isNot(0));
    });

    test('declared inputs land in the env as NIXBLITZ_INPUT_<NAME>', () async {
      final action = PluginAction(
        label: 'show-key',
        command: r'echo "key=$NIXBLITZ_INPUT_AUTHKEY"',
        inputs: const [PluginActionInput(name: 'authkey', label: 'Key')],
      );
      final r = await _runAndCollect(
        pluginActionRunner,
        action,
        inputs: const {'authkey': 'tskey-abc123'},
      );
      expect(r.exitCode, 0);
      expect(r.output.join(), contains('key=tskey-abc123'));
    });

    test('missing inputs come through as empty strings, not unset', () async {
      final action = PluginAction(
        label: 'show-empty',
        // Use `${VAR-fallback}` so an UNSET var would print "unset",
        // but an empty var prints empty. We want empty.
        command: r'echo "val=[${NIXBLITZ_INPUT_AUTHKEY-unset}]"',
        inputs: const [PluginActionInput(name: 'authkey', label: 'Key')],
      );
      final r = await _runAndCollect(pluginActionRunner, action);
      expect(r.exitCode, 0);
      expect(r.output.join(), contains('val=[]'));
    });

    test('values not on the command line (no argv leak)', () async {
      // Run a sentinel value through env, then `ps` ourselves and
      // assert the sentinel never showed up in argv. Cheap guard
      // against an accidental future change that interpolates inputs
      // into the command string.
      const sentinel = 'unique-sentinel-93f8a';
      final action = PluginAction(
        label: 'ps-self',
        // Grab argv of the bash process via /proc/self/cmdline.
        command: r"tr '\0' ' ' </proc/self/cmdline",
        inputs: const [PluginActionInput(name: 'authkey', label: 'Key')],
      );
      final r = await _runAndCollect(
        pluginActionRunner,
        action,
        inputs: const {'authkey': sentinel},
      );
      expect(r.exitCode, 0);
      expect(r.output.join(), isNot(contains(sentinel)));
    });
  });

  group('PluginActionRunner.runOneShot', () {
    final pluginActionRunner = PluginActionRunner(
      sudoSession: SudoSession(authBackend: _NoopAuth()),
    );

    test('captures stdout and stderr separately', () async {
      final r = await pluginActionRunner.runOneShot(
        command: r'echo to-stdout; echo to-stderr 1>&2',
      );
      expect(r.exitCode, 0);
      expect(r.stdout.trim(), 'to-stdout');
      expect(r.stderr.trim(), 'to-stderr');
    });

    test('captures non-zero exit code', () async {
      final r = await pluginActionRunner.runOneShot(
        command: 'echo nope; exit 3',
      );
      expect(r.exitCode, 3);
      expect(r.stdout.trim(), 'nope');
    });

    test('timeout surfaces as exit 124', () async {
      final r = await pluginActionRunner.runOneShot(
        command: 'sleep 30',
        timeout: const Duration(seconds: 1),
      );
      expect(r.exitCode, 124);
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
