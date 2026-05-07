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

    test('default values for branch / autoUpdate / signatureFingerprint', () {
      final pluginDir = Directory('${tmp.path}/defaults')..createSync();
      writeMarker(
        pluginDir.path,
        PluginMarker(
          id: 'defaults',
          url: 'u',
          version: '1',
          rev: 'r',
          installedAt: DateTime.utc(2026, 5, 7),
          disabled: false,
        ),
      );
      final back = readMarker(pluginDir.path)!;
      expect(back.branch, 'main');
      expect(back.autoUpdate, isTrue);
      expect(back.signatureFingerprint, isNull);

      // toJson omits the defaults so the on-disk JSON stays tidy.
      final raw = File(
        '${pluginDir.path}/.nixblitz-installed.json',
      ).readAsStringSync();
      expect(raw, isNot(contains('branch')));
      expect(raw, isNot(contains('auto_update')));
      expect(raw, isNot(contains('signature_fingerprint')));
    });

    test('non-default branch / autoUpdate / signature persist', () {
      final pluginDir = Directory('${tmp.path}/full')..createSync();
      writeMarker(
        pluginDir.path,
        PluginMarker(
          id: 'full',
          url: 'u',
          version: '1',
          rev: 'r',
          installedAt: DateTime.utc(2026, 5, 7),
          disabled: false,
          branch: 'develop',
          autoUpdate: false,
          signatureFingerprint: 'AABBCCDD',
        ),
      );
      final back = readMarker(pluginDir.path)!;
      expect(back.branch, 'develop');
      expect(back.autoUpdate, isFalse);
      expect(back.signatureFingerprint, 'AABBCCDD');
    });

    test('copyWith mutates writable fields, preserves identity', () {
      final original = PluginMarker(
        id: 'p',
        url: 'u',
        version: '1.0',
        rev: 'oldrev',
        installedAt: DateTime.utc(2026, 5, 7),
        disabled: false,
        signatureFingerprint: 'oldsig',
      );
      final updated = original.copyWith(version: '1.1', rev: 'newrev');
      expect(updated.id, 'p'); // id preserved
      expect(updated.url, 'u'); // url preserved
      expect(
        updated.installedAt,
        original.installedAt,
      ); // installedAt preserved
      expect(updated.version, '1.1');
      expect(updated.rev, 'newrev');
      expect(updated.signatureFingerprint, 'oldsig');

      final cleared = original.copyWith(clearSignatureFingerprint: true);
      expect(cleared.signatureFingerprint, isNull);
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
