import 'package:test/test.dart';
import 'package:common/src/models/update_status.dart';
import 'package:common/src/models/updates_display.dart';

CheckResult _result({
  bool ok = true,
  String? error,
  List<PluginAhead> plugins = const [],
  String diffText = '',
  bool noChanges = false,
  List<String> wouldBuild = const [],
  List<String> lockInputsMoved = const [],
}) => CheckResult(
  checkedAt: DateTime(2026, 1, 1),
  ok: ok,
  error: error,
  inputsAhead: const [],
  pluginsAhead: plugins,
  diffText: diffText,
  noChanges: noChanges,
  wouldBuild: wouldBuild,
  lockInputsMoved: lockInputsMoved,
);

PluginAhead _plugin(String id) => PluginAhead(
  pluginId: id,
  currentRev: 'a' * 40,
  upstreamRev: 'b' * 40,
  url: 'forgejo:x/$id',
);

void main() {
  group('PluginAhead version display', () {
    test('uses manifest versions when present', () {
      final p = PluginAhead(
        pluginId: 'tailscale',
        currentRev: 'a' * 40,
        upstreamRev: 'b' * 40,
        url: 'forgejo:x/tailscale',
        currentVersion: '0.2.0',
        upstreamVersion: '0.3.0',
      );
      expect(p.displayFrom, '0.2.0');
      expect(p.displayTo, '0.3.0');
      expect(p.versionDelta, '0.2.0 → 0.3.0');
    });

    test('falls back to short revs when unversioned', () {
      final p = PluginAhead(
        pluginId: 'foo',
        currentRev: '1234567abcdef',
        upstreamRev: '89abcdef01234',
        url: 'forgejo:x/foo',
      );
      expect(p.displayFrom, '1234567');
      expect(p.displayTo, '89abcde');
      expect(p.versionDelta, '1234567 → 89abcde');
    });
  });

  group('mapUpdatesDisplay', () {
    test('null result → not checked, no note, no details', () {
      final d = mapUpdatesDisplay(result: null, aheadInputCount: 0);
      expect(d.nixblitz, UpdateRowStatus.notChecked);
      expect(d.plugins, UpdateRowStatus.notChecked);
      expect(d.applyNote, isNull);
      expect(d.detailsAvailable, isFalse);
      expect(d.error, isNull);
    });

    test('failed probe surfaces the error', () {
      final d = mapUpdatesDisplay(
        result: _result(ok: false, error: 'network down'),
        aheadInputCount: 0,
      );
      expect(d.error, 'network down');
      expect(d.nixblitz, UpdateRowStatus.notChecked);
    });

    test('all up to date → both ✓, no note, no details', () {
      final d = mapUpdatesDisplay(
        result: _result(noChanges: true),
        aheadInputCount: 0,
      );
      expect(d.nixblitz, UpdateRowStatus.upToDate);
      expect(d.plugins, UpdateRowStatus.upToDate);
      expect(d.applyNote, isNull);
      expect(d.detailsAvailable, isFalse);
    });

    test('an input ahead → NixBlitz update available + details', () {
      final d = mapUpdatesDisplay(
        result: _result(noChanges: false, diffText: '[U] x 1 -> 2'),
        aheadInputCount: 1,
      );
      expect(d.nixblitz, UpdateRowStatus.updateAvailable);
      expect(d.detailsAvailable, isTrue);
      expect(
        d.applyNote,
        'Applying downloads prebuilt packages (no local build).',
      );
    });

    test('plugins ahead → count + pluralization', () {
      final d = mapUpdatesDisplay(
        result: _result(plugins: [_plugin('a'), _plugin('b')]),
        aheadInputCount: 0,
      );
      expect(d.plugins, UpdateRowStatus.updateAvailable);
      expect(d.pluginsAheadCount, 2);
      expect(d.detailsAvailable, isTrue);
    });

    test('compile needed → build warning with N', () {
      final d = mapUpdatesDisplay(
        result: _result(wouldBuild: ['rustc', 'llvm', 'gcc']),
        aheadInputCount: 1,
      );
      expect(
        d.applyNote,
        'Applying builds 3 packages on the node first — can be slow on a Pi.',
      );
      expect(d.detailsAvailable, isTrue);
    });

    test('compile needed singular', () {
      final d = mapUpdatesDisplay(
        result: _result(wouldBuild: ['rustc']),
        aheadInputCount: 1,
      );
      expect(
        d.applyNote,
        'Applying builds 1 package on the node first — can be slow on a Pi.',
      );
    });

    test('rev moved but system unchanged → re-pin note', () {
      final d = mapUpdatesDisplay(
        result: _result(noChanges: true),
        aheadInputCount: 1,
      );
      expect(d.nixblitz, UpdateRowStatus.updateAvailable);
      expect(
        d.applyNote,
        'Inputs moved but the built system is unchanged — applying re-pins, '
        'nothing rebuilds.',
      );
    });

    test('staged lock movement flips the NixBlitz row even when the '
        'probe saw nothing (offline nodes: the nixblitz input is a '
        'path: pin the rev probe cannot query — the panel said "up to '
        'date" while the log staged a 20-package update)', () {
      final d = mapUpdatesDisplay(
        result: _result(
          wouldBuild: ['nixblitz-0.1.0'],
          lockInputsMoved: ['nixblitz'],
        ),
        aheadInputCount: 0,
      );
      expect(d.nixblitz, UpdateRowStatus.updateAvailable);
      expect(d.detailsAvailable, isTrue);
    });

    test('no probe hits and no lock movement stays up to date', () {
      final d = mapUpdatesDisplay(result: _result(), aheadInputCount: 0);
      expect(d.nixblitz, UpdateRowStatus.upToDate);
    });
  });
}
