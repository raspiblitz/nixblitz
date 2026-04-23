import 'dart:convert';
import 'package:test/test.dart';
import 'package:common/src/models/config_migrations.dart';
import 'package:common/src/models/nixblitz_config.dart';

void main() {
  group('NixblitzConfig', () {
    test('should create default config', () {
      final config = NixblitzConfig.defaults();
      expect(config.version, currentConfigVersion);
      expect(config.initialized, false);
      expect(config.system.hostname, 'nixblitz');
      expect(config.system.timezone, 'UTC');
      expect(config.system.platform, 'x86');
      expect(config.bitcoind.enabled, true);
      expect(config.bitcoind.network, 'mainnet');
      expect(config.bitcoind.pruned, true);
      expect(config.bitcoind.pruneSizeGb, 550);
      expect(config.lnd.enabled, false);
      expect(config.cln.enabled, false);
      expect(config.blitzApi.enabled, true);
      expect(config.blitzWeb.enabled, true);
    });

    test('should include version in serialized JSON', () {
      final config = NixblitzConfig.defaults();
      final json = config.toJson();
      expect(json['version'], currentConfigVersion);
    });

    test('should default to version 1 when version field is missing', () {
      final json = {
        'initialized': false,
        'system': {'hostname': 'x', 'timezone': 'UTC', 'platform': 'x86'},
        'bitcoind': {
          'enabled': true,
          'network': 'mainnet',
          'pruned': true,
          'prune_size_gb': 550,
        },
        'lnd': {'enabled': false, 'alias': ''},
        'cln': {'enabled': false},
        'blitz_api': {'enabled': false},
        'blitz_web': {'enabled': false},
      };
      final config = NixblitzConfig.fromJson(json);
      expect(config.version, currentConfigVersion);
    });

    test(
      'should preserve unknown fields from newer config (forward compat)',
      () {
        final json = {
          'version': 999,
          'initialized': true,
          'system': {
            'hostname': 'future',
            'timezone': 'UTC',
            'platform': 'x86',
          },
          'bitcoind': {
            'enabled': true,
            'network': 'mainnet',
            'pruned': true,
            'prune_size_gb': 550,
          },
          'lnd': {'enabled': false, 'alias': ''},
          'cln': {'enabled': false},
          'blitz_api': {'enabled': false},
          'blitz_web': {'enabled': false},
          'newer_service': {'enabled': true, 'endpoint': 'localhost:1234'},
        };
        final config = NixblitzConfig.fromJson(json);
        expect(config.version, 999);
        final reencoded = config.toJson();
        expect(reencoded['newer_service'], {
          'enabled': true,
          'endpoint': 'localhost:1234',
        });
      },
    );

    test('should preserve version through copyWith', () {
      final config = NixblitzConfig.defaults();
      final modified = config.copyWith(initialized: true);
      expect(modified.version, currentConfigVersion);
    });

    test('should throw ConfigTooNewException when min_compatible_version is higher', () {
      final tooNewMin = currentConfigVersion + 2;
      final json = {
        'version': tooNewMin + 2,
        'min_compatible_version': tooNewMin,
        'initialized': false,
        'system': {'hostname': 'x', 'timezone': 'UTC', 'platform': 'x86'},
        'bitcoind': {
          'enabled': true,
          'network': 'mainnet',
          'pruned': true,
          'prune_size_gb': 550,
        },
        'lnd': {'enabled': false, 'alias': ''},
        'cln': {'enabled': false},
        'blitz_api': {'enabled': false},
        'blitz_web': {'enabled': false},
      };
      expect(
        () => NixblitzConfig.fromJson(json),
        throwsA(isA<ConfigTooNewException>()),
      );
    });

    test('should preserve configMinCompatibleVersion from file on write-back', () {
      // Newer TUI wrote a config with its own min_compatible_version. An
      // older TUI at the same version reads it, modifies it, writes it
      // back — the min should survive the round-trip unchanged.
      final json = {
        'version': currentConfigVersion,
        'min_compatible_version': minCompatibleVersion,
        'initialized': true,
        'system': {'hostname': 'x', 'timezone': 'UTC', 'platform': 'x86'},
        'bitcoind': {
          'enabled': true,
          'network': 'mainnet',
          'pruned': true,
          'prune_size_gb': 550,
        },
        'lnd': {'enabled': false, 'alias': ''},
        'cln': {'enabled': false},
        'blitz_api': {'enabled': false},
        'blitz_web': {'enabled': false},
      };
      final config = NixblitzConfig.fromJson(json);
      expect(config.configMinCompatibleVersion, minCompatibleVersion);
      final written = config.toJson();
      expect(written['min_compatible_version'], minCompatibleVersion);
      expect(written['version'], currentConfigVersion);
    });

    test('should write current minCompatibleVersion for fresh configs', () {
      final config = NixblitzConfig.defaults();
      final json = config.toJson();
      expect(json['min_compatible_version'], minCompatibleVersion);
    });

    test('should round-trip via JSON without losing version', () {
      final config = NixblitzConfig.defaults().copyWith(initialized: true);
      final json = jsonEncode(config.toJson());
      final restored = NixblitzConfig.fromJson(jsonDecode(json));
      expect(restored.version, currentConfigVersion);
    });

    test(
      'older TUI reading newer config then writing back preserves forward-compat fields',
      () {
        // Simulate: newer TUI wrote v999 with extra sections.
        // Older TUI (at currentConfigVersion) reads it, makes a change,
        // and writes it back. The unknown fields must survive.
        final newerJson = {
          'version': 999,
          'initialized': true,
          'system': {
            'hostname': 'host',
            'timezone': 'UTC',
            'platform': 'x86',
          },
          'bitcoind': {
            'enabled': true,
            'network': 'mainnet',
            'pruned': true,
            'prune_size_gb': 550,
          },
          'lnd': {'enabled': false, 'alias': ''},
          'cln': {'enabled': false},
          'blitz_api': {'enabled': false},
          'blitz_web': {'enabled': false},
          'zeus': {'enabled': true, 'port': 9999},
          'nostr_relay': {'enabled': false},
        };

        // Read with older TUI
        final config = NixblitzConfig.fromJson(newerJson);
        expect(config.version, 999);

        // Older TUI modifies a known field
        final modified = config.copyWith(
          bitcoind: config.bitcoind.copyWith(network: 'testnet'),
        );

        // Write back
        final written = modified.toJson();

        // Forward-compat fields still there
        expect(written['zeus'], {'enabled': true, 'port': 9999});
        expect(written['nostr_relay'], {'enabled': false});

        // Version preserved (older TUI doesn't downgrade newer configs)
        expect(written['version'], 999);

        // Modified field is updated
        expect(
          (written['bitcoind'] as Map)['network'],
          'testnet',
        );
      },
    );

    test('should serialize to JSON and back', () {
      final config = NixblitzConfig.defaults();
      final json = jsonEncode(config.toJson());
      final restored = NixblitzConfig.fromJson(jsonDecode(json));
      expect(restored.initialized, config.initialized);
      expect(restored.system.hostname, config.system.hostname);
      expect(restored.bitcoind.network, config.bitcoind.network);
      expect(restored.lnd.enabled, config.lnd.enabled);
    });

    test('should produce diff description for changed fields', () {
      final before = NixblitzConfig.defaults();
      final after = before.copyWith(
        bitcoind: before.bitcoind.copyWith(network: 'testnet'),
      );
      final diff = after.diffFrom(before);
      expect(diff, contains('bitcoind'));
      expect(diff, contains('testnet'));
    });

    test('should round-trip unknown fields in JSON', () {
      final json = {
        'initialized': false,
        'system': {'hostname': 'test', 'timezone': 'UTC', 'platform': 'x86'},
        'bitcoind': {'enabled': true, 'network': 'mainnet', 'pruned': false, 'prune_size_gb': 550},
        'lnd': {'enabled': false, 'alias': ''},
        'cln': {'enabled': false},
        'blitz_api': {'enabled': false},
        'blitz_web': {'enabled': false},
        'some_future_field': {'value': 42},
      };
      final config = NixblitzConfig.fromJson(json);
      final reencoded = config.toJson();
      expect(reencoded['some_future_field'], {'value': 42});
    });
  });
}
