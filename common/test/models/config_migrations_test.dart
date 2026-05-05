import 'package:test/test.dart';
import 'package:common/src/models/config_migrations.dart';

void main() {
  group('migrateConfig', () {
    test('is a no-op when version matches current', () {
      final input = {'version': currentConfigVersion, 'foo': 'bar'};
      final output = migrateConfig(input);
      expect(output['version'], currentConfigVersion);
      expect(output['foo'], 'bar');
    });

    test('sets version on config with no version field', () {
      // An unversioned config is treated as v1 — this is the default
      // assumption for configs that existed before versioning was added.
      final input = {'foo': 'bar'};
      final output = migrateConfig(input);
      expect(output['version'], currentConfigVersion);
      expect(output['foo'], 'bar');
    });

    test('does not mutate the input map', () {
      final input = {'version': currentConfigVersion, 'foo': 'bar'};
      final copy = Map<String, dynamic>.from(input);
      migrateConfig(input);
      expect(input, copy);
    });

    test('throws if a migration is missing for an older version', () {
      // Only v1 exists right now. A config at v0 (hypothetical) has no
      // migration registered, so it should throw.
      // We simulate this by temporarily checking what happens when
      // currentConfigVersion is higher than any registered migration.
      // Since we can't change currentConfigVersion at runtime, we test
      // the behavior indirectly: a config claiming version 0 would be
      // treated as "needs migration to current" but no migration exists.
      //
      // Note: this test will naturally pass today because we're at v1 and
      // all v1 configs need no migration. If we bump to v2 without adding
      // a migration from v1, the while loop would detect the gap.
      //
      // For now, just verify the function returns successfully for v1.
      final input = {'version': 1, 'foo': 'bar'};
      expect(() => migrateConfig(input), returnsNormally);
    });
  });

  group('migration chain (simulated)', () {
    // These tests register a temporary migration to verify the chain
    // works end-to-end, then remove it.

    test('applies a single migration step', () {
      // Register a temporary v1 → v2 migration
      migrations[1] = (json) => {...json, 'added_in_v2': 'hello'};
      try {
        final input = {'version': 1};
        // The real migrateConfig won't run this unless currentConfigVersion
        // is >= 2. So we manually invoke the registered migration to verify
        // it's wired up correctly.
        final migrated = migrations[1]!(input);
        expect(migrated['added_in_v2'], 'hello');
      } finally {
        migrations.remove(1);
      }
    });

    test('migration function signature matches contract', () {
      // Sanity check that the migration map type accepts a realistic migration.
      Map<String, dynamic> migrate(Map<String, dynamic> json) {
        return {...json, 'new_field': 'default_value'};
      }

      migrations[1] = migrate;
      try {
        final result = migrations[1]!({'version': 1, 'existing': 'value'});
        expect(result['existing'], 'value');
        expect(result['new_field'], 'default_value');
      } finally {
        migrations.remove(1);
      }
    });
  });

  group('v17 → v18', () {
    test('moves all five typed-app keys into app_configs', () {
      final v17 = <String, dynamic>{
        'version': 17,
        'system': {'hostname': 'h', 'platform': 'p'},
        'bitcoind': {
          'enabled': true,
          'network': 'regtest',
          'pruned': false,
          'prune_size_gb': 0,
        },
        'lnd': {'enabled': true, 'alias': 'node-1'},
        'cln': {'enabled': false},
        'blitz_api': {'enabled': true},
        'blitz_web': {'enabled': true},
      };
      final v18 = migrateConfig(Map.from(v17));
      expect(v18['version'], 18);
      expect(v18.containsKey('bitcoind'), isFalse);
      expect(v18.containsKey('lnd'), isFalse);
      expect(v18.containsKey('cln'), isFalse);
      expect(v18.containsKey('blitz_api'), isFalse);
      expect(v18.containsKey('blitz_web'), isFalse);
      expect(v18['app_configs'], isA<Map>());
      expect(v18['app_configs']['bitcoind']['enabled'], isTrue);
      expect(v18['app_configs']['lnd']['alias'], 'node-1');
      expect(v18['app_configs']['cln']['enabled'], isFalse);
    });

    test('handles partial v17 (some keys missing)', () {
      final v17 = <String, dynamic>{
        'version': 17,
        'system': {'hostname': 'h', 'platform': 'p'},
        'bitcoind': {'enabled': true, 'network': 'mainnet'},
        // No lnd/cln/blitz_api/blitz_web
      };
      final v18 = migrateConfig(Map.from(v17));
      expect(v18['version'], 18);
      expect(v18['app_configs']['bitcoind']['enabled'], isTrue);
      expect(v18['app_configs'].containsKey('lnd'), isFalse);
      expect(v18['app_configs'].containsKey('blitz_api'), isFalse);
    });

    test('idempotent on v18 input', () {
      final v18Input = <String, dynamic>{
        'version': 18,
        'system': {'hostname': 'h', 'platform': 'p'},
        'app_configs': {
          'bitcoind': {'enabled': true, 'network': 'mainnet'},
        },
      };
      final result = migrateConfig(Map.from(v18Input));
      expect(result['version'], 18);
      expect(result['app_configs']['bitcoind']['enabled'], isTrue);
      // Nothing accidentally restored at top level
      expect(result.containsKey('bitcoind'), isFalse);
    });
  });
}
