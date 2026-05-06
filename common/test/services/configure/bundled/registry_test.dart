import 'package:common/src/services/configure/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledAppManifests', () {
    test('contains all five apps in stable order', () {
      final ids = bundledAppManifests.map((m) => m.id).toList();
      expect(ids, ['bitcoind', 'blitz_api', 'blitz_web', 'cln', 'lnd']);
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

    test('blitz_api unitName is blitz-api (hyphenated systemd unit)', () {
      final m = bundledAppManifests.firstWhere((m) => m.id == 'blitz_api');
      expect(m.serviceUnit, 'blitz-api');
      expect(m.unitName, 'blitz-api');
    });

    test('blitz_web unitName is blitz-web (hyphenated systemd unit)', () {
      final m = bundledAppManifests.firstWhere((m) => m.id == 'blitz_web');
      expect(m.serviceUnit, 'blitz-web');
      expect(m.unitName, 'blitz-web');
    });
  });
}
