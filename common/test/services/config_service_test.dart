import 'dart:io';
import 'package:test/test.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/services/config_service.dart';

void main() {
  group('ConfigService', () {
    late Directory tempDir;
    late ConfigService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_test_');
      service = ConfigService(baseDir: tempDir.path);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('configExists returns false when no config.json', () {
      expect(service.configExists(), false);
    });

    test(
      'writeConfig creates config.json and readConfig restores it',
      () async {
        final config = NixblitzConfig.defaults();
        await service.writeConfig(config);
        expect(service.configExists(), true);
        final restored = await service.readConfig();
        expect(restored.system.hostname, config.system.hostname);
        expect(restored.bitcoind.network, config.bitcoind.network);
      },
    );

    test('readConfig returns initialized state correctly', () async {
      final config = NixblitzConfig.defaults().copyWith(initialized: true);
      await service.writeConfig(config);
      final restored = await service.readConfig();
      expect(restored.initialized, true);
    });

    test('writeConfig produces pretty-printed JSON', () async {
      final config = NixblitzConfig.defaults();
      await service.writeConfig(config);
      final file = File('${tempDir.path}/config.json');
      final content = await file.readAsString();
      expect(content, contains('\n'));
      expect(content, contains('  '));
    });
  });
}
