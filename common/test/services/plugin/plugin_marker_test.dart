import 'dart:io';

import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plugin_marker_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('PluginMarker', () {
    test('write + read roundtrip', () {
      final marker = PluginMarker(
        id: 'blitz-api',
        url: 'git+https://forge.example/x',
        version: '1.0.0',
        rev: 'abcd1234',
        installedAt: DateTime.utc(2026, 5, 6, 12, 0),
        disabled: false,
      );
      final pluginDir = Directory('${tmp.path}/blitz-api')..createSync();
      writeMarker(pluginDir.path, marker);
      final back = readMarker(pluginDir.path);
      expect(back, isNotNull);
      expect(back!.id, 'blitz-api');
      expect(back.url, 'git+https://forge.example/x');
      expect(back.disabled, isFalse);
    });

    test('readMarker returns null for missing file', () {
      final pluginDir = Directory('${tmp.path}/nonexistent')..createSync();
      expect(readMarker(pluginDir.path), isNull);
    });

    test('readMarker returns null for malformed file', () {
      final pluginDir = Directory('${tmp.path}/bad')..createSync();
      File(
        '${pluginDir.path}/.nixblitz-installed.json',
      ).writeAsStringSync('not json');
      expect(readMarker(pluginDir.path), isNull);
    });

    test('disabled flag persists', () {
      final pluginDir = Directory('${tmp.path}/x')..createSync();
      writeMarker(
        pluginDir.path,
        PluginMarker(
          id: 'x',
          url: 'u',
          version: '1',
          rev: 'r',
          installedAt: DateTime.utc(2026, 5, 6),
          disabled: true,
        ),
      );
      expect(readMarker(pluginDir.path)!.disabled, isTrue);
    });
  });

  group('discoverInstalledMarkers', () {
    test('finds all markers under plugins/', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      for (final id in ['a', 'b', 'c']) {
        final pd = Directory('${pluginsRoot.path}/$id')..createSync();
        writeMarker(
          pd.path,
          PluginMarker(
            id: id,
            url: 'u',
            version: '1',
            rev: 'r',
            installedAt: DateTime.utc(2026, 5, 6),
            disabled: false,
          ),
        );
      }
      // One directory without a marker — should be ignored.
      Directory('${pluginsRoot.path}/d').createSync();
      final found = discoverInstalledMarkers(pluginsRoot.path);
      expect(found.map((m) => m.id).toSet(), {'a', 'b', 'c'});
    });

    test('returns empty when plugins/ is missing', () {
      expect(discoverInstalledMarkers('${tmp.path}/missing'), isEmpty);
    });
  });
}
