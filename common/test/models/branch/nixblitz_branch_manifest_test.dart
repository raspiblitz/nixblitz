import 'package:common/common.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  test('nixblitzBranchManifestProvider parses the embedded constant', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final manifest = container.read(nixblitzBranchManifestProvider);
    expect(manifest.branches.keys, contains('stable'));
    expect(manifest.branches['stable']!.ref, 'main');
    expect(manifest.defaultKey, 'stable');
  });
}
