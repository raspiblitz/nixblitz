import 'dart:io';

import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:test/test.dart';

void main() {
  for (final name in ['bitcoin', 'lightning', 'hardware', 'system']) {
    test('$name.json parses', () {
      final s = File(
        'lib/src/services/dashboard/bundled/manifests/$name.json',
      ).readAsStringSync();
      expect(() => TileManifest.fromJsonString(s), returnsNormally);
    });
  }
}
