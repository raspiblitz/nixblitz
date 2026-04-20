import 'dart:convert';
import 'package:test/test.dart';
import 'package:common/src/models/nixblitz_config.dart';

void main() {
  group('NixblitzConfig', () {
    test('should create default config', () {
      final config = NixblitzConfig.defaults();
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
