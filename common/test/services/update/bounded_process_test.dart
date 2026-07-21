import 'dart:async';
import 'dart:io';

import 'package:common/src/services/update/bounded_process.dart';
import 'package:test/test.dart';

void main() {
  group('runBounded', () {
    test(
      'throws a labelled TimeoutException when the child overruns',
      () async {
        expect(
          () => runBounded(
            'sleep',
            ['5'],
            timeout: const Duration(milliseconds: 200),
            label: 'nix flake update',
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              allOf(contains('nix flake update'), contains('timed out')),
            ),
          ),
        );
      },
    );

    test(
      'interrupts promptly instead of waiting for the child to finish',
      () async {
        final sw = Stopwatch()..start();
        await runBounded(
          'sleep',
          ['30'],
          timeout: const Duration(milliseconds: 200),
        ).catchError((_) => ProcessResult(0, 0, '', ''));
        sw.stop();
        // Must return on the timeout, not after the full 30s sleep.
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      },
    );

    test(
      'returns a ProcessResult with stdout + exit code on success',
      () async {
        final r = await runBounded('sh', [
          '-c',
          'echo hello',
        ], timeout: const Duration(seconds: 5));
        expect(r.exitCode, 0);
        expect((r.stdout as String).trim(), 'hello');
      },
    );

    test('captures stderr and a non-zero exit code', () async {
      final r = await runBounded('sh', [
        '-c',
        'echo oops >&2; exit 3',
      ], timeout: const Duration(seconds: 5));
      expect(r.exitCode, 3);
      expect((r.stderr as String).trim(), 'oops');
    });
  });
}
