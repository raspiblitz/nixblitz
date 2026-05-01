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
      // Empty by default — set by the install wizard from the
      // operator's chosen disk. Falls back to the disko module's
      // per-platform default at eval time when empty.
      expect(config.system.diskDevice, '');
      expect(config.bitcoind.enabled, true);
      expect(config.bitcoind.network, 'mainnet');
      expect(config.bitcoind.pruned, true);
      expect(config.bitcoind.pruneSizeGb, 550);
      expect(config.lnd.enabled, false);
      expect(config.cln.enabled, false);
      expect(config.blitzApi.enabled, true);
      expect(config.blitzWeb.enabled, true);
    });

    test('disk_device round-trips through JSON', () {
      // The post-install grub-install regression on bare-metal
      // x86 was caused by this field NOT being persisted, so the
      // installed system kept defaulting `disko.devices.disk.main.device`
      // to /dev/vda even though disko-install partitioned /dev/sda.
      // Pin the round-trip so a future refactor can't quietly
      // drop the field.
      final config = NixblitzConfig.defaults().copyWith(
        system: NixblitzConfig.defaults().system.copyWith(
          diskDevice: '/dev/sda',
        ),
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

    test('disk_device defaults to empty when missing from JSON', () {
      // Configs from before v15 don't have disk_device. Reading
      // them must not throw — the field falls through to the
      // disko module's default. Regression guard for older
      // installs upgrading.
      final json = {
        'version': 14,
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
      expect(config.system.diskDevice, '');
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

    test(
      'should throw ConfigTooNewException when min_compatible_version is higher',
      () {
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
      },
    );

    test(
      'should preserve configMinCompatibleVersion from file on write-back',
      () {
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
      },
    );

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
          'system': {'hostname': 'host', 'timezone': 'UTC', 'platform': 'x86'},
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
        expect((written['bitcoind'] as Map)['network'], 'testnet');
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

    group('diffKeysFrom', () {
      test('returns empty set for equal configs', () {
        final a = NixblitzConfig.defaults();
        final b = NixblitzConfig.defaults();
        expect(a.diffKeysFrom(b), isEmpty);
      });

      test('flags single field changed in each section', () {
        final base = NixblitzConfig.defaults();

        final sys = base.copyWith(
          system: base.system.copyWith(hostname: 'newname'),
        );
        expect(sys.diffKeysFrom(base), {'system.hostname'});

        final btc = base.copyWith(
          bitcoind: base.bitcoind.copyWith(pruned: !base.bitcoind.pruned),
        );
        expect(btc.diffKeysFrom(base), {'bitcoind.pruned'});

        final lnd = base.copyWith(lnd: base.lnd.copyWith(alias: 'MyNode'));
        expect(lnd.diffKeysFrom(base), {'lnd.alias'});

        final cln = base.copyWith(
          cln: base.cln.copyWith(enabled: !base.cln.enabled),
        );
        expect(cln.diffKeysFrom(base), {'cln.enabled'});

        final api = base.copyWith(
          blitzApi: base.blitzApi.copyWith(enabled: !base.blitzApi.enabled),
        );
        expect(api.diffKeysFrom(base), {'blitz_api.enabled'});

        final web = base.copyWith(
          blitzWeb: base.blitzWeb.copyWith(enabled: !base.blitzWeb.enabled),
        );
        expect(web.diffKeysFrom(base), {'blitz_web.enabled'});
      });

      test('flags multiple sections at once with snake_case keys', () {
        final base = NixblitzConfig.defaults();
        final after = base.copyWith(
          system: base.system.copyWith(hostname: 'foo'),
          bitcoind: base.bitcoind.copyWith(pruneSizeGb: 1024),
          lnd: base.lnd.copyWith(alias: 'bar'),
        );
        // The numeric-field assertion specifically guards the
        // snake_case requirement that diffKeysFrom must mirror
        // toJson()'s key shape — Configure view's
        // _pendingKeyFor lookup depends on this.
        expect(after.diffKeysFrom(base), {
          'system.hostname',
          'bitcoind.prune_size_gb',
          'lnd.alias',
        });
      });

      test('flags top-level field toggles', () {
        final base = NixblitzConfig.defaults();
        final after = base.copyWith(
          initialized: !base.initialized,
          setupStepCompleted: () => 'buildServices',
        );
        expect(after.diffKeysFrom(base), {
          'initialized',
          'setup_step_completed',
        });
      });

      test('ignores _extra (forward-compat) fields', () {
        // Round-trip a config that carries an unknown field
        // through fromJson/_extra. diffKeysFrom must not
        // surface that field — it's not operator-visible and
        // doesn't have a Configure-view row to mark.
        final base = NixblitzConfig.defaults();
        final json = base.toJson()..['some_future_field'] = {'a': 1};
        final withExtra = NixblitzConfig.fromJson(json);
        expect(withExtra.diffKeysFrom(base), isEmpty);
      });
    });

    test('should round-trip unknown fields in JSON', () {
      final json = {
        'initialized': false,
        'system': {'hostname': 'test', 'timezone': 'UTC', 'platform': 'x86'},
        'bitcoind': {
          'enabled': true,
          'network': 'mainnet',
          'pruned': false,
          'prune_size_gb': 550,
        },
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
