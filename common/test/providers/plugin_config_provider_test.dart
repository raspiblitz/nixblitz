import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/plugin_config_provider.dart';

/// Seed a plugin dir at `$home/plugins/$dirName` with a manifest +
/// (optionally) a config.json. Used to exercise the provider's
/// load + validate + persist path without cloning a real git repo.
void _seedPlugin(
  Directory home,
  String dirName, {
  Map<String, Map<String, dynamic>> configFields = const {},
  Map<String, dynamic>? initialCfg,
}) {
  final dir = Directory('${home.path}/plugins/$dirName');
  dir.createSync(recursive: true);
  File('${dir.path}/plugin.nix').writeAsStringSync('{}\n');
  File('${dir.path}/plugin.json').writeAsStringSync(
    jsonEncode({
      'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': dirName},
      if (configFields.isNotEmpty) 'config': configFields,
    }),
  );
  if (initialCfg != null) {
    File('${dir.path}/config.json').writeAsStringSync(jsonEncode(initialCfg));
  }
}

ProviderContainer _makeContainer(Directory home) {
  return ProviderContainer(
    overrides: [baseDirProvider.overrideWithValue(home.path)],
  );
}

void main() {
  group('pluginConfigProvider', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('nixblitz_pcp_');
    });

    tearDown(() => home.deleteSync(recursive: true));

    test('loads empty config when config.json is missing', () async {
      _seedPlugin(home, 'demo');
      final container = _makeContainer(home);
      addTearDown(container.dispose);

      // Let the StateNotifier's _load() Future settle.
      await Future<void>.delayed(Duration.zero);

      final state = container.read(pluginConfigProvider('demo'));
      expect(state.value, isEmpty);
    });

    test('loads persisted values', () async {
      _seedPlugin(
        home,
        'demo',
        configFields: {
          'exit_node': {'type': 'bool', 'label': 'Exit node'},
        },
        initialCfg: {'exit_node': true},
      );
      final container = _makeContainer(home);
      addTearDown(container.dispose);

      await Future<void>.delayed(Duration.zero);

      final state = container.read(pluginConfigProvider('demo'));
      expect(state.value!['exit_node'], true);
    });

    test('updateField persists to disk and updates state', () async {
      _seedPlugin(
        home,
        'demo',
        configFields: {
          'auth_key': {'type': 'secret', 'label': 'Auth key'},
          'exit_node': {'type': 'bool', 'label': 'Exit node'},
        },
      );
      final container = _makeContainer(home);
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      await container
          .read(pluginConfigProvider('demo').notifier)
          .updateField('exit_node', true);

      final state = container.read(pluginConfigProvider('demo'));
      expect(state.value!['exit_node'], true);

      final onDisk =
          jsonDecode(
                File(
                  '${home.path}/plugins/demo/config.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(onDisk['exit_node'], true);
    });

    test('updateField rejects unknown key', () async {
      _seedPlugin(home, 'demo');
      final container = _makeContainer(home);
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final notifier = container.read(pluginConfigProvider('demo').notifier);
      await expectLater(
        () => notifier.updateField('not_declared', 1),
        throwsA(isA<StateError>()),
      );
    });

    test('updateField rejects wrong type', () async {
      _seedPlugin(
        home,
        'demo',
        configFields: {
          'exit_node': {'type': 'bool', 'label': 'Exit node'},
        },
      );
      final container = _makeContainer(home);
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final notifier = container.read(pluginConfigProvider('demo').notifier);
      await expectLater(
        () => notifier.updateField('exit_node', 'not a bool'),
        throwsA(isA<FormatException>()),
      );
    });

    test('updateField validates list<string> elements', () async {
      _seedPlugin(
        home,
        'demo',
        configFields: {
          'tags': {'type': 'list<string>', 'label': 'Tags'},
        },
      );
      final container = _makeContainer(home);
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final notifier = container.read(pluginConfigProvider('demo').notifier);
      await notifier.updateField('tags', ['a', 'b']);
      expect(container.read(pluginConfigProvider('demo')).value!['tags'], [
        'a',
        'b',
      ]);

      await expectLater(
        () => notifier.updateField('tags', ['a', 1]),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
