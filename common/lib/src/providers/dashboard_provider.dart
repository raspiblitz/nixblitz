// common/lib/src/providers/dashboard_provider.dart
import 'dart:async';
import 'dart:io';

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
  // upstream service. Skip plugins whose own `app_configs[id].enabled`
  // is false — the operator's per-plugin toggle. Without this gate the
  // streamer would loop trying to talk to a service that NixOS hasn't
  // started.
  final plugins = ref.watch(installedPluginsProvider);
  final depStatuses = ref.watch(pluginDepCheckProvider);
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
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
    // Operator's per-plugin enabled toggle. If config hasn't loaded
    // yet (early boot), conservatively skip — the provider will
    // re-run once config is ready.
    if (config == null || !config.isAppEnabled(plugin.id)) {
      LogService.info(
        'plugin ${plugin.id}: skipping streamer registration — '
        'app_configs[${plugin.id}].enabled is false',
      );
      continue;
    }

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

/// Bundled manifests + every enabled plugin's declared `tile_manifests`.
/// Paths are resolved relative to `<baseDir>/plugins/<id>/`. A plugin
/// whose manifest declares `tile_manifests` but whose `app_configs[id]
/// .enabled` is false contributes nothing — same `app_configs[id]
/// .enabled` gating as streamers (no marker / dep-check filtering).
///
/// Per-plugin manifests are filtered: parse failures and missing files
/// log a warning and skip rather than blowing up the dashboard. The
/// final list is sorted by tile id for stable order across rebuilds.
final tileManifestsProvider = Provider<List<TileManifest>>((ref) {
  final base = ref.watch(baseDirProvider);
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final plugins = ref.watch(installedPluginsProvider);

  final out = <TileManifest>[...bundledManifests];

  for (final plugin in plugins) {
    if (plugin.tileManifests.isEmpty) continue;
    if (config == null || !config.isAppEnabled(plugin.id)) continue;

    for (final relPath in plugin.tileManifests) {
      final path = '$base/plugins/${plugin.id}/$relPath';
      try {
        final content = File(path).readAsStringSync();
        out.add(TileManifest.fromJsonString(content));
      } catch (e, st) {
        LogService.warn(
          'plugin ${plugin.id}: failed to load tile manifest $relPath: $e',
        );
        LogService.error('plugin tile manifest load trace', e, st);
      }
    }
  }

  out.sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(out);
});

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
