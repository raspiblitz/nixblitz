import 'package:common/src/services/dashboard/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledManifests', () {
    test('contains only hardware + system tiles after bitcoin/lightning moved to plugins', () {
      // bitcoin and lightning tile manifests now ship inside the
      // bitcoind / lnd / cln plugins. Only procfs/sysfs readers
      // remain as built-ins.
      final ids = bundledManifests.map((m) => m.id).toList();
      expect(ids, ['hardware', 'system']);
    });

    test('all manifests have non-empty title', () {
      for (final m in bundledManifests) {
        expect(m.title.isNotEmpty, isTrue, reason: 'tile=${m.id}');
      }
    });

    test('returns same content on repeat call', () {
      final ids1 = bundledManifests.map((m) => m.id).toList();
      final ids2 = bundledManifests.map((m) => m.id).toList();
      expect(ids2, ids1);
    });
  });
}
