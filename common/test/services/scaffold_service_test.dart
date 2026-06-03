import 'dart:io';
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('substituteNixblitzRef', () {
    test('substitutes ref into nested nixblitz block url', () {
      const template = '''
inputs = {
  nixblitz = {
    url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
''';
      final result = substituteNixblitzRef(template, 'main');
      expect(
        result,
        contains('url = "git+https://forge.f44.fyi/f44/nixblitz_ng?ref=main"'),
      );
      // The follows line must not be mangled
      expect(result, contains('inputs.nixpkgs.follows = "nixpkgs"'));
    });

    test('replaces an existing ?ref= in place', () {
      const template = '''
nixblitz = {
  url = "git+https://forge.f44.fyi/f44/nixblitz_ng?ref=old";
  inputs.nixpkgs.follows = "nixpkgs";
};
''';
      final result = substituteNixblitzRef(template, 'new');
      expect(result, contains('?ref=new'));
      expect(result, isNot(contains('?ref=old')));
    });

    test('throws on a template missing the nixblitz url', () {
      const template = 'inputs = { foo = {}; };';
      expect(
        () => substituteNixblitzRef(template, 'main'),
        throwsA(isA<StateError>()),
      );
    });

    test('handles ref with slash (e.g. release/1.0)', () {
      const template = '''
nixblitz = {
  url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
};
''';
      final result = substituteNixblitzRef(template, 'release/1.0');
      expect(result, contains('?ref=release/1.0'));
    });
  });

  group('resolveNixblitzRef', () {
    final manifest = BranchManifest.fromJson({
      'stable': {'ref': 'main', 'default': true},
      'next': {'ref': 'develop'},
    });

    test('null config field → default key ref + no warning', () {
      final (ref, warning) = resolveNixblitzRef(null, manifest);
      expect(ref, 'main');
      expect(warning, isNull);
    });

    test('declared key → that key ref + no warning', () {
      final (ref, warning) = resolveNixblitzRef('next', manifest);
      expect(ref, 'develop');
      expect(warning, isNull);
    });

    test('custom:<ref> → strip prefix, use literal + no warning', () {
      final (ref, warning) = resolveNixblitzRef(
        'custom:plugins-nostr-wot',
        manifest,
      );
      expect(ref, 'plugins-nostr-wot');
      expect(warning, isNull);
    });

    test('unknown declared key → default ref + warning', () {
      final (ref, warning) = resolveNixblitzRef('experimental', manifest);
      expect(ref, 'main');
      expect(warning, isNotNull);
      expect(warning, contains('experimental'));
    });

    test('null config with no default in manifest → throws StateError', () {
      final noDefault = BranchManifest.fromJson({
        'a': {'ref': 'main'},
        'b': {'ref': 'next'},
      });
      expect(
        () => resolveNixblitzRef(null, noDefault),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('ScaffoldService', () {
    late Directory tempDir;
    late ScaffoldService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_scaffold_test_');
      final targetDir = '${tempDir.path}/nixblitz';
      service = ScaffoldService(targetDir: targetDir);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('scaffold writes embedded templates to target', () async {
      await service.scaffold();
      final targetDir = Directory('${tempDir.path}/nixblitz');
      expect(targetDir.existsSync(), true);
      expect(File('${targetDir.path}/flake.nix').existsSync(), true);
      // bitcoind.nix / lnd.nix / cln.nix were removed; apps are plugins now.
      // Verify a system module is present instead.
      expect(
        File('${targetDir.path}/modules/system/base.nix').existsSync(),
        true,
      );
      expect(File('${targetDir.path}/hardware/x86.nix').existsSync(), true);
      expect(File('${targetDir.path}/hosts/default.nix').existsSync(), true);
    });

    test('scaffold does not overwrite existing directory', () async {
      final targetDir = Directory('${tempDir.path}/nixblitz');
      targetDir.createSync();
      File('${targetDir.path}/existing.txt').writeAsStringSync('keep');
      await service.scaffold();
      expect(File('${targetDir.path}/existing.txt').readAsStringSync(), 'keep');
    });

    test('needsScaffold returns true when target does not exist', () {
      expect(service.needsScaffold(), true);
    });

    test('needsScaffold returns false when target exists', () {
      Directory('${tempDir.path}/nixblitz').createSync();
      expect(service.needsScaffold(), false);
    });
  });
}
