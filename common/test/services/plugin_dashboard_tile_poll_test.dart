import 'package:common/common.dart';
import 'package:test/test.dart';

PluginManifest _mf(Map<String, dynamic> j) => PluginManifest.fromJson(j);

void main() {
  final logicOnly = _mf({
    'manifest': {'schema_version': 5, 'name': 'Node Summary'},
    'id': 'node-summary',
    'actions': {
      'a': {
        'label': 'a',
        'wasm': {'module': 'a.wasm'},
      },
    },
    'sandbox': {
      'bitcoin_rpc': {
        'methods': ['getblockchaininfo'],
      },
    },
    'dashboard': {
      'title': 'Node Summary',
      'wasm': {'module': 'a.wasm', 'export': 'tile'},
    },
  });

  final withConfig = _mf({
    'manifest': {'schema_version': 5, 'name': 'Cfg'},
    'id': 'cfg',
    'module': 'module.nix',
    'config_schema': {
      'id': 'cfg',
      'label': 'Cfg',
      'fields': [
        {'name': 'enable', 'label': 'Enable', 'type': 'bool', 'default': false},
      ],
    },
    'dashboard': {'title': 'Cfg', 'command': 'echo {}'},
  });

  test('logic-only plugin polls regardless of config-enable', () {
    expect(
      tilePollEnabled(manifest: logicOnly, isAppEnabled: (_) => false),
      isTrue,
    );
  });

  test('config_schema plugin polls only when enabled', () {
    expect(
      tilePollEnabled(manifest: withConfig, isAppEnabled: (id) => true),
      isTrue,
    );
    expect(
      tilePollEnabled(manifest: withConfig, isAppEnabled: (id) => false),
      isFalse,
    );
  });
}
