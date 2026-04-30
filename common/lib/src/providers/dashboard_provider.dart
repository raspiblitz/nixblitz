import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/dashboard/snapshots.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/dashboard/api_dashboard_source.dart';
import 'package:common/src/services/dashboard/dashboard_data_source.dart';

/// Persists the four dashboard snapshots across
/// `dashboardDataSourceProvider` recreates. Without this cache,
/// every config change (operator edits, FS-watcher pickup,
/// post-rebuild config writeback) tears down the SSE source and
/// rebuilds from scratch — flipping all four tiles back to
/// "loading" until SSE reconnects.
///
/// Cache lives for the ProviderScope's lifetime (i.e. the whole
/// TUI session). Re-creates seed from it; live snapshot updates
/// flow into it via subscriptions on the active source's streams
/// (set up below).
class _SnapshotCache {
  SystemSnapshot? system;
  HardwareSnapshot? hardware;
  BtcSnapshot? bitcoin;
  LnSnapshot? lightning;
}

final _snapshotCacheProvider = Provider<_SnapshotCache>(
  (_) => _SnapshotCache(),
);

/// Picks the right data source for the current config. Blitz-api
/// enabled → SSE-driven source seeded from the persistent cache
/// (so a config-change-driven recreate doesn't blank the tiles).
/// Otherwise a null source (tiles say "unavailable"); a future
/// CLI-polling source will slot in here.
final dashboardDataSourceProvider = Provider<DashboardDataSource>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final cache = ref.read(_snapshotCacheProvider);

  final apiEnabled = config?.blitzApi.enabled ?? false;
  if (!apiEnabled) {
    final ds = NullDashboardSource();
    ref.onDispose(() async => ds.dispose());
    return ds;
  }

  // System seed combines two sources: the canonical hostname /
  // platform / network from config (always derivable, even on
  // first launch), and any prior services-map / uptime captured
  // by the cache. Prefer the cache version when we have one
  // because it carries richer state; fall back to the freshly
  // computed config-only seed on cold start.
  final freshSystemSeed = config == null
      ? null
      : SystemSnapshot(
          hostname: config.system.hostname,
          platform: config.system.platform,
          network: config.bitcoind.network,
          uptime: Duration.zero,
          services: <String, ServiceState>{
            'blitz-api': ServiceState.unknown,
            'blitz-web': ServiceState.unknown,
            'nginx': ServiceState.unknown,
            'redis': ServiceState.unknown,
          },
        );

  final ds = ApiDashboardSource(
    seedSystem: cache.system ?? freshSystemSeed,
    seedHardware: cache.hardware,
    seedBitcoin: cache.bitcoin,
    seedLightning: cache.lightning,
  );

  // Tap the source's broadcast streams to keep the cache fresh
  // for the NEXT recreate. Subscriptions ride the same lifetime
  // as the source — torn down together in onDispose below. Ignore
  // null emissions (the NullDashboardSource shape isn't used
  // here, but defensively the dashboard expects null = unknown).
  final subs = <StreamSubscription>[
    ds.system.listen((s) {
      if (s != null) cache.system = s;
    }),
    ds.hardware.listen((s) {
      if (s != null) cache.hardware = s;
    }),
    ds.bitcoin.listen((s) {
      if (s != null) cache.bitcoin = s;
    }),
    ds.lightning.listen((s) {
      if (s != null) cache.lightning = s;
    }),
  ];

  ref.onDispose(() async {
    for (final s in subs) {
      await s.cancel();
    }
    await ds.dispose();
  });

  return ds;
});

/// Merge the source's current seed value into the stream so a late
/// subscriber (e.g. user navigating back to the dashboard) sees the
/// last-known snapshot immediately, not "loading".
Stream<T?> _withSeed<T>(T? seed, Stream<T?> stream) async* {
  if (seed != null) yield seed;
  yield* stream;
}

/// Per-stream providers so tiles watch one thing each.
final systemSnapshotProvider = StreamProvider<SystemSnapshot?>((ref) {
  final ds = ref.watch(dashboardDataSourceProvider);
  return _withSeed(ds.seedSystem, ds.system);
});

final hardwareSnapshotProvider = StreamProvider<HardwareSnapshot?>((ref) {
  final ds = ref.watch(dashboardDataSourceProvider);
  return _withSeed(ds.seedHardware, ds.hardware);
});

final btcSnapshotProvider = StreamProvider<BtcSnapshot?>((ref) {
  final ds = ref.watch(dashboardDataSourceProvider);
  return _withSeed(ds.seedBitcoin, ds.bitcoin);
});

final lnSnapshotProvider = StreamProvider<LnSnapshot?>((ref) {
  final ds = ref.watch(dashboardDataSourceProvider);
  return _withSeed(ds.seedLightning, ds.lightning);
});
