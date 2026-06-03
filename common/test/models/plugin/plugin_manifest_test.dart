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

    test('rejects empty-string entry in tile_manifests', () {
      final json = {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
        'tile_manifests': ['tile-foo.json', ''],
      };
      expect(
        () => PluginManifest.fromJson(json),
        throwsA(isA<PluginManifestError>()),
      );
    });
  });

  group('PluginManifest.fromJson — app_version', () {
    test('parses an app_version command + args', () {
      final json = {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
        'app_version': {
          'command': 'bash',
          'args': ['app-version.sh'],
        },
      };
      final m = PluginManifest.fromJson(json);
      expect(m.appVersionCommand, isNotNull);
      expect(m.appVersionCommand!.command, 'bash');
      expect(m.appVersionCommand!.args, ['app-version.sh']);
    });

    test('app_version defaults to null when absent', () {
      final json = {
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'Test'},
        'id': 'test',
      };
      expect(PluginManifest.fromJson(json).appVersionCommand, isNull);
    });

    test('rejects a non-map app_version', () {
      final json = {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
        'app_version': 'bitcoin-cli getnetworkinfo',
      };
      expect(
        () => PluginManifest.fromJson(json),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('rejects an app_version with no command', () {
      final json = {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
        'app_version': {
          'args': ['x'],
        },
      };
      expect(
        () => PluginManifest.fromJson(json),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('round-trips app_version through toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
        'app_version': {
          'command': 'sg',
          'args': ['bitcoin', '-c', 'bash app-version.sh'],
        },
      });
      final round = PluginManifest.fromJson(m.toJson());
      expect(round.appVersionCommand!.command, 'sg');
      expect(round.appVersionCommand!.args, [
        'bitcoin',
        '-c',
        'bash app-version.sh',
      ]);
    });
  });

  group('plugin manifest schema branches block (T5)', () {
    test('older-schema manifest with no branches block still parses', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Test'},
        'id': 'test',
      });
      expect(m.branches, isNull);
    });

    test('new-schema manifest with branches block parses', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': currentPluginManifestVersion,
          'min_tui_version': 3,
          'name': 'Test',
        },
        'id': 'test',
        'branches': {
          'stable': {'ref': 'main', 'description': 'Prod', 'default': true},
          'next': {'ref': 'develop'},
        },
      });
      expect(m.branches, isNotNull);
      expect(m.branches!.branches['stable']!.ref, 'main');
      expect(m.branches!.branches['stable']!.description, 'Prod');
      expect(m.branches!.branches['stable']!.isDefault, isTrue);
      expect(m.branches!.branches['next']!.ref, 'develop');
      expect(m.branches!.defaultKey, 'stable');
    });

    test('new-schema manifest with no branches block parses (optional)', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': currentPluginManifestVersion,
          'min_tui_version': 3,
          'name': 'Test',
        },
        'id': 'test',
      });
      expect(m.branches, isNull);
    });

    test('toJson roundtrips a manifest with branches', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': currentPluginManifestVersion,
          'min_tui_version': 3,
          'name': 'Test',
        },
        'id': 'test',
        'branches': {
          'stable': {'ref': 'main', 'default': true},
        },
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.branches, isNotNull);
      expect(back.branches!.branches['stable']!.ref, 'main');
      expect(back.branches!.branches['stable']!.isDefault, isTrue);
      expect(back.branches!.defaultKey, 'stable');
    });
  });
}
