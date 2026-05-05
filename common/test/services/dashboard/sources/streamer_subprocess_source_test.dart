import 'dart:io';

import 'package:common/src/services/dashboard/sources/streamer_subprocess_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

// Resolve fixture paths so the tests work whether invoked from the workspace
// root (`dart test common/test/...`), from `common/` (`dart test test/...`),
// or from any other working directory.
//
// Strategy: if `common/pubspec.yaml` exists beneath the cwd we're at the
// workspace root; otherwise assume we're already inside `common/`.
String _fixturePath(String name) {
  final cwd = Directory.current.path;
  final commonRoot = File('$cwd/common/pubspec.yaml').existsSync()
      ? '$cwd/common'
      : cwd;
  return '$commonRoot/test/fixtures/streamers/$name';
}

void main() {
  group('StreamerSubprocessSource', () {
    test('happy path: spawns + parses JSON-lines + emits events', () async {
      final s = StreamerSubprocessSource(
        id: 'echo',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: [_fixturePath('echo_streamer.dart')],
        backoff: const [], // no backoff in tests
      );
      addTearDown(s.dispose);
      final got = <TileEvent>[];
      s.events.listen(got.add);
      await s.start();
      // Wait for the streamer to produce three events + exit
      await Future.delayed(const Duration(seconds: 2));
      expect(got.length, greaterThanOrEqualTo(3));
      expect(got.take(3).map((e) => e.data['n']), [0, 1, 2]);
      await s.dispose();
    });

    test('malformed line is dropped, not propagated', () async {
      final s = StreamerSubprocessSource(
        id: 'echo',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: [_fixturePath('echo_streamer.dart')],
        backoff: const [],
      );
      addTearDown(s.dispose);
      final errs = <Object>[];
      s.events.listen((_) {}, onError: errs.add);
      await s.start();
      await Future.delayed(const Duration(seconds: 2));
      expect(errs, isEmpty);
      await s.dispose();
    });

    test('process exit triggers restart with backoff', () async {
      final s = StreamerSubprocessSource(
        id: 'crashy',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: [_fixturePath('crashy_streamer.dart')],
        backoff: const [Duration(milliseconds: 50)],
        // Raise threshold so we don't hit crash-loop during this test.
        crashLoopThreshold: 100,
      );
      addTearDown(s.dispose);
      final got = <TileEvent>[];
      s.events.listen(got.add, onError: (_) {});
      await s.start();
      // First start emits one event, exits, restarts after 50ms,
      // emits another. Allow ~1s.
      await Future.delayed(const Duration(seconds: 1));
      expect(got.length, greaterThanOrEqualTo(2));
      await s.dispose();
    });

    test('crash-loop after 3 restarts in 60s emits sticky error', () async {
      final s = StreamerSubprocessSource(
        id: 'crashy',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: [_fixturePath('crashy_streamer.dart')],
        backoff: const [Duration(milliseconds: 10)],
        crashLoopThreshold: 3,
        crashLoopWindow: const Duration(seconds: 60),
      );
      addTearDown(s.dispose);
      Object? err;
      s.events.listen(
        (_) {},
        onError: (e) {
          err = e;
        },
      );
      await s.start();
      await Future.delayed(const Duration(milliseconds: 800));
      expect(err, isA<StreamerCrashLoopError>());
      await s.dispose();
    });

    test('dispose terminates the child', () async {
      final s = StreamerSubprocessSource(
        id: 'sleeper',
        providedTileIds: const {'fix'},
        command: 'sleep',
        args: ['60'],
        backoff: const [],
      );
      addTearDown(s.dispose);
      await s.start();
      await Future.delayed(const Duration(milliseconds: 200));
      await s.dispose();
      // If dispose hangs, test framework times out — that IS the assertion.
    });
  });
}
