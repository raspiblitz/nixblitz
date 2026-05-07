// common/lib/src/providers/dashboard_provider.dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:common/src/providers/plugin_dep_check_provider.dart';
import 'package:common/src/services/dashboard/bundled/registry.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/sources/streamer_subprocess_source.dart';
import 'package:common/src/services/dashboard/tile_data_cache.dart';
import 'package:common/src/services/dashboard/tile_event_source_registry.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_dep_check.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

/// Holds 0..N TileEventSource instances. Always registers `system-stats`
/// (procfs/sysfs reader, no plugin dep). Plugin streamers are registered
/// for each enabled, dep-satisfied installed plugin — one
/// [StreamerSubprocessSource] per declared `streamers` entry.
final tileSourceRegistryProvider = Provider<TileEventSourceRegistry>((ref) {
  final reg = TileEventSourceRegistry();
  final baseDir = ref.watch(baseDirProvider);
  final pluginsRoot = '$baseDir/plugins';

  // system-stats: always on. Reads procfs/sysfs; no plugin dep.
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

  // Plugin streamers — only for enabled plugins with satisfied deps.
  // Skip plugins whose marker is missing (defensive: should not happen
  // since installedPluginsProvider already required a marker), or whose
  // marker is `disabled: true`. Skip plugins whose dep-check returned
  // [DepMissing] — their streamers can't be relied on without the
  // upstream service.
  final plugins = ref.watch(installedPluginsProvider);
  final depStatuses = ref.watch(pluginDepCheckProvider);
  for (final plugin in plugins) {
    final status = depStatuses[plugin.id];
    if (status is DepMissing) {
      LogService.warn(
        'plugin ${plugin.id}: skipping streamer registration — deps missing',
      );
      continue;
    }
    final marker = readMarker('$pluginsRoot/${plugin.id}');
    if (marker == null || marker.disabled) continue;

    for (final spec in plugin.streamers) {
      reg.register(
        StreamerSubprocessSource(
          id: '${plugin.id}/${spec.name}',
          providedTileIds: spec.tileIds,
          command: spec.command,
          args: spec.args,
          // Resolve the streamer's argv relative to the plugin's
          // checkout, so e.g. `streamers/blitz_api_stream.py` works
          // from a working directory of `<pluginsRoot>/<plugin.id>/`.
          workingDirectory: '$pluginsRoot/${plugin.id}',
        ),
      );
    }
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
        (event) {
          if (src.providedTileIds.contains(event.tileId)) {
            cache.apply(event);
          } else {
            LogService.warn(
              'source ${src.id} emitted event for unauthorized tile '
              '"${event.tileId}" (declared: ${src.providedTileIds.join(", ")}); '
              'dropped',
            );
          }
        },
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
