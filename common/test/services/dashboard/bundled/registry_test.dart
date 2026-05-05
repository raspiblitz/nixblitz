import 'package:common/src/services/dashboard/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledManifests', () {
    test('contains four core tiles in stable order', () {
      final ids = bundledManifests.map((m) => m.id).toList();
      expect(ids, ['bitcoin', 'hardware', 'lightning', 'system']);
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
