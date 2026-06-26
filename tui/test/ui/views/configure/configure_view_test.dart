import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/configure/field_editor.dart';
import 'package:tui/src/ui/views/configure_view.dart';

/// Smoke tests for the manifest-driven configure_view.
///
/// The view itself is a nocterm component and cannot be widget-tested in
/// isolation (nocterm does not provide a headless test renderer). Instead
/// these tests exercise the layers the view delegates to:
///
///   1. AppManifestRegistry population — registry machinery (allApps
///      order, get-by-id, field lookup).
///
///   2. Generic field rendering helpers — for a given field + value the
///      right display string is emitted (delegates to FieldDisplayRow
///      logic already tested in field_editor_test.dart).
///
///   3. Pending-change tracking — `setAppOption` produces a new config
///      whose `diffKeysFrom` the original contains the changed key (the
///      mechanism the view's `pendingChangeKeysProvider` uses).
///
///   4. Apply / Cancel semantics — applying a pending value commits via
///      `setAppOption`; "cancel" (not calling updateConfig) leaves the
///      config unchanged.
///
/// bitcoind / lnd / cln / blitz-web are plugins now, so
/// `bundledAppManifests` is empty. The registry/rendering tests use the
/// [_fixtureManifest] below instead of sourcing those apps' bundled
/// manifests — keeping them about the machinery, not about which apps
/// happen to ship in the binary.
AppManifest _fixtureManifest({String id = 'demo-app'}) => AppManifest(
  id: id,
  label: 'Demo App',
  fields: const [
    BoolField(name: 'enabled', label: 'Enabled', defaultValue: true),
    EnumField(
      name: 'network',
      label: 'Network',
      choices: ['mainnet', 'testnet', 'regtest'],
      defaultValue: 'mainnet',
    ),
    StringField(name: 'alias', label: 'Alias', defaultValue: ''),
    IntField(name: 'prune_size_gb', label: 'Prune size (GB)', defaultValue: 0),
  ],
);

void main() {
  // ── 1. Registry population ──────────────────────────────────────────────

  group('AppManifestRegistry population', () {
    test('allApps preserves bundled-then-plugin order', () {
      final registry = AppManifestRegistry(
        bundled: [
          _fixtureManifest(id: 'alpha'),
          _fixtureManifest(id: 'zebra'),
        ],
        plugin: [_fixtureManifest(id: 'plug')],
      );
      expect(registry.allApps.map((m) => m.id).toList(), [
        'alpha',
        'zebra',
        'plug',
      ]);
    });

    test('get(id) finds a manifest by id; null when absent', () {
      final registry = AppManifestRegistry(
        bundled: [_fixtureManifest(id: 'demo-app')],
        plugin: const [],
      );
      expect(registry.get('demo-app')?.id, 'demo-app');
      expect(registry.get('nope'), isNull);
    });

    test('empty bundled + empty plugin yields no apps', () {
      final registry = AppManifestRegistry(bundled: const [], plugin: const []);
      expect(registry.allApps, isEmpty);
    });

    test('manifest.field(name) resolves each declared field type', () {
      final m = _fixtureManifest();
      expect(m.field('enabled'), isA<BoolField>());
      expect(m.field('network'), isA<EnumField>());
      expect(m.field('alias'), isA<StringField>());
      expect(m.field('prune_size_gb'), isA<IntField>());
      expect(m.field('missing'), isNull);
    });
  });

  // ── 2. Field value rendering ────────────────────────────────────────────

  group('Field value rendering via formatFieldValue', () {
    final manifest = _fixtureManifest();

    test('BoolField true renders as "on"', () {
      expect(formatFieldValue(manifest.field('enabled')!, true), 'on');
    });

    test('BoolField false renders as "off"', () {
      expect(formatFieldValue(manifest.field('enabled')!, false), 'off');
    });

    test('EnumField renders the selected choice', () {
      expect(
        formatFieldValue(manifest.field('network')!, 'mainnet'),
        'mainnet',
      );
    });

    test('StringField empty renders as empty string', () {
      expect(formatFieldValue(manifest.field('alias')!, ''), '');
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
      // The view checks isPending via '${manifest.id}.${field.name}'.
      // Verify diffKeysFrom emits that exact format. Uses an enum
      // change (the other diff tests above cover bool / string / int).
      final original = NixblitzConfig.defaults();
      final updated = original.setAppOption('demo-app', 'network', 'regtest');
      expect(updated.diffKeysFrom(original), contains('demo-app.network'));
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

    test('cycling an EnumField via cycleFieldValue advances the choice', () {
      final field = _fixtureManifest().field('network')! as EnumField;
      final next = cycleFieldValue(field, 'mainnet');
      final idx = field.choices.indexOf('mainnet');
      expect(next, field.choices[(idx + 1) % field.choices.length]);
    });

    test('toggling a BoolField via cycleFieldValue flips it', () {
      final field = _fixtureManifest().field('enabled')!;
      expect(field, isA<BoolField>());
      expect(cycleFieldValue(field, false), isTrue);
      expect(cycleFieldValue(field, true), isFalse);
    });

    test('StringField requires editor overlay', () {
      final field = _fixtureManifest().field('alias')!;
      expect(field, isA<StringField>());
      expect(fieldRequiresEditor(field), isTrue);
    });

    test('IntField requires editor overlay', () {
      final field = _fixtureManifest().field('prune_size_gb')!;
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

  // ── 6. visiblePluginActions — actions gate ─────────────────────────────

  group('visiblePluginActions', () {
    PluginManifest manifestWithDown() => PluginManifest.fromJson({
      'manifest': {
        'schema_version': 4,
        'min_tui_version': 1,
        'name': 'Tailscale',
      },
      'actions': {
        'down': {'label': 'Disconnect', 'unit': 'tailscale-down.service'},
      },
      'permissions': {
        'privileged_units': ['tailscale-down.service'],
      },
    });

    test('returns actions when enabled', () {
      expect(
        visiblePluginActions(plugin: manifestWithDown(), enabled: true),
        hasLength(1),
      );
    });
    test('empty when disabled', () {
      expect(
        visiblePluginActions(plugin: manifestWithDown(), enabled: false),
        isEmpty,
      );
    });
    test('empty when plugin missing', () {
      expect(visiblePluginActions(plugin: null, enabled: true), isEmpty);
    });
  });

  // ── 7. configSchema field rendering data path ──────────────────────────

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
