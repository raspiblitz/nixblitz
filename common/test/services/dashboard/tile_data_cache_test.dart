import 'package:common/src/services/dashboard/tile_data_cache.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

void main() {
  group('TileDataCache', () {
    test('apply merges data by key', () {
      final c = TileDataCache();
      c.apply(
        TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)),
      );
      c.apply(
        TileEvent(tileId: 'b', data: {'y': 2}, ts: DateTime.utc(2026, 5, 5)),
      );
      expect(c.snapshotFor('b').data, {'x': 1, 'y': 2});
    });

    test('streamFor emits on every apply', () async {
      final c = TileDataCache();
      final events = <int>[];
      c.streamFor('b').listen((s) => events.add(s.data['x'] ?? -1));
      c.apply(
        TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)),
      );
      c.apply(
        TileEvent(tileId: 'b', data: {'x': 2}, ts: DateTime.utc(2026, 5, 5)),
      );
      await Future.delayed(Duration.zero);
      expect(events, [1, 2]);
    });

    test('applyError preserves data, sets lastError', () {
      final c = TileDataCache();
      c.apply(
        TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)),
      );
      c.applyError('b', 'boom');
      final s = c.snapshotFor('b');
      expect(s.data, {'x': 1});
      expect(s.lastError, 'boom');
    });

    test('next successful apply clears lastError', () {
      final c = TileDataCache();
      c.applyError('b', 'boom');
      c.apply(
        TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)),
      );
      expect(c.snapshotFor('b').lastError, isNull);
    });

    test('snapshotFor unknown tileId returns empty default', () {
      final c = TileDataCache();
      final s = c.snapshotFor('unknown');
      expect(s.isEmpty, isTrue);
    });

    test('streamFor returns same broadcast stream for same tileId', () async {
      final c = TileDataCache();
      final s1 = c.streamFor('x');
      final s2 = c.streamFor('x');
      final got1 = <int>[];
      final got2 = <int>[];
      s1.listen((s) => got1.add(s.data['n'] ?? -1));
      s2.listen((s) => got2.add(s.data['n'] ?? -1));
      c.apply(
        TileEvent(tileId: 'x', data: {'n': 5}, ts: DateTime.utc(2026, 5, 5)),
      );
      await Future.delayed(Duration.zero);
      expect(got1, [5]);
      expect(got2, [5]);
    });
  });
}
