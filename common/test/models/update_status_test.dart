import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('PluginAhead', () {
    test('round-trips through JSON', () {
      final original = PluginAhead(
        pluginId: 'mempool',
        currentRev: 'a' * 40,
        upstreamRev: 'b' * 40,
        url: 'https://github.com/example/mempool',
      );
      final reparsed = PluginAhead.fromJson(original.toJson());
      expect(reparsed.pluginId, original.pluginId);
      expect(reparsed.currentRev, original.currentRev);
      expect(reparsed.upstreamRev, original.upstreamRev);
      expect(reparsed.url, original.url);
    });

    test('accepts legacy `dir_name` JSON key', () {
      // Old status files written before the marker migration carry a
      // `dir_name` rather than `plugin_id`; tolerate that on read so
      // a daemon timer that wrote yesterday's status still parses.
      final reparsed = PluginAhead.fromJson({
        'dir_name': 'electrs',
        'current_rev': 'a' * 40,
        'upstream_rev': 'b' * 40,
        'url': 'https://example/electrs',
      });
      expect(reparsed.pluginId, 'electrs');
    });
  });

  group('LightCheck', () {
    test('parses plugins_ahead when present', () {
      final json = {
        'checked_at': '2026-05-04T10:00:00.000Z',
        'ok': true,
        'inputs_ahead': [],
        'plugins_ahead': [
          {
            'plugin_id': 'electrs',
            'current_rev': 'a' * 40,
            'upstream_rev': 'b' * 40,
            'url': 'https://example/electrs',
          },
        ],
      };
      final lc = LightCheck.fromJson(json);
      expect(lc.pluginsAhead.length, 1);
      expect(lc.pluginsAhead.single.pluginId, 'electrs');
    });

    test('treats missing plugins_ahead as empty (backward compat)', () {
      final json = {
        'checked_at': '2026-05-04T10:00:00.000Z',
        'ok': true,
        'inputs_ahead': [],
      };
      final lc = LightCheck.fromJson(json);
      expect(lc.pluginsAhead, isEmpty);
    });

    test('serialises plugins_ahead', () {
      final lc = LightCheck(
        checkedAt: DateTime.utc(2026, 5, 4),
        ok: true,
        pluginsAhead: [
          PluginAhead(
            pluginId: 'mempool',
            currentRev: 'a' * 40,
            upstreamRev: 'b' * 40,
            url: 'https://example',
          ),
        ],
      );
      final j = lc.toJson();
      expect((j['plugins_ahead'] as List).length, 1);
    });
  });
}
