import 'dart:io';

import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:test/test.dart';

void main() {
  // bitcoin.json and lightning.json were removed; they live inside the
  // bitcoind / lnd / cln plugins now.
  for (final name in ['hardware', 'system']) {
    test('$name.json parses', () {
      final s = File(
        'lib/src/services/dashboard/bundled/manifests/$name.json',
      ).readAsStringSync();
      expect(() => TileManifest.fromJsonString(s), returnsNormally);
    });
  }
}
