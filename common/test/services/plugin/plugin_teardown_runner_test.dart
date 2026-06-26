import 'dart:async';

import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/plugin/plugin_teardown_runner.dart';

void main() {
  const tailscaleManifest = '''
    {
      "manifest": {"schema_version": 4, "min_tui_version": 1, "name": "Tailscale"},
      "actions": {"down": {"label": "Disconnect", "unit": "tailscale-down.service"}},
      "permissions": {"privileged_units": ["tailscale-down.service"]},
      "teardown": "down"
    }
  ''';

  String cfg(Map<String, bool> enabledById) =>
      '{"schema_version":18,"system":{"hostname":"n","timezone":"UTC","platform":"x86","disk_device":"/dev/vda","shell":"bash"},'
      '"app_configs":{${enabledById.entries.map((e) => '"${e.key}":{"enabled":${e.value}}').join(",")}}}';

  PluginTeardownRunner build({
    required Map<String, String?> committed,
    required Map<String, String?> current,
    required List<PluginAction> ran,
    int exitCode = 0,
  }) {
    return PluginTeardownRunner(
      runAction: (action) {
        ran.add(action);
        return (
          output: Stream<String>.value('ok'),
          exitCode: Future.value(exitCode),
        );
      },
      readCommitted: (p) async => committed[p],
      readCurrent: (p) => current[p],
    );
  }

  test('resolves the disable edge (enabled true→false)', () async {
    final ran = <PluginAction>[];
    final r = build(
      committed: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': true}),
        'plugins/tailscale/plugin.json': tailscaleManifest,
      },
      current: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': false}),
      },
      ran: ran,
    );
    final pending = await r.resolvePending();
    expect(pending.map((t) => t.pluginId), ['tailscale']);
    expect(pending.first.action.unit, 'tailscale-down.service');
  });

  test('resolves the uninstall edge (dropped from plugins.list)', () async {
    final ran = <PluginAction>[];
    final r = build(
      committed: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': true}),
        'plugins/tailscale/plugin.json': tailscaleManifest,
      },
      current: {
        'plugins.list': '',
        'config.json': cfg({'tailscale': true}),
      },
      ran: ran,
    );
    expect((await r.resolvePending()).map((t) => t.pluginId), ['tailscale']);
  });

  test('union dedupes a plugin both uninstalled and disabled', () async {
    final r = build(
      committed: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': true}),
        'plugins/tailscale/plugin.json': tailscaleManifest,
      },
      current: {
        'plugins.list': '',
        'config.json': cfg({'tailscale': false}),
      },
      ran: [],
    );
    expect((await r.resolvePending()).length, 1);
  });

  test('no edge → nothing pending', () async {
    final r = build(
      committed: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': true}),
      },
      current: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': true}),
      },
      ran: [],
    );
    expect(await r.resolvePending(), isEmpty);
  });

  test('runPending runs each action and emits lines', () async {
    final ran = <PluginAction>[];
    final lines = <String>[];
    final r = build(
      committed: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': true}),
        'plugins/tailscale/plugin.json': tailscaleManifest,
      },
      current: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': false}),
      },
      ran: ran,
    );
    await r.runPending(lines.add);
    expect(ran.single.unit, 'tailscale-down.service');
    expect(lines.any((l) => l.contains('tearing down tailscale')), isTrue);
  });

  test('a failing action is non-fatal and still emits', () async {
    final lines = <String>[];
    final r = build(
      committed: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': true}),
        'plugins/tailscale/plugin.json': tailscaleManifest,
      },
      current: {
        'plugins.list': 'tailscale\n',
        'config.json': cfg({'tailscale': false}),
      },
      ran: [],
      exitCode: 1,
    );
    await r.runPending(lines.add); // must not throw
    expect(lines.any((l) => l.contains('exited 1')), isTrue);
  });
}
