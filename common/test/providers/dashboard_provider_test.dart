import 'dart:async';

import 'package:common/src/providers/dashboard_provider.dart';
import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/dashboard/tile_event_source_registry.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _FakeSource extends InProcessAdapterSource {
  _FakeSource({required Set<String> tileIds})
    : super(id: 'fake', providedTileIds: tileIds);

  void pump(TileEvent e) => emit(e);
}

void main() {
  group('tileDataCacheProvider tile_ids enforcement', () {
    test('events for declared tiles flow through to cache', () async {
      final fake = _FakeSource(tileIds: {'foo'});
      final reg = TileEventSourceRegistry()..register(fake);

      final container = ProviderContainer(
        overrides: [tileSourceRegistryProvider.overrideWithValue(reg)],
      );
      addTearDown(container.dispose);

      final cache = container.read(tileDataCacheProvider);
      fake.pump(
        TileEvent(
          tileId: 'foo',
          data: const {'x': 1},
          ts: DateTime.utc(2026, 5, 6),
        ),
      );
      // Allow stream to flush.
      await Future<void>.delayed(Duration.zero);

      final snap = cache.snapshotFor('foo');
      expect(snap.data, {'x': 1});
    });

    test('events for undeclared tiles are dropped', () async {
      final fake = _FakeSource(tileIds: {'foo'});
      final reg = TileEventSourceRegistry()..register(fake);

      final container = ProviderContainer(
        overrides: [tileSourceRegistryProvider.overrideWithValue(reg)],
      );
      addTearDown(container.dispose);

      final cache = container.read(tileDataCacheProvider);
      // Source declared {'foo'} but emits 'bar':
      fake.pump(
        TileEvent(
          tileId: 'bar',
          data: const {'evil': 1},
          ts: DateTime.utc(2026, 5, 6),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final snap = cache.snapshotFor('bar');
      // TileSnapshot.data is non-nullable (defaults to const {}). The
      // contract under test is "the unauthorized event was NOT applied",
      // which we assert via the empty-snapshot predicate.
      expect(
        snap.isEmpty,
        isTrue,
        reason: 'unauthorized tile event must be dropped',
      );
      expect(snap.data, isEmpty);
      expect(snap.lastEventTs, isNull);
    });

    test(
      'events for declared and undeclared tiles are sorted correctly',
      () async {
        final fake = _FakeSource(tileIds: {'foo'});
        final reg = TileEventSourceRegistry()..register(fake);

        final container = ProviderContainer(
          overrides: [tileSourceRegistryProvider.overrideWithValue(reg)],
        );
        addTearDown(container.dispose);

        final cache = container.read(tileDataCacheProvider);
        // Pump one of each.
        fake.pump(
          TileEvent(
            tileId: 'foo',
            data: const {'allowed': true},
            ts: DateTime.utc(2026, 5, 6),
          ),
        );
        fake.pump(
          TileEvent(
            tileId: 'bar',
            data: const {'evil': 1},
            ts: DateTime.utc(2026, 5, 6),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(cache.snapshotFor('foo').data, {'allowed': true});
        expect(cache.snapshotFor('bar').isEmpty, isTrue);
        expect(cache.snapshotFor('bar').data, isEmpty);
      },
    );
  });
}
