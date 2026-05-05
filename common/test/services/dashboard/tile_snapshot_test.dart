import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:test/test.dart';

void main() {
  group('TileSnapshot', () {
    test('default is empty / null error / null ts', () {
      const s = TileSnapshot();
      expect(s.data, isEmpty);
      expect(s.lastError, isNull);
      expect(s.lastEventTs, isNull);
    });

    test('isEmpty getter true on default', () {
      expect(const TileSnapshot().isEmpty, isTrue);
    });

    test('copyWith preserves untouched fields', () {
      final ts = DateTime.utc(2026, 5, 5);
      final s = const TileSnapshot().copyWith(data: {'a': 1}, lastEventTs: ts);
      expect(s.data['a'], 1);
      expect(s.lastEventTs, ts);
      expect(s.lastError, isNull);

      final s2 = s.copyWith(lastError: 'boom');
      expect(s2.data['a'], 1);
      expect(s2.lastEventTs, ts);
      expect(s2.lastError, 'boom');
    });

    test('copyWith clears error with clearError: true', () {
      final ts = DateTime.utc(2026, 5, 5);
      final s = const TileSnapshot().copyWith(
        data: {'a': 1},
        lastEventTs: ts,
        lastError: 'boom',
      );
      expect(s.lastError, 'boom');

      final s2 = s.copyWith(clearError: true);
      expect(s2.lastError, isNull);
      expect(s2.data['a'], 1);
      expect(s2.lastEventTs, ts);
    });
  });
}
