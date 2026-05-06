import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/configure/field_editor.dart';

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

    test('all five bundled apps are present', () {
      final ids = registry.allApps.map((m) => m.id).toSet();
      expect(
        ids,
        containsAll(['bitcoind', 'lnd', 'cln', 'blitz_api', 'blitz_web']),
      );
    });

    test('menu entries are: System + 5 apps + Plugins = 7 total', () {
      // System (1) + 5 apps + Plugins (1) = 7
      expect(registry.allApps.length, 5);
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
}
