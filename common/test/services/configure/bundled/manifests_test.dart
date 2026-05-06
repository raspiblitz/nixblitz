import 'dart:io';

import 'package:common/src/models/configure/app_manifest.dart';
import 'package:test/test.dart';

void main() {
  for (final name in ['bitcoind', 'lnd', 'cln', 'blitz_api', 'blitz_web']) {
    test('$name.json parses', () {
      final s = File(
        'lib/src/services/configure/bundled/manifests/$name.json',
      ).readAsStringSync();
      final m = AppManifest.fromJsonString(s);
      expect(m.id, name);
      expect(m.label.isNotEmpty, isTrue);
    });
  }

  test('lnd + cln declare lightning_backend', () {
    for (final name in ['lnd', 'cln']) {
      final s = File(
        'lib/src/services/configure/bundled/manifests/$name.json',
      ).readAsStringSync();
      final m = AppManifest.fromJsonString(s);
      expect(m.capabilities, contains('lightning_backend'));
    }
  });

  test('cln has service_unit override to clightning', () {
    final s = File(
      'lib/src/services/configure/bundled/manifests/cln.json',
    ).readAsStringSync();
    final m = AppManifest.fromJsonString(s);
    expect(m.serviceUnit, 'clightning');
    expect(m.unitName, 'clightning');
  });
}
