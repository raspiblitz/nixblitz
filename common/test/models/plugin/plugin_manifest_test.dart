import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/models/plugin/plugin_manifest_error.dart';

void main() {
  group('PluginManifest.fromJson — tile_manifests', () {
    test('parses tile_manifests as a list of relative paths', () {
      final json = {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
        'tile_manifests': ['tile-foo.json', 'tile-bar.json'],
      };
      final m = PluginManifest.fromJson(json);
      expect(m.tileManifests, ['tile-foo.json', 'tile-bar.json']);
    });

    test('tile_manifests defaults to empty when absent', () {
      final json = {
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'Test'},
        'id': 'test',
      };
      final m = PluginManifest.fromJson(json);
      expect(m.tileManifests, isEmpty);
    });

    test('rejects non-list tile_manifests', () {
      final json = {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
        'tile_manifests': 'tile-foo.json',
      };
      expect(
        () => PluginManifest.fromJson(json),
        throwsA(isA<PluginManifestError>()),
      );
    });
  });
}
