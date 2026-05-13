import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('AppliedStateService', () {
    late Directory tmp;
    late AppliedStateService svc;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('applied-state-');
      svc = AppliedStateService(stateDir: tmp.path);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('read returns null when file is missing', () async {
      expect(await svc.read(), isNull);
    });

    test('write then read round-trips all fields', () async {
      svc.write(
        rev: 'abc1234',
        toplevel: '/nix/store/aaa-nixos-system-host-26.05',
        flakeAttr: 'x86-installed',
      );

      final state = await svc.read();
      expect(state, isNotNull);
      expect(state!.rev, 'abc1234');
      expect(state.toplevel, '/nix/store/aaa-nixos-system-host-26.05');
      expect(state.flakeAttr, 'x86-installed');
      // appliedAt should be close to "now" — a few seconds of skew is fine.
      expect(
        DateTime.now().difference(state.appliedAt).inSeconds.abs(),
        lessThan(10),
      );
    });

    test('write creates the state dir when missing', () async {
      final nested = Directory('${tmp.path}/nested/state');
      final s = AppliedStateService(stateDir: nested.path);
      s.write(rev: 'def5678', toplevel: '/nix/store/x', flakeAttr: 'pi5');
      expect(File('${nested.path}/last-applied.json').existsSync(), isTrue);
      final state = await s.read();
      expect(state?.rev, 'def5678');
    });

    test('corrupt JSON is swallowed and returns null', () async {
      File('${tmp.path}/last-applied.json').writeAsStringSync('not json');
      expect(await svc.read(), isNull);
    });

    test('missing required fields returns null', () async {
      File('${tmp.path}/last-applied.json').writeAsStringSync('{}');
      expect(await svc.read(), isNull);
    });

    test('write overwrites previous record', () async {
      svc.write(rev: 'first', toplevel: '/tl1', flakeAttr: 'attr1');
      svc.write(rev: 'second', toplevel: '/tl2', flakeAttr: 'attr2');
      final state = await svc.read();
      expect(state?.rev, 'second');
      expect(state?.toplevel, '/tl2');
    });
  });
}
