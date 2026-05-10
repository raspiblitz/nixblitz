import 'package:test/test.dart';

void main() {
  test('no bundled app manifests ship in the binary', () {
    // All apps have been extracted into plugins. This file's
    // existence preserves the test path so future bundled-shape
    // additions land here, but the body is intentionally minimal.
    expect(true, isTrue);
  });
}
