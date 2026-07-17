import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/providers/app_manifest_registry_provider.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

PluginManifest _mf(Map<String, dynamic> json) => PluginManifest.fromJson(json);

void main() {
  test('a config-less action plugin gets a synthetic sidebar AppManifest', () {
    final logicOnly = _mf({
      'manifest': {'schema_version': 5, 'name': 'Node Summary'},
      'id': 'node-summary',
      'actions': {
        'summary': {
          'label': 'Node summary',
          'wasm': {'module': 'a.wasm'},
        },
      },
      'sandbox': {
        'bitcoin_rpc': {
          'methods': ['getblockchaininfo'],
        },
      },
    });

    final container = ProviderContainer(
      overrides: [
        installedPluginsProvider.overrideWithValue([logicOnly]),
      ],
    );
    addTearDown(container.dispose);

    final registry = container.read(appManifestRegistryProvider);
    final entry = registry.allApps
        .where((a) => a.id == 'node-summary')
        .toList();
    expect(
      entry,
      hasLength(1),
      reason: 'logic-only action plugin must produce a sidebar entry',
    );
    expect(entry.single.label, 'Node Summary');
    expect(entry.single.fields, isEmpty);
  });

  test(
    'a plugin with neither config_schema nor actions is not a sidebar entry',
    () {
      final inert = _mf({
        'manifest': {'schema_version': 5, 'name': 'Inert'},
        'id': 'inert',
        'module': 'module.nix',
      });

      final container = ProviderContainer(
        overrides: [
          installedPluginsProvider.overrideWithValue([inert]),
        ],
      );
      addTearDown(container.dispose);

      final registry = container.read(appManifestRegistryProvider);
      expect(registry.allApps.where((a) => a.id == 'inert'), isEmpty);
    },
  );
}
