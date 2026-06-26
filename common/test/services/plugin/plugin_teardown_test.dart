import 'package:test/test.dart';
import 'package:common/src/services/plugin/plugin_teardown.dart';
import 'package:common/src/models/nixblitz_config.dart';

void main() {
  group('parsePluginsList', () {
    test('splits, trims, drops blanks', () {
      expect(parsePluginsList('a\nb\n\n c \n'), ['a', 'b', 'c']);
    });
    test('null is empty', () {
      expect(parsePluginsList(null), isEmpty);
    });
  });

  group('removedPluginIds', () {
    test('returns ids in committed but not current', () {
      expect(
        removedPluginIds(
          committed: ['a', 'tailscale', 'b'],
          current: ['a', 'b'],
        ),
        {'tailscale'},
      );
    });
    test('no removals yields empty', () {
      expect(
        removedPluginIds(committed: ['a', 'b'], current: ['a', 'b', 'c']),
        isEmpty,
      );
    });
  });

  group('resolveTeardowns', () {
    Future<String?> Function(String) readerFrom(
      Map<String, String> manifests,
    ) =>
        (id) async => manifests[id];

    test('resolves the declared teardown action', () async {
      final read = readerFrom({
        'tailscale': '''
          {
            "manifest": {"schema_version": 4, "min_tui_version": 1, "name": "Tailscale"},
            "actions": {"down": {"label": "Disconnect", "unit": "tailscale-down.service"}},
            "permissions": {"privileged_units": ["tailscale-down.service"]},
            "teardown": "down"
          }
        ''',
      });
      final result = await resolveTeardowns(
        removedIds: {'tailscale'},
        readManifest: read,
      );
      expect(result, hasLength(1));
      expect(result.first.pluginId, 'tailscale');
      expect(result.first.action.unit, 'tailscale-down.service');
    });

    test('skips a removed plugin with no teardown declared', () async {
      final read = readerFrom({
        'plain': '''
          {"manifest": {"schema_version": 4, "min_tui_version": 1, "name": "Plain"}}
        ''',
      });
      expect(
        await resolveTeardowns(removedIds: {'plain'}, readManifest: read),
        isEmpty,
      );
    });

    test('skips a removed plugin whose committed manifest is absent', () async {
      final read = readerFrom({}); // reader returns null
      expect(
        await resolveTeardowns(removedIds: {'ghost'}, readManifest: read),
        isEmpty,
      );
    });

    test('skips a manifest that fails to parse', () async {
      // A malformed committed manifest must be skipped (logged), not raised —
      // resolution is best-effort so one bad plugin never aborts Apply.
      final read = readerFrom({'broken': '{ not valid json'});
      expect(
        await resolveTeardowns(removedIds: {'broken'}, readManifest: read),
        isEmpty,
      );
    });

    test('reader throwing for one id is non-fatal and skips it', () async {
      Future<String?> read(String id) async {
        if (id == 'boom') throw StateError('git failed');
        return '''
          {
            "manifest": {"schema_version": 4, "min_tui_version": 1, "name": "OK"},
            "actions": {"down": {"label": "Disconnect", "unit": "ok-down.service"}},
            "permissions": {"privileged_units": ["ok-down.service"]},
            "teardown": "down"
          }
        ''';
      }

      final result = await resolveTeardowns(
        removedIds: {'boom', 'ok'},
        readManifest: read,
      );
      expect(result.map((t) => t.pluginId), ['ok']);
    });
  });

  group('disabledPluginIds', () {
    NixblitzConfig cfgWith(Map<String, bool> enabledById) =>
        NixblitzConfig.fromJson({
          'schema_version': 18,
          'system': {
            'hostname': 'n',
            'timezone': 'UTC',
            'platform': 'x86',
            'disk_device': '/dev/vda',
            'shell': 'bash',
          },
          'app_configs': {
            for (final e in enabledById.entries) e.key: {'enabled': e.value},
          },
        });

    test('detects an enabled→disabled plugin', () {
      expect(
        disabledPluginIds(
          committed: cfgWith({'tailscale': true}),
          current: cfgWith({'tailscale': false}),
        ),
        {'tailscale'},
      );
    });

    test('ignores a still-enabled plugin', () {
      expect(
        disabledPluginIds(
          committed: cfgWith({'tailscale': true}),
          current: cfgWith({'tailscale': true}),
        ),
        isEmpty,
      );
    });

    test('ignores a newly-enabled plugin', () {
      expect(
        disabledPluginIds(
          committed: cfgWith({'tailscale': false}),
          current: cfgWith({'tailscale': true}),
        ),
        isEmpty,
      );
    });

    test('treats a plugin dropped from current config as disabled', () {
      expect(
        disabledPluginIds(
          committed: cfgWith({'tailscale': true}),
          current: cfgWith({}),
        ),
        {'tailscale'},
      );
    });

    test('null committed or current yields empty', () {
      expect(
        disabledPluginIds(
          committed: null,
          current: cfgWith({'tailscale': false}),
        ),
        isEmpty,
      );
      expect(
        disabledPluginIds(
          committed: cfgWith({'tailscale': true}),
          current: null,
        ),
        isEmpty,
      );
    });
  });
}
