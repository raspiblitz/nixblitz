import 'package:common/src/services/dashboard/colors.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('resolveTileColor', () {
    test('semantic ok → green', () {
      expect(
        resolveTileColor('ok', accent: const Color.fromRGB(0, 0, 0)),
        equals(Color.fromRGB(0x4c, 0xaf, 0x50)),
      );
    });

    test('semantic warn → orange', () {
      expect(
        resolveTileColor('warn', accent: const Color.fromRGB(0, 0, 0)),
        equals(Color.fromRGB(0xff, 0xa7, 0x26)),
      );
    });

    test('semantic error → red', () {
      expect(
        resolveTileColor('error', accent: const Color.fromRGB(0, 0, 0)),
        equals(Color.fromRGB(0xef, 0x53, 0x50)),
      );
    });

    test('semantic muted → gray', () {
      expect(
        resolveTileColor('muted', accent: const Color.fromRGB(0, 0, 0)),
        equals(Color.fromRGB(0x9e, 0x9e, 0x9e)),
      );
    });

    test('semantic default → light gray', () {
      expect(
        resolveTileColor('default', accent: const Color.fromRGB(0, 0, 0)),
        equals(Color.fromRGB(0xee, 0xee, 0xee)),
      );
    });

    test('semantic accent returns the supplied accent color', () {
      const accent = Color.fromRGB(0xf7, 0x93, 0x1a);
      expect(resolveTileColor('accent', accent: accent), equals(accent));
    });

    test('hex string returns the parsed color', () {
      expect(
        resolveTileColor('#ff8800', accent: const Color.fromRGB(0, 0, 0)),
        equals(Color.fromRGB(0xff, 0x88, 0x00)),
      );
    });

    test('null returns default theme color', () {
      expect(
        resolveTileColor(null, accent: const Color.fromRGB(0, 0, 0)),
        equals(Color.fromRGB(0xee, 0xee, 0xee)),
      );
    });

    test('unknown name returns default + does not throw', () {
      expect(
        () =>
            resolveTileColor('nonsense', accent: const Color.fromRGB(0, 0, 0)),
        returnsNormally,
      );
    });
  });

  group('parseHex', () {
    test('#rrggbb', () {
      expect(parseHex('#ff8800'), equals(Color.fromRGB(0xff, 0x88, 0x00)));
    });
    test('rejects bad input', () {
      expect(parseHex('not-a-color'), isNull);
      expect(parseHex('#xyz'), isNull);
    });
  });
}
