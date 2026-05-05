import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

class _Concrete extends InProcessAdapterSource {
  _Concrete() : super(id: 'fake', providedTileIds: {'foo'});
  void emitForTest(TileEvent e) => emit(e);
  void emitErrorForTest(Object e, [StackTrace? st]) => emitError(e, st);
}

void main() {
  group('InProcessAdapterSource', () {
    test('emits events to listeners', () async {
      final s = _Concrete();
      await s.start();
      final got = <TileEvent>[];
      s.events.listen(got.add);
      s.emitForTest(
        TileEvent(tileId: 'foo', data: {'a': 1}, ts: DateTime.utc(2026, 5, 5)),
      );
      await Future.delayed(Duration.zero);
      expect(got.length, 1);
      expect(got.first.data['a'], 1);
      await s.dispose();
    });

    test('emitError propagates on stream', () async {
      final s = _Concrete();
      await s.start();
      Object? err;
      s.events.listen(
        (_) {},
        onError: (e) {
          err = e;
        },
      );
      s.emitErrorForTest('nope');
      await Future.delayed(Duration.zero);
      expect(err, 'nope');
      await s.dispose();
    });

    test('start is idempotent', () async {
      final s = _Concrete();
      await s.start();
      await s.start();
      expect(s.startedCount, 1);
      await s.dispose();
    });

    test('dispose is idempotent', () async {
      final s = _Concrete();
      await s.start();
      await s.dispose();
      await s.dispose(); // does not throw
    });

    test('emit after dispose is silently dropped', () async {
      final s = _Concrete();
      await s.start();
      await s.dispose();
      // Should not throw or hang.
      s.emitForTest(
        TileEvent(tileId: 'foo', data: {'a': 1}, ts: DateTime.utc(2026, 5, 5)),
      );
    });
  });
}
