import 'package:common/src/services/configure/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledAppManifests', () {
    test('contains the four built-in apps in stable order', () {
      // blitz_api was a built-in in earlier phases; it's now a plugin
      // (~/dev/blitz/nixblitz-plugin-blitz-api) and no longer ships
      // a bundled config_schema.
      final ids = bundledAppManifests.map((m) => m.id).toList();
      expect(ids, ['bitcoind', 'blitz_web', 'cln', 'lnd']);
    });

    test('each manifest has a non-empty label', () {
      for (final m in bundledAppManifests) {
        expect(m.label.isNotEmpty, isTrue, reason: 'app=${m.id}');
      }
    });

    test('lnd + cln have lightning_backend capability', () {
      final lnApps = bundledAppManifests
          .where((m) => m.capabilities.contains('lightning_backend'))
          .map((m) => m.id)
          .toSet();
      expect(lnApps, {'lnd', 'cln'});
    });

    test('cln resolves to clightning unit name', () {
      final cln = bundledAppManifests.firstWhere((m) => m.id == 'cln');
      expect(cln.unitName, 'clightning');
    });

    test('blitz_web unitName is blitz-web (hyphenated systemd unit)', () {
      final m = bundledAppManifests.firstWhere((m) => m.id == 'blitz_web');
      expect(m.serviceUnit, 'blitz-web');
      expect(m.unitName, 'blitz-web');
    });
  });
}
