import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/dashboard/snapshots.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/dashboard/api_dashboard_source.dart';
import 'package:common/src/services/dashboard/dashboard_data_source.dart';

/// Picks the right data source for the current config. Blitz-api
/// enabled → SSE-driven source. Otherwise a null source (tiles say
/// "unavailable"); a future CLI-polling source will slot in here.
final dashboardDataSourceProvider = Provider<DashboardDataSource>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;

  final apiEnabled = config?.blitzApi.enabled ?? false;
  if (!apiEnabled) {
    final ds = NullDashboardSource();
    ref.onDispose(() async => ds.dispose());
    return ds;
  }

  final seed = config == null
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

  final ds = ApiDashboardSource(seedSystem: seed);
  ref.onDispose(() async => ds.dispose());
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
