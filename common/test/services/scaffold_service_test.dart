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

    test('clearTargetSync removes an existing target dir', () async {
      await service.scaffold();
      expect(Directory('${tempDir.path}/nixblitz').existsSync(), true);
      service.clearTargetSync();
      expect(Directory('${tempDir.path}/nixblitz').existsSync(), false);
    });

    test('clearTargetSync is a no-op when the target is absent', () {
      // Must not throw on a missing directory.
      service.clearTargetSync();
      expect(Directory('${tempDir.path}/nixblitz').existsSync(), false);
    });
  });

  group('copyOfflineLockIfPresent', () {
    late Directory tempDir;
    late ScaffoldService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_scaffold_test_');
      final targetDir = '${tempDir.path}/nixblitz';
      Directory(targetDir).createSync(recursive: true);
      service = ScaffoldService(targetDir: targetDir);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('copies the offline lock into baseDir when the source exists', () {
      final baseDir = '${tempDir.path}/nixblitz';
      final offlineLock = File('${tempDir.path}/offline-flake.lock');
      offlineLock.writeAsStringSync('{"nodes": {"root": {}}}');

      service.copyOfflineLockIfPresent(
        baseDir,
        offlineLockPath: offlineLock.path,
      );

      final copied = File('$baseDir/flake.lock');
      expect(copied.existsSync(), true);
      expect(copied.readAsStringSync(), offlineLock.readAsStringSync());
    });

    test('copied lock is writable even when the source is read-only '
        '(store-backed /etc/nixblitz/offline-flake.lock is mode 444; a '
        'preserved mode breaks every later re-lock with EACCES)', () {
      final baseDir = '${tempDir.path}/nixblitz';
      final offlineLock = File('${tempDir.path}/offline-flake.lock');
      offlineLock.writeAsStringSync('{"nodes": {"root": {}}}');
      Process.runSync('chmod', ['444', offlineLock.path]);

      service.copyOfflineLockIfPresent(
        baseDir,
        offlineLockPath: offlineLock.path,
      );

      final copied = File('$baseDir/flake.lock');
      expect(copied.existsSync(), true);
      // Overwriting in place is the writability proof — this is exactly
      // what `nix flake update` needs to do.
      expect(() => copied.writeAsStringSync('{"nodes": {}}'), returnsNormally);

      // Re-scaffold over the existing lock must also succeed.
      expect(
        () => service.copyOfflineLockIfPresent(
          baseDir,
          offlineLockPath: offlineLock.path,
        ),
        returnsNormally,
      );
      expect(copied.readAsStringSync(), offlineLock.readAsStringSync());
    });

    test('is a no-op when the offline lock source is absent', () {
      final baseDir = '${tempDir.path}/nixblitz';
      final missingPath = '${tempDir.path}/does-not-exist.lock';

      expect(
        () => service.copyOfflineLockIfPresent(
          baseDir,
          offlineLockPath: missingPath,
        ),
        returnsNormally,
      );
      expect(File('$baseDir/flake.lock').existsSync(), false);
    });

    test('refreshTemplatesSync copies the offline lock when present, via the '
        'injectable path (exercises the same call site install_view uses)', () {
      final baseDir = '${tempDir.path}/nixblitz';
      final offlineLock = File('${tempDir.path}/offline-flake.lock');
      offlineLock.writeAsStringSync('{"nodes": {"root": {}}}');

      service.refreshTemplatesSync(offlineLockPath: offlineLock.path);

      expect(File('$baseDir/flake.lock').existsSync(), true);
      expect(
        File('$baseDir/flake.lock').readAsStringSync(),
        offlineLock.readAsStringSync(),
      );
    });

    test('refreshTemplatesSync does not create flake.lock when the offline '
        'lock is absent', () {
      final baseDir = '${tempDir.path}/nixblitz';
      final missingPath = '${tempDir.path}/does-not-exist.lock';

      service.refreshTemplatesSync(offlineLockPath: missingPath);

      expect(File('$baseDir/flake.lock').existsSync(), false);
    });
  });

  group('stripHardwareConfigMounts', () {
    test('removes fileSystems and swapDevices blocks, keeps the rest', () {
      const hw = '''
{ config, lib, ... }:
{
  boot.initrd.availableKernelModules = [ "xhci_pci" ];
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/abcd";
      fsType = "ext4";
    };
  swapDevices = [ ];
  networking.useDHCP = lib.mkDefault true;
}
''';
      final out = stripHardwareConfigMounts(hw);
      expect(out, contains('availableKernelModules'));
      expect(out, contains('networking.useDHCP'));
      expect(out, isNot(contains('fileSystems')));
      expect(out, isNot(contains('swapDevices')));
      expect(out, isNot(contains('/dev/disk/by-uuid/abcd')));
    });

    test('single-line swapDevices with trailing ; is removed', () {
      final out = stripHardwareConfigMounts('swapDevices = [ ];\nx = 1;');
      expect(out, isNot(contains('swapDevices')));
      expect(out, contains('x = 1;'));
    });
  });
}
