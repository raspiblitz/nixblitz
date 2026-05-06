// common/lib/src/providers/dashboard_provider.dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/dashboard/bundled/registry.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/sources/blitz_api_bridge_source.dart';
import 'package:common/src/services/dashboard/sources/streamer_subprocess_source.dart';
import 'package:common/src/services/dashboard/tile_data_cache.dart';
import 'package:common/src/services/dashboard/tile_event_source_registry.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';

/// Holds 0..N TileEventSource instances. Phase 1: always registers
/// `system-stats` (procfs/sysfs reader, no blitz-api dep). When
/// `config.isAppEnabled('blitz_api')`, also registers blitz-api-bridge.
/// Phase 4 will swap the bridge gate for "is the blitz-api plugin
/// installed."
final tileSourceRegistryProvider = Provider<TileEventSourceRegistry>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final reg = TileEventSourceRegistry();

  // system-stats: always on. Reads procfs/sysfs; no blitz-api dep.
  // The Phase-1 unit list is hardcoded here; Phase 2/3 will pull it
  // from system.json's streamer_args once NixblitzConfig is generalized.
  reg.register(
    StreamerSubprocessSource(
      id: 'system-stats',
      providedTileIds: const {'hardware', 'system'},
      command: Platform.resolvedExecutable,
      args: const [
        'streamer',
        'system-stats',
        '--units',
        'blitz-api,blitz-web,nginx,redis',
      ],
    ),
  );

  if (config != null && config.isAppEnabled('blitz_api')) {
    reg.register(BlitzApiBridgeSource());
  }

  unawaited(reg.startAll());
  ref.onDispose(reg.disposeAll);
  return reg;
});

/// Aggregates events from all registered sources into per-tile snapshots.
final tileDataCacheProvider = Provider<TileDataCache>((ref) {
  final reg = ref.watch(tileSourceRegistryProvider);
  final cache = TileDataCache();
  final subs = <StreamSubscription>[];
  for (final src in reg.sources) {
    subs.add(
      src.events.listen(
        cache.apply,
        onError: (e, st) {
          for (final tid in src.providedTileIds) {
            cache.applyError(tid, e);
          }
        },
      ),
    );
  }
  ref.onDispose(() async {
    for (final s in subs) {
      await s.cancel();
    }
    await cache.dispose();
  });
  return cache;
});

/// The four bundled tile manifests, parsed at startup.
final tileManifestsProvider = Provider<List<TileManifest>>(
  (ref) => bundledManifests,
);

/// Per-tile snapshot stream the renderer subscribes to. Seeded with the
/// current cache value so a late subscriber sees data immediately.
final tileSnapshotProvider = StreamProvider.family<TileSnapshot, String>((
  ref,
  tileId,
) {
  final cache = ref.watch(tileDataCacheProvider);
  return Stream<TileSnapshot>.multi((controller) async {
    controller.add(cache.snapshotFor(tileId));
    final sub = cache
        .streamFor(tileId)
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
    controller.onCancel = sub.cancel;
  });
});
