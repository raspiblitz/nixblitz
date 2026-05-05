import 'package:common/src/services/dashboard/dsl/primitives.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('TileManifest.fromJsonString', () {
    test('full round-trip', () {
      final m = TileManifest.fromJsonString('''
        {
          "id": "bitcoin",
          "title": "Bitcoin",
          "accent_color": "#f7931a",
          "layout": [
            {"Row": {"label": "Peers", "value": {"\$data": "peers"}}}
          ],
          "footer": {"Footer": {"text": "synced", "color": "ok"}}
        }
      ''');
      expect(m.id, 'bitcoin');
      expect(m.title, 'Bitcoin');
      expect(m.accentColor, '#f7931a');
      expect(m.layout.length, 1);
      expect(m.layout.first, isA<Row>());
      expect(m.footer, isNotNull);
      expect(m.footer, isA<Footer>());
    });

    test('layout-only manifest (no footer)', () {
      final m = TileManifest.fromJsonString('''
        {"id":"x","title":"X","layout":[{"Spacer":{}}]}
      ''');
      expect(m.footer, isNull);
    });

    test('rejects missing id', () {
      expect(
        () => TileManifest.fromJsonString('{"title":"X","layout":[]}'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('rejects empty id', () {
      expect(
        () => TileManifest.fromJsonString('{"id":"","title":"X","layout":[]}'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('rejects missing title', () {
      expect(
        () => TileManifest.fromJsonString('{"id":"x","layout":[]}'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('rejects missing layout', () {
      expect(
        () => TileManifest.fromJsonString('{"id":"x","title":"X"}'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => TileManifest.fromJsonString('not json'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('rejects non-object root', () {
      expect(
        () => TileManifest.fromJsonString('[]'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('footer can be a \$status directive (passes through opaque)', () {
      final m = TileManifest.fromJsonString('''
        {
          "id":"x","title":"X","layout":[],
          "footer":{"\$status":{"\$on":"sync_state","ok":{"Footer":{"text":"yes"}}}}
        }
      ''');
      expect(m.footer, isA<Map>()); // not parsed as Primitive at this stage
    });

    test('Footer in layout (not in footer block) throws', () {
      expect(
        () => TileManifest.fromJsonString('''
          {"id":"x","title":"X","layout":[{"Footer":{"text":"x"}}]}
        '''),
        throwsA(isA<TileManifestError>()),
      );
    });
  });
}
