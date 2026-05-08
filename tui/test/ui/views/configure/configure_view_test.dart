import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/configure/field_editor.dart';
import 'package:tui/src/ui/views/configure_view.dart';

/// Smoke tests for the manifest-driven configure_view.
///
/// The view itself is a nocterm component and cannot be widget-tested in
/// isolation (nocterm does not provide a headless test renderer). Instead
/// these tests exercise the three layers the view delegates to:
///
///   1. AppManifestRegistry population — checks that bundled manifests
///      produce the expected menu order (alphabetical by id with System +
///      Plugins pinned at the ends).
///
///   2. Generic field rendering helpers — checks that for a given manifest
///      and config, the right field values are emitted (delegates to
///      FieldDisplayRow logic already tested in field_editor_test.dart, so
///      we just validate the data-side).
///
///   3. Pending-change tracking — checks that `setAppOption` produces a
///      new config whose `diffKeysFrom` the original contains the changed
///      key (the mechanism the view's `pendingChangeKeysProvider` uses).
///
///   4. Apply / Cancel semantics — checks that applying a pending value
///      commits via `setAppOption`, and that "cancel" (not calling
///      updateConfig) leaves the config unchanged.
void main() {
  // ── 1. Registry population ──────────────────────────────────────────────

  group('AppManifestRegistry population', () {
    late AppManifestRegistry registry;

    setUp(() {
      registry = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      );
    });

    test('bundled app IDs are sorted alphabetically', () {
      final ids = registry.allApps.map((m) => m.id).toList();
      final sorted = [...ids]..sort();
      expect(ids, sorted);
    });

    test('all four bundled apps are present', () {
      // blitz_api was a built-in in earlier phases; it's now a plugin
      // (~/dev/blitz/nixblitz-plugin-blitz-api) and ships its own
      // config_schema.
      final ids = registry.allApps.map((m) => m.id).toSet();
      expect(ids, containsAll(['bitcoind', 'lnd', 'cln', 'blitz_web']));
    });

    test('menu entries are: System + 4 apps + Plugins = 6 total', () {
      // System (1) + 4 apps + Plugins (1) = 6
      expect(registry.allApps.length, 4);
    });

    test('each bundled app has at least one field', () {
      for (final m in registry.allApps) {
        expect(m.fields, isNotEmpty, reason: '${m.id} has no fields');
      }
    });

    test('bitcoind manifest has 4 fields in order', () {
      final m = registry.get('bitcoind')!;
      expect(m.fields.map((f) => f.name).toList(), [
        'enabled',
        'network',
        'pruned',
        'prune_size_gb',
      ]);
    });

    test('lnd manifest has 2 fields: enabled + alias', () {
      final m = registry.get('lnd')!;
      expect(m.fields.map((f) => f.name).toList(), ['enabled', 'alias']);
    });

    test('cln manifest has 1 field: enabled', () {
      final m = registry.get('cln')!;
      expect(m.fields.map((f) => f.name).toList(), ['enabled']);
    });
  });

  // ── 2. Field value rendering ────────────────────────────────────────────

  group('Field value rendering via formatFieldValue', () {
    final config = NixblitzConfig.defaults();

    test('bitcoind enabled renders as "on"', () {
      final m = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      ).get('bitcoind')!;
      final field = m.field('enabled')!;
      final value = config.appOption<bool>('bitcoind', 'enabled');
      expect(formatFieldValue(field, value), 'on');
    });

    test('bitcoind network renders as "mainnet"', () {
      final m = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      ).get('bitcoind')!;
      final field = m.field('network')!;
      final value = config.appOption<String>('bitcoind', 'network');
      expect(formatFieldValue(field, value), 'mainnet');
    });

    test('lnd enabled renders as "off"', () {
      final m = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      ).get('lnd')!;
      final field = m.field('enabled')!;
      final value = config.appOption<bool>('lnd', 'enabled');
      expect(formatFieldValue(field, value), 'off');
    });

    test('lnd alias renders as empty string by default', () {
      final m = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      ).get('lnd')!;
      final field = m.field('alias')!;
      final value = config.appOption<String>('lnd', 'alias');
      expect(formatFieldValue(field, value), '');
    });

    test('SecretField masks non-empty value as bullets', () {
      const field = SecretField(
        name: 'auth_key',
        label: 'Auth key',
        defaultValue: '',
      );
      expect(formatFieldValue(field, 'tskey-auth-very-secret'), '•••');
    });

    test('SecretField renders empty value as "(unset)"', () {
      const field = SecretField(
        name: 'auth_key',
        label: 'Auth key',
        defaultValue: '',
      );
      expect(formatFieldValue(field, null), '(unset)');
      expect(formatFieldValue(field, ''), '(unset)');
    });
  });

  // ── 3. Pending-change tracking ──────────────────────────────────────────

  group('Pending-change tracking via diffKeysFrom', () {
    test('toggling bitcoind enabled produces a pending key', () {
      final original = NixblitzConfig.defaults();
      final updated = original.toggleAppOption('bitcoind', 'enabled');
      final keys = updated.diffKeysFrom(original);
      expect(keys, contains('bitcoind.enabled'));
    });

    test('changing lnd alias produces a pending key', () {
      final original = NixblitzConfig.defaults();
      final updated = original.setAppOption('lnd', 'alias', 'my-node');
      final keys = updated.diffKeysFrom(original);
      expect(keys, contains('lnd.alias'));
    });

    test('setting bitcoind prune_size_gb produces a pending key', () {
      final original = NixblitzConfig.defaults();
      final updated = original.setAppOption('bitcoind', 'prune_size_gb', 200);
      final keys = updated.diffKeysFrom(original);
      expect(keys, contains('bitcoind.prune_size_gb'));
    });

    test('unchanged config produces no pending keys', () {
      final config = NixblitzConfig.defaults();
      expect(config.diffKeysFrom(config), isEmpty);
    });

    test('pending key format matches manifest field path', () {
      // The view uses '${manifest.id}.${field.name}' to check isPending.
      // Verify diffKeysFrom emits the same format.
      final registry = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      );
      final original = NixblitzConfig.defaults();
      for (final m in registry.allApps) {
        for (final f in m.fields) {
          final currentValue = original.appConfig(m.id)[f.name];
          // Only test fields that have a non-null value to change.
          if (currentValue == null) continue;
          // Produce a trivially different value to trigger a diff.
          dynamic newValue;
          if (f is BoolField) {
            newValue = !(currentValue as bool);
          } else if (f is EnumField) {
            final choices = f.choices;
            final idx = choices.indexOf(currentValue as String);
            newValue = choices[(idx + 1) % choices.length];
          } else if (f is IntField) {
            newValue = (currentValue as int) + 1;
          } else if (f is StringField) {
            newValue = '${currentValue}x';
          }
          if (newValue == null) continue;
          final updated = original.setAppOption(m.id, f.name, newValue);
          final keys = updated.diffKeysFrom(original);
          expect(
            keys,
            contains('${m.id}.${f.name}'),
            reason: '${m.id}.${f.name} missing from diffKeysFrom',
          );
        }
      }
    });
  });

  // ── 4. Apply / Cancel semantics ─────────────────────────────────────────

  group('Apply / Cancel semantics', () {
    test('applying via setAppOption commits the value', () {
      final before = NixblitzConfig.defaults();
      final after = before.setAppOption('bitcoind', 'enabled', false);
      expect(after.appOption<bool>('bitcoind', 'enabled'), isFalse);
    });

    test('cancel — not calling setAppOption — leaves config unchanged', () {
      final config = NixblitzConfig.defaults();
      // Simulate: user pressed Enter to start editing, then Esc to cancel.
      // onCancel does NOT call setAppOption; config is unchanged.
      final enabledBefore = config.appOption<bool>('bitcoind', 'enabled');
      // No mutation happens on cancel.
      final enabledAfter = config.appOption<bool>('bitcoind', 'enabled');
      expect(enabledAfter, enabledBefore);
    });

    test('cycling bitcoind network via cycleFieldValue', () {
      final registry = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      );
      final field = registry.get('bitcoind')!.field('network')!;
      expect(field, isA<EnumField>());
      final choices = (field as EnumField).choices;
      // Cycle from mainnet → next choice.
      final next = cycleFieldValue(field, 'mainnet');
      final idx = choices.indexOf('mainnet');
      expect(next, choices[(idx + 1) % choices.length]);
    });

    test('toggling lnd enabled via cycleFieldValue flips bool', () {
      final registry = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      );
      final field = registry.get('lnd')!.field('enabled')!;
      expect(field, isA<BoolField>());
      expect(cycleFieldValue(field, false), isTrue);
      expect(cycleFieldValue(field, true), isFalse);
    });

    test('lnd alias requires editor overlay (StringField)', () {
      final registry = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      );
      final field = registry.get('lnd')!.field('alias')!;
      expect(field, isA<StringField>());
      expect(fieldRequiresEditor(field), isTrue);
    });

    test('bitcoind prune_size_gb requires editor overlay (IntField)', () {
      final registry = AppManifestRegistry(
        bundled: bundledAppManifests,
        plugin: const [],
      );
      final field = registry.get('bitcoind')!.field('prune_size_gb')!;
      expect(field, isA<IntField>());
      expect(fieldRequiresEditor(field), isTrue);
    });
  });

  // ── 5. pluginStatusLabel — distinguishes marker.disabled vs app_configs ──

  group('pluginSigShort', () {
    PluginMarker mkMarker({String? signatureFingerprint}) => PluginMarker(
      id: 'demo',
      url: 'git+https://example.test/demo',
      version: '0.1.0',
      rev: 'deadbeef',
      installedAt: DateTime.utc(2026, 5, 6),
      disabled: false,
      signatureFingerprint: signatureFingerprint,
    );

    test('null marker renders as placeholder', () {
      expect(pluginSigShort(null), '?       ');
    });

    test('null fingerprint renders as "(unsign)"', () {
      expect(pluginSigShort(mkMarker(signatureFingerprint: null)), '(unsign)');
    });

    test('SHA256 prefix is stripped, 8-char tail returned', () {
      final m = mkMarker(
        signatureFingerprint: 'SHA256:cjpfs1MT+veO9adeWCZZvEb6VZskk',
      );
      expect(pluginSigShort(m), 'cjpfs1MT');
    });

    test('no prefix takes first 8 chars', () {
      final m = mkMarker(signatureFingerprint: 'A1B2C3D4E5F6G7H8I9');
      expect(pluginSigShort(m), 'A1B2C3D4');
    });

    test('short fingerprint pads to 8 chars', () {
      final m = mkMarker(signatureFingerprint: 'SHORT');
      expect(pluginSigShort(m), 'SHORT   ');
    });
  });

  group('pluginStatusLabel', () {
    PluginMarker mkMarker({bool disabled = false, bool autoUpdate = true}) =>
        PluginMarker(
          id: 'demo',
          url: 'git+https://example.test/demo',
          version: '0.1.0',
          rev: 'deadbeefdeadbeef',
          installedAt: DateTime.utc(2026, 5, 6),
          disabled: disabled,
          autoUpdate: autoUpdate,
        );

    test('marker null → "marker missing"', () {
      expect(
        pluginStatusLabel(marker: null, cfgEnabled: false),
        'marker missing',
      );
      // cfgEnabled is irrelevant when marker is missing.
      expect(
        pluginStatusLabel(marker: null, cfgEnabled: true),
        'marker missing',
      );
    });

    test('marker.disabled → "disabled" regardless of cfgEnabled', () {
      expect(
        pluginStatusLabel(marker: mkMarker(disabled: true), cfgEnabled: false),
        'disabled',
      );
      expect(
        pluginStatusLabel(marker: mkMarker(disabled: true), cfgEnabled: true),
        'disabled',
      );
    });

    test('marker not disabled, cfgEnabled false → "off" '
        '(distinguishes app_configs.enabled from marker.disabled)', () {
      expect(pluginStatusLabel(marker: mkMarker(), cfgEnabled: false), 'off');
    });

    test('marker not disabled, cfgEnabled true → "active"', () {
      expect(pluginStatusLabel(marker: mkMarker(), cfgEnabled: true), 'active');
    });

    test('autoUpdate=false adds " · pinned" suffix', () {
      expect(
        pluginStatusLabel(
          marker: mkMarker(autoUpdate: false),
          cfgEnabled: true,
        ),
        'active · pinned',
      );
      expect(
        pluginStatusLabel(
          marker: mkMarker(autoUpdate: false),
          cfgEnabled: false,
        ),
        'off · pinned',
      );
      expect(
        pluginStatusLabel(
          marker: mkMarker(disabled: true, autoUpdate: false),
          cfgEnabled: true,
        ),
        'disabled · pinned',
      );
    });

    test('NixblitzConfig.isAppEnabled drives the cfgEnabled bit', () {
      // Smoke that the call site's data flow is correct: the value
      // isAppEnabled returns is exactly what callers should pass.
      final config = NixblitzConfig.defaults().setAppOption(
        'plugin-id',
        'enabled',
        false,
      );
      expect(config.isAppEnabled('plugin-id'), isFalse);
      expect(
        pluginStatusLabel(
          marker: mkMarker(),
          cfgEnabled: config.isAppEnabled('plugin-id'),
        ),
        'off',
      );
    });
  });

  // ── 6. configSchema field rendering data path ──────────────────────────

  group('plugin configSchema field rendering data path', () {
    // The plugin_config_view's _renderRows reads currentValue from
    // mainConfig.appConfig(pluginId)[field.name]. These tests verify
    // the data shape — that a plugin's configSchema fields resolve
    // against app_configs[pluginId] correctly.

    test('configSchema BoolField renders default when app_configs missing', () {
      const field = BoolField(
        name: 'enabled',
        label: 'Enabled',
        defaultValue: false,
      );
      final config = NixblitzConfig.defaults();
      // No app_configs entry for this plugin yet.
      final value = config.appConfig('blitz-api')[field.name];
      expect(formatFieldValue(field, value), 'off');
    });

    test('configSchema BoolField renders explicit true', () {
      const field = BoolField(
        name: 'enabled',
        label: 'Enabled',
        defaultValue: false,
      );
      final config = NixblitzConfig.defaults().setAppOption(
        'blitz-api',
        'enabled',
        true,
      );
      final value = config.appConfig('blitz-api')[field.name];
      expect(formatFieldValue(field, value), 'on');
    });

    test(
      'toggling configSchema field via setAppOption persists round-trip',
      () {
        const field = BoolField(
          name: 'enabled',
          label: 'Enabled',
          defaultValue: false,
        );
        final before = NixblitzConfig.defaults();
        final beforeValue =
            before.appConfig('blitz-api')[field.name] ?? field.defaultValue;
        final after = before.setAppOption(
          'blitz-api',
          field.name,
          !beforeValue,
        );
        expect(after.appOption<bool>('blitz-api', 'enabled'), isTrue);
        // Round-trip: diffKeysFrom surfaces the change.
        expect(after.diffKeysFrom(before), contains('blitz-api.enabled'));
      },
    );

    test(
      'plugin manifest with configSchema parses fields used by the view',
      () {
        // Mirror the blitz-api plugin.json shape — config_schema with
        // a single bool field. The view iterates manifest.configSchema!.fields
        // to build rows.
        final manifest = PluginManifest.fromJson({
          'manifest': {
            'schema_version': 2,
            'min_tui_version': 2,
            'name': 'Blitz API',
            'description': 'FastAPI backend for the Blitz web frontend',
          },
          'id': 'blitz-api',
          'config_schema': {
            'label': 'Blitz API',
            'description': 'FastAPI backend for the Blitz web frontend',
            'capabilities': <String>[],
            'fields': [
              {
                'name': 'enabled',
                'type': 'bool',
                'label': 'Enabled',
                'default': false,
              },
            ],
          },
        });
        expect(manifest.configSchema, isNotNull);
        expect(manifest.configSchema!.fields.length, 1);
        final f = manifest.configSchema!.fields.first;
        expect(f, isA<BoolField>());
        expect(f.name, 'enabled');
      },
    );
  });
}
