import 'dart:async';

import 'package:test/test.dart';

import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/plugin_action_runner.dart';

Future<({List<String> output, int exitCode})> _runAndCollect(
  PluginActionRunner svc,
  PluginAction action,
) async {
  final out = <String>[];
  final r = svc.run(action);
  r.output.listen(out.add);
  final code = await r.exitCode;
  // Give the stream listener one more microtask to flush trailing
  // events that may land after exitCode resolves.
  await Future<void>.delayed(Duration.zero);
  return (output: out, exitCode: code);
}

void main() {
  group('PluginActionRunner', () {
    final svc = PluginActionRunner();

    test('happy path: echo command exits 0 with output', () async {
      final action = PluginAction(
        label: 'echo',
        command: 'echo hello-world',
      );
      final r = await _runAndCollect(svc, action);
      expect(r.exitCode, 0);
      expect(r.output.join(), contains('hello-world'));
    });

    test('non-zero exit code is captured', () async {
      final action = PluginAction(
        label: 'fail',
        command: 'exit 7',
      );
      final r = await _runAndCollect(svc, action);
      expect(r.exitCode, 7);
    });

    test('stderr is interleaved into the output stream', () async {
      final action = PluginAction(
        label: 'err',
        command: 'echo to-stderr 1>&2',
      );
      final r = await _runAndCollect(svc, action);
      expect(r.exitCode, 0);
      expect(r.output.join(), contains('to-stderr'));
    });

    test('timeout kills the process with reported exit 124', () async {
      final action = PluginAction(
        label: 'hang',
        command: 'sleep 30',
        timeoutSeconds: 1,
      );
      final r = await _runAndCollect(svc, action);
      expect(r.exitCode, 124);
      expect(r.output.join(), contains('timeout'));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('command-not-found surfaces non-zero exit', () async {
      final action = PluginAction(
        label: 'no-such-binary',
        command: 'definitely-not-a-real-command-37281',
      );
      final r = await _runAndCollect(svc, action);
      expect(r.exitCode, isNot(0));
    });
  });
}
