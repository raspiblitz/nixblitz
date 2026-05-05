import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

void main() {
  group('TileEvent', () {
    test('holds tileId, data, ts', () {
      final ts = DateTime.utc(2026, 5, 5);
      final ev = TileEvent(
        tileId: 'bitcoin',
        data: const {'blocks': 100},
        ts: ts,
      );
      expect(ev.tileId, 'bitcoin');
      expect(ev.data['blocks'], 100);
      expect(ev.ts, ts);
    });

    test('equality by all fields', () {
      final ts = DateTime.utc(2026, 5, 5);
      final a = TileEvent(tileId: 'a', data: const {'x': 1}, ts: ts);
      final b = TileEvent(tileId: 'a', data: const {'x': 1}, ts: ts);
      final c = TileEvent(tileId: 'a', data: const {'x': 2}, ts: ts);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('hashCode consistency', () {
      final ts = DateTime.utc(2026, 5, 5);
      final a = TileEvent(tileId: 'a', data: const {'x': 1}, ts: ts);
      final b = TileEvent(tileId: 'a', data: const {'x': 1}, ts: ts);
      final c = TileEvent(tileId: 'a', data: const {'x': 2}, ts: ts);
      // Equal events must have equal hashes
      expect(a.hashCode, equals(b.hashCode));
      // Events with different data should have different hashes
      expect(a.hashCode, isNot(equals(c.hashCode)));
    });
  });
}
