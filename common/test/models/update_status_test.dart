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

  group('CheckResult', () {
    test('parses plugins_ahead + inputs_ahead when present', () {
      final json = {
        'checked_at': '2026-05-04T10:00:00.000Z',
        'ok': true,
        'inputs_ahead': [
          {
            'name': 'nixpkgs',
            'current_rev': 'a' * 40,
            'upstream_rev': 'b' * 40,
            'url': 'github:NixOS/nixpkgs',
          },
        ],
        'plugins_ahead': [
          {
            'plugin_id': 'electrs',
            'current_rev': 'c' * 40,
            'upstream_rev': 'd' * 40,
            'url': 'https://example/electrs',
          },
        ],
        'diff_text': '',
        'no_changes': false,
      };
      final r = CheckResult.fromJson(json);
      expect(r.inputsAhead.length, 1);
      expect(r.inputsAhead.single.name, 'nixpkgs');
      expect(r.pluginsAhead.length, 1);
      expect(r.pluginsAhead.single.pluginId, 'electrs');
    });

    test('treats missing inputs/plugins as empty (backward compat)', () {
      final json = {
        'checked_at': '2026-05-04T10:00:00.000Z',
        'ok': true,
        'diff_text': '',
        'no_changes': false,
      };
      final r = CheckResult.fromJson(json);
      expect(r.inputsAhead, isEmpty);
      expect(r.pluginsAhead, isEmpty);
    });

    test('round-trips through toJson/fromJson', () {
      final original = CheckResult(
        checkedAt: DateTime.utc(2026, 5, 4),
        ok: true,
        inputsAhead: [
          const InputAhead(
            name: 'nixpkgs',
            currentRev: 'a',
            upstreamRev: 'b',
            url: '',
          ),
        ],
        pluginsAhead: [
          const PluginAhead(
            pluginId: 'mempool',
            currentRev: 'c',
            upstreamRev: 'd',
            url: '',
          ),
        ],
        diffText: '[U.] foo 1.0 → 1.1',
        wouldBuild: const ['rustc-1.87.0'],
      );
      final reparsed = CheckResult.fromJson(original.toJson());
      expect(reparsed.inputsAhead.length, 1);
      expect(reparsed.pluginsAhead.length, 1);
      expect(reparsed.diffText, '[U.] foo 1.0 → 1.1');
      expect(reparsed.wouldBuild, ['rustc-1.87.0']);
      expect(reparsed.compileNeeded, isTrue);
    });

    test('transcript round-trips through toJson/fromJson', () {
      final original = CheckResult(
        checkedAt: DateTime.utc(2026, 5, 4),
        ok: false,
        error: 'nix build failed',
        transcript: const ['• nix flake update', 'error: corrupt sqlite db'],
      );
      final reparsed = CheckResult.fromJson(original.toJson());
      expect(reparsed.transcript, [
        '• nix flake update',
        'error: corrupt sqlite db',
      ]);
    });

    test('missing transcript parses as empty (backward compat)', () {
      final json = {
        'checked_at': '2026-05-04T10:00:00.000Z',
        'ok': true,
        'diff_text': '',
        'no_changes': false,
      };
      final r = CheckResult.fromJson(json);
      expect(r.transcript, isEmpty);
    });

    test('empty transcript is omitted from toJson', () {
      final j = CheckResult(
        checkedAt: DateTime.utc(2026, 5, 4),
        ok: true,
      ).toJson();
      expect(j.containsKey('transcript'), isFalse);
    });

    test('compileNeeded reflects wouldBuild non-empty', () {
      final empty = CheckResult(checkedAt: DateTime.utc(2026, 5, 4), ok: true);
      expect(empty.compileNeeded, isFalse);
      final populated = CheckResult(
        checkedAt: DateTime.utc(2026, 5, 4),
        ok: true,
        wouldBuild: const ['a-1.0'],
      );
      expect(populated.compileNeeded, isTrue);
    });
  });

  group('UpdateStatus', () {
    test('empty round-trips through JSON', () {
      final j = UpdateStatus.empty().toJson();
      expect(j, isEmpty);
      final reparsed = UpdateStatus.fromJson(j);
      expect(reparsed.checkResult, isNull);
    });

    test('with checkResult round-trips through JSON', () {
      final s = UpdateStatus(
        checkResult: CheckResult(checkedAt: DateTime.utc(2026, 5, 4), ok: true),
      );
      final j = s.toJson();
      expect(j.containsKey('check_result'), isTrue);
      final reparsed = UpdateStatus.fromJson(j);
      expect(reparsed.checkResult, isNotNull);
      expect(reparsed.checkResult!.ok, isTrue);
    });
  });
}
