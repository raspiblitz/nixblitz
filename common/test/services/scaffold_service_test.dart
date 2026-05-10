import 'dart:io';
import 'package:test/test.dart';
import 'package:common/src/services/scaffold_service.dart';

void main() {
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
