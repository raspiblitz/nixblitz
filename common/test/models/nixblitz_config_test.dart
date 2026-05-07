import 'dart:convert';
import 'package:test/test.dart';
import 'package:common/src/models/config_migrations.dart';
import 'package:common/src/models/nixblitz_config.dart';

void main() {
  group('NixblitzConfig generic accessors', () {
    test('appOption returns null for missing app', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
      );
      expect(c.appOption<bool>('bitcoind', 'enabled'), isNull);
    });

    test('appOption returns null for missing key', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true},
        },
      );
      expect(c.appOption<String>('bitcoind', 'network'), isNull);
    });

    test('appOption returns null on type mismatch', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': 'yes'},
        },
      );
      expect(c.appOption<bool>('bitcoind', 'enabled'), isNull);
    });

    test('appOption returns value on type match', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true, 'network': 'mainnet'},
        },
      );
      expect(c.appOption<bool>('bitcoind', 'enabled'), isTrue);
      expect(c.appOption<String>('bitcoind', 'network'), 'mainnet');
    });

    test('isAppEnabled reads from app_configs', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true},
          'lnd': {'enabled': false},
        },
      );
      expect(c.isAppEnabled('bitcoind'), isTrue);
      expect(c.isAppEnabled('lnd'), isFalse);
      expect(c.isAppEnabled('cln'), isFalse);
    });

    test('setAppOption creates app entry when absent', () {
      final c0 = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
      );
      final c1 = c0.setAppOption('bitcoind', 'enabled', true);
      expect(c1.appOption<bool>('bitcoind', 'enabled'), isTrue);
    });

    test('setAppOption preserves other apps + other keys within same app', () {
      final c0 = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true, 'network': 'regtest'},
          'lnd': {'enabled': true},
        },
      );
      final c1 = c0.setAppOption('bitcoind', 'pruned', true);
      expect(c1.appOption<bool>('bitcoind', 'enabled'), isTrue);
      expect(c1.appOption<String>('bitcoind', 'network'), 'regtest');
      expect(c1.appOption<bool>('bitcoind', 'pruned'), isTrue);
      expect(c1.isAppEnabled('lnd'), isTrue);
    });

    test('toggleAppOption flips bool', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true},
        },
      );
      expect(
        c.toggleAppOption('bitcoind', 'enabled').isAppEnabled('bitcoind'),
        isFalse,
      );
    });

    test('toggleAppOption from missing → true', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
      );
      expect(
        c.toggleAppOption('bitcoind', 'enabled').isAppEnabled('bitcoind'),
        isTrue,
      );
    });

    test('removeAppConfig is no-op when app absent', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true},
        },
      );
      expect(c.removeAppConfig('lnd').appConfigs.length, c.appConfigs.length);
    });

    test('removeAppConfig drops the named app, preserves others', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true},
          'lnd': {'enabled': true},
        },
      );
      final c1 = c.removeAppConfig('bitcoind');
      expect(c1.appConfigs.containsKey('bitcoind'), isFalse);
      expect(c1.isAppEnabled('lnd'), isTrue);
    });

    test('appConfig returns empty map for absent app', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
      );
      expect(c.appConfig('bitcoind'), isEmpty);
    });

    test('appConfig returns full map for present app', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true, 'network': 'mainnet'},
        },
      );
      expect(c.appConfig('bitcoind'), {'enabled': true, 'network': 'mainnet'});
    });

    test('setAppConfig replaces whole app config', () {
      final c0 = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        appConfigs: const {
          'bitcoind': {'enabled': true, 'network': 'mainnet'},
        },
      );
      final c1 = c0.setAppConfig('bitcoind', {
        'enabled': false,
        'network': 'regtest',
      });
      expect(c1.appOption<bool>('bitcoind', 'enabled'), isFalse);
      expect(c1.appOption<String>('bitcoind', 'network'), 'regtest');
    });
  });

  group('NixblitzConfig.fromJson v18', () {
    test('round-trip with five apps', () {
      final systemJson = SystemConfig.defaults().toJson();
      final json = <String, dynamic>{
        'schema_version': 18,
        'system': systemJson,
        'app_configs': {
          'bitcoind': {
            'enabled': true,
            'network': 'regtest',
            'pruned': false,
            'prune_size_gb': 0,
          },
          'lnd': {'enabled': true, 'alias': 'hello'},
          'cln': {'enabled': false},
          'blitz_api': {'enabled': true},
          'blitz_web': {'enabled': true},
        },
      };
      final c = NixblitzConfig.fromJson(json);
      expect(c.schemaVersion, 18);
      expect(c.isAppEnabled('bitcoind'), isTrue);
      expect(c.appOption<String>('bitcoind', 'network'), 'regtest');
      expect(c.appOption<String>('lnd', 'alias'), 'hello');
      expect(c.isAppEnabled('cln'), isFalse);

      final back = c.toJson();
      expect(back['schema_version'], 18);
      expect((back['app_configs'] as Map)['bitcoind']['network'], 'regtest');
    });

    test('empty app_configs', () {
      final c = NixblitzConfig.fromJson({
        'schema_version': 18,
        'system': SystemConfig.defaults().toJson(),
        'app_configs': <String, dynamic>{},
      });
      expect(c.isAppEnabled('bitcoind'), isFalse);
    });

    test('missing app_configs defaults to empty', () {
      final c = NixblitzConfig.fromJson({
        'schema_version': 18,
        'system': SystemConfig.defaults().toJson(),
      });
      expect(c.appConfigs, isEmpty);
    });
  });

  group('NixblitzConfig fields', () {
    test('schemaVersion preserved through copyWith', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
      );
      expect(c.copyWith(system: SystemConfig.defaults()).schemaVersion, 18);
    });

    test('initialized round-trips through JSON', () {
      final c = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        initialized: true,
      );
      final json = jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
      final r = NixblitzConfig.fromJson(json);
      expect(r.initialized, isTrue);
    });

    test('setupStepCompleted nullable copyWith sentinel', () {
      final c0 = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults(),
        setupStepCompleted: 'buildServices',
      );
      // Omit → inherit
      final c1 = c0.copyWith(initialized: true);
      expect(c1.setupStepCompleted, 'buildServices');
      // Explicit null → clear
      final c2 = c0.copyWith(setupStepCompleted: () => null);
      expect(c2.setupStepCompleted, isNull);
    });

    test('disk_device round-trips through JSON', () {
      final config = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults().copyWith(diskDevice: '/dev/sda'),
      );
      final json =
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>;
      expect(
        (json['system'] as Map<String, dynamic>)['disk_device'],
        '/dev/sda',
      );
      final restored = NixblitzConfig.fromJson(json);
      expect(restored.system.diskDevice, '/dev/sda');
    });

    test('shell round-trips through JSON', () {
      final config = NixblitzConfig(
        schemaVersion: 18,
        system: SystemConfig.defaults().copyWith(shell: 'nushell'),
      );
      final json =
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>;
      expect((json['system'] as Map<String, dynamic>)['shell'], 'nushell');
      final restored = NixblitzConfig.fromJson(json);
      expect(restored.system.shell, 'nushell');
    });

    test(
      'should throw ConfigTooNewException when min_compatible_version is higher',
      () {
        final tooNewMin = currentConfigVersion + 2;
        final json = {
          'schema_version': tooNewMin + 2,
          'min_compatible_version': tooNewMin,
          'system': SystemConfig.defaults().toJson(),
          'app_configs': <String, dynamic>{},
        };
        expect(
          () => NixblitzConfig.fromJson(json),
          throwsA(isA<ConfigTooNewException>()),
        );
      },
    );
  });

  group('SystemConfig', () {
    test('defaults are correct', () {
      final s = SystemConfig.defaults();
      expect(s.hostname, 'nixblitz');
      expect(s.timezone, 'UTC');
      expect(s.platform, 'x86');
      expect(s.diskDevice, '');
      expect(s.shell, 'bash');
    });

    test('round-trips through JSON', () {
      final s = SystemConfig(
        hostname: 'mynode',
        timezone: 'Europe/Berlin',
        platform: 'rpi4',
        diskDevice: '/dev/sda',
        shell: 'nushell',
      );
      final r = SystemConfig.fromJson(s.toJson());
      expect(r, s);
    });

    test('missing fields default correctly', () {
      final s = SystemConfig.fromJson({
        'hostname': 'x',
        'timezone': 'UTC',
        'platform': 'x86',
      });
      expect(s.diskDevice, '');
      expect(s.shell, 'bash');
    });
  });
}
