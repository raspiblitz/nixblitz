import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/services/configure/app_manifest_registry.dart';
import 'package:test/test.dart';

AppManifest _m(String id, {Set<String> caps = const {}, String? unit}) =>
    AppManifest(
      id: id,
      label: id,
      capabilities: caps,
      fields: const [],
      serviceUnit: unit,
    );

void main() {
  group('AppManifestRegistry', () {
    test('allApps combines bundled + plugin', () {
      final r = AppManifestRegistry(
        bundled: [_m('a'), _m('b')],
        plugin: [_m('c')],
      );
      expect(r.allApps.map((m) => m.id).toSet(), {'a', 'b', 'c'});
    });

    test('get(id) returns the matching manifest or null', () {
      final r = AppManifestRegistry(bundled: [_m('a')], plugin: const []);
      expect(r.get('a')?.id, 'a');
      expect(r.get('missing'), isNull);
    });

    test('withCapability filters', () {
      final r = AppManifestRegistry(
        bundled: [
          _m('lnd', caps: {'lightning_backend'}),
          _m('cln', caps: {'lightning_backend'}),
          _m('bitcoind'),
        ],
        plugin: const [],
      );
      final ln = r.withCapability('lightning_backend').map((m) => m.id).toSet();
      expect(ln, {'lnd', 'cln'});
      expect(r.withCapability('bitcoin_node'), isEmpty);
    });

    test('serviceIds returns unit names (honouring service_unit override)', () {
      final r = AppManifestRegistry(
        bundled: [
          _m('cln', unit: 'clightning'),
          _m('lnd'),
        ],
        plugin: const [],
      );
      expect(r.serviceIds().toSet(), {'clightning', 'lnd'});
    });

    test('allApps unmodifiable', () {
      final r = AppManifestRegistry(bundled: [_m('a')], plugin: const []);
      expect(() => r.allApps.add(_m('b')), throwsUnsupportedError);
    });
  });
}
