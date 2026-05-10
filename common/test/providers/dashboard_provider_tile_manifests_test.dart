import 'dart:convert';
import 'dart:io';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/dashboard_provider.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Future<bool> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return predicate();
}

void _writePluginFixture({
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
      installedAt: DateTime.utc(2026, 5, 8),
      disabled: disabled,
    ),
  );
}

void main() {
  test('tileManifestsProvider includes enabled plugin tile manifests', () async {
    final tmp = Directory.systemTemp.createTempSync('plugin-tile-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));

    _writePluginFixture(
      baseDir: tmp.path,
      id: 'foo',
      manifestJson: {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Foo'},
        'id': 'foo',
        'tile_manifests': ['tile-foo.json'],
      },
    );
    File('${tmp.path}/plugins/foo/tile-foo.json').writeAsStringSync(
      '{"id": "foo", "title": "Foo", "accent_color": "#ff0000", "layout": []}',
    );
    File('${tmp.path}/config.json').writeAsStringSync(
      jsonEncode({
        'schema_version': 18,
        'min_compatible_version': 1,
        'initialized': true,
        'system': {'hostname': 'h', 'timezone': 'UTC', 'platform': 'vm'},
        'app_configs': {
          'foo': {'enabled': true},
        },
      }),
    );

    final container = ProviderContainer(
      overrides: [baseDirProvider.overrideWithValue(tmp.path)],
    );
    addTearDown(container.dispose);

    // Force the config provider to start loading.
    container.read(configProvider);
    // Wait for the async load to settle before reading the manifests.
    await _waitFor(() => container.read(configProvider).value != null);

    final manifests = container.read(tileManifestsProvider);
    final ids = manifests.map((m) => m.id).toList();
    expect(ids, contains('foo'));
  });

  test('disabled plugin tile manifests are excluded', () async {
    final tmp = Directory.systemTemp.createTempSync('plugin-tile-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));

    _writePluginFixture(
      baseDir: tmp.path,
      id: 'foo',
      manifestJson: {
        'manifest': {'schema_version': 3, 'min_tui_version': 3, 'name': 'Foo'},
        'id': 'foo',
        'tile_manifests': ['tile-foo.json'],
      },
    );
    File('${tmp.path}/plugins/foo/tile-foo.json').writeAsStringSync(
      '{"id": "foo", "title": "Foo", "accent_color": "#ff0000", "layout": []}',
    );
    File('${tmp.path}/config.json').writeAsStringSync(
      jsonEncode({
        'schema_version': 18,
        'min_compatible_version': 1,
        'initialized': true,
        'system': {'hostname': 'h', 'timezone': 'UTC', 'platform': 'vm'},
        'app_configs': {
          'foo': {'enabled': false},
        },
      }),
    );

    final container = ProviderContainer(
      overrides: [baseDirProvider.overrideWithValue(tmp.path)],
    );
    addTearDown(container.dispose);

    container.read(configProvider);
    await _waitFor(() => container.read(configProvider).value != null);

    final manifests = container.read(tileManifestsProvider);
    final ids = manifests.map((m) => m.id).toList();
    expect(ids, isNot(contains('foo')));
  });
}
