import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('StagingService', () {
    late Directory tmp;
    late StagingService svc;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('staging-svc-');
      svc = StagingService(basePath: tmp.path);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('read of empty dir returns StagedChanges.empty', () {
      final s = svc.read();
      expect(s.lockBumpAvailable, isFalse);
      expect(s.pluginPins, isEmpty);
      expect(s.nvdDiff, isNull);
      expect(s.newToplevel, isNull);
      expect(s.checkedAt, isNull);
      expect(s.isEmpty, isTrue);
      expect(s.count, 0);
    });

    test('writeLockBump + read reports lockBumpAvailable', () {
      final source = File('${tmp.path}/source.lock');
      source.writeAsStringSync('{"nodes":{}}');
      svc.writeLockBump(source);

      final s = svc.read();
      expect(s.lockBumpAvailable, isTrue);
      expect(s.isNotEmpty, isTrue);
      expect(s.count, 1);
      // Staged copy is at the documented location.
      expect(File(svc.lockPath).existsSync(), isTrue);
      expect(File(svc.lockPath).readAsStringSync(), '{"nodes":{}}');
    });

    test('writePluginPins round-trips through read', () {
      final pin = PluginAhead(
        pluginId: 'cachepop',
        currentRev: '4a3f9e1' * 4 + '4a3f9e1ab',
        upstreamRev: 'b8c2d7e' * 4 + 'b8c2d7eab',
        url: 'forgejo:forge.f44.fyi/f44/cachepop',
        currentVersion: '0.1.0',
        upstreamVersion: '0.2.0',
      );
      svc.writePluginPins([pin]);

      final s = svc.read();
      expect(s.pluginPins.length, 1);
      expect(s.pluginPins.first.pluginId, 'cachepop');
      expect(s.pluginPins.first.currentVersion, '0.1.0');
      expect(s.pluginPins.first.upstreamVersion, '0.2.0');
      expect(s.count, 1);
    });

    test('writeNvdDiff + writeNewToplevel + writeCheckedAt round-trip', () {
      svc.writeNvdDiff('  bitcoind: 27.0 -> 27.1\n');
      svc.writeNewToplevel('/nix/store/abcd-system');
      final ts = DateTime.utc(2026, 5, 18, 12, 0, 0);
      svc.writeCheckedAt(ts);

      final s = svc.read();
      expect(s.nvdDiff, '  bitcoind: 27.0 -> 27.1\n');
      expect(s.newToplevel, '/nix/store/abcd-system');
      expect(s.checkedAt, ts);
    });

    test('clearAll wipes every artifact', () {
      final source = File('${tmp.path}/source.lock')..writeAsStringSync('{}');
      svc.writeLockBump(source);
      svc.writeNvdDiff('diff');
      svc.writeCheckedAt(DateTime.utc(2026, 5, 18));

      svc.clearAll();
      final s = svc.read();
      expect(s.isEmpty, isTrue);
      expect(File(svc.lockPath).existsSync(), isFalse);
    });

    test('clearLockBump leaves plugin pins intact', () {
      final source = File('${tmp.path}/source.lock')..writeAsStringSync('{}');
      svc.writeLockBump(source);
      svc.writePluginPins([
        const PluginAhead(
          pluginId: 'cachepop',
          currentRev: 'aaaaaaa',
          upstreamRev: 'bbbbbbb',
          url: '',
        ),
      ]);

      svc.clearLockBump();
      final s = svc.read();
      expect(s.lockBumpAvailable, isFalse);
      expect(s.pluginPins.length, 1);
    });

    test('clearPluginPins leaves lock bump intact', () {
      final source = File('${tmp.path}/source.lock')..writeAsStringSync('{}');
      svc.writeLockBump(source);
      svc.writePluginPins([
        const PluginAhead(
          pluginId: 'cachepop',
          currentRev: 'aaaaaaa',
          upstreamRev: 'bbbbbbb',
          url: '',
        ),
      ]);

      svc.clearPluginPins();
      final s = svc.read();
      expect(s.lockBumpAvailable, isTrue);
      expect(s.pluginPins, isEmpty);
    });

    test('corrupt plugin-pins.json is treated as empty', () {
      Directory(tmp.path).createSync(recursive: true);
      File('${tmp.path}/plugin-pins.json').writeAsStringSync('not json');
      final s = svc.read();
      expect(s.pluginPins, isEmpty);
    });

    test('count counts lock bump + each plugin pin', () {
      final source = File('${tmp.path}/source.lock')..writeAsStringSync('{}');
      svc.writeLockBump(source);
      svc.writePluginPins([
        const PluginAhead(
          pluginId: 'cachepop',
          currentRev: 'a',
          upstreamRev: 'b',
          url: '',
        ),
        const PluginAhead(
          pluginId: 'blitz-api',
          currentRev: 'c',
          upstreamRev: 'd',
          url: '',
        ),
      ]);
      expect(svc.read().count, 3);
    });
  });
}
