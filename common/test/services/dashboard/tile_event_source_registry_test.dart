import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event_source_registry.dart';
import 'package:test/test.dart';

class _Fake extends InProcessAdapterSource {
  _Fake(String id, Set<String> tileIds)
    : super(id: id, providedTileIds: tileIds);
}

void main() {
  group('TileEventSourceRegistry', () {
    test('register adds source', () {
      final r = TileEventSourceRegistry();
      final s = _Fake('a', {'x'});
      r.register(s);
      expect(r.sources, contains(s));
    });

    test('id collision throws', () {
      final r = TileEventSourceRegistry();
      r.register(_Fake('a', {'x'}));
      expect(() => r.register(_Fake('a', {'y'})), throwsA(isA<StateError>()));
    });

    test('startAll calls start on each source once', () async {
      final r = TileEventSourceRegistry();
      final s1 = _Fake('a', {'x'});
      final s2 = _Fake('b', {'y'});
      r.register(s1);
      r.register(s2);
      await r.startAll();
      expect(s1.started, isTrue);
      expect(s2.started, isTrue);
      // second startAll is a no-op
      s1.startedCount = 0;
      await r.startAll();
      expect(s1.startedCount, 0);
    });

    test('disposeAll clears state', () async {
      final r = TileEventSourceRegistry();
      final s = _Fake('a', {'x'});
      r.register(s);
      await r.disposeAll();
      expect(s.disposed, isTrue);
      expect(r.sources, isEmpty);
    });
  });
}
