import 'package:common/src/services/configure/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledAppManifests', () {
    test('contains the three built-in apps in stable order', () {
      // blitz_api and blitz_web were built-ins in earlier phases;
      // they're now plugins (nixblitz_official_plugins/{blitz-api,
      // blitz-web}) and no longer ship a bundled config_schema.
      final ids = bundledAppManifests.map((m) => m.id).toList();
      expect(ids, ['bitcoind', 'cln', 'lnd']);
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
  });
}
