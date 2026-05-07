import 'dart:convert';
import 'dart:io';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('installed_plugins_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(String baseDir) => ProviderContainer(
    overrides: [baseDirProvider.overrideWithValue(baseDir)],
  );

  void writeFixture({
    required String baseDir,
    required String id,
    required Map<String, dynamic> manifestJson,
    bool disabled = false,
  }) {
    final pd = Directory('$baseDir/plugins/$id')..createSync(recursive: true);
    File('${pd.path}/plugin.json').writeAsStringSync(jsonEncode(manifestJson));
    writeMarker(
      pd.path,
      PluginMarker(
        id: id,
        url: 'git+https://example/$id',
        version: '1.0.0',
        rev: 'abcd',
        installedAt: DateTime.utc(2026, 5, 7),
        disabled: disabled,
      ),
    );
  }

  group('installedPluginsProvider', () {
    test('discovers plugins with marker + parseable plugin.json', () {
      writeFixture(
        baseDir: tmp.path,
        id: 'plugin-a',
        manifestJson: {
          'manifest': {
            'schema_version': 2,
            'min_tui_version': 2,
            'name': 'Plugin A',
          },
          'id': 'plugin-a',
        },
      );
      final container = makeContainer(tmp.path);
      addTearDown(container.dispose);
      final result = container.read(installedPluginsProvider);
      expect(result.length, 1);
      expect(result.first.id, 'plugin-a');
    });

    test('skips plugins with marker but missing plugin.json', () {
      // Marker present, plugin.json absent.
      final pd = Directory('${tmp.path}/plugins/orphan')
        ..createSync(recursive: true);
      writeMarker(
        pd.path,
        PluginMarker(
          id: 'orphan',
          url: 'u',
          version: '1',
          rev: 'r',
          installedAt: DateTime.utc(2026, 5, 7),
          disabled: false,
        ),
      );
      final container = makeContainer(tmp.path);
      addTearDown(container.dispose);
      final result = container.read(installedPluginsProvider);
      expect(result, isEmpty);
    });

    test('skips plugins with malformed plugin.json', () {
      final pd = Directory('${tmp.path}/plugins/broken')
        ..createSync(recursive: true);
      writeMarker(
        pd.path,
        PluginMarker(
          id: 'broken',
          url: 'u',
          version: '1',
          rev: 'r',
          installedAt: DateTime.utc(2026, 5, 7),
          disabled: false,
        ),
      );
      File('${pd.path}/plugin.json').writeAsStringSync('not json');
      final container = makeContainer(tmp.path);
      addTearDown(container.dispose);
      final result = container.read(installedPluginsProvider);
      expect(result, isEmpty);
    });

    test('returns empty when plugins root is missing', () {
      final container = makeContainer(tmp.path);
      addTearDown(container.dispose);
      // No plugins/ directory at all.
      final result = container.read(installedPluginsProvider);
      expect(result, isEmpty);
    });

    test('discovers multiple plugins', () {
      for (final id in ['a', 'b', 'c']) {
        writeFixture(
          baseDir: tmp.path,
          id: id,
          manifestJson: {
            'manifest': {'schema_version': 2, 'min_tui_version': 2, 'name': id},
            'id': id,
          },
        );
      }
      final container = makeContainer(tmp.path);
      addTearDown(container.dispose);
      final result = container.read(installedPluginsProvider);
      expect(result.map((m) => m.id).toSet(), {'a', 'b', 'c'});
    });
  });
}
