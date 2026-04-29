import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/plugin/plugin_tile.dart';
import 'package:common/src/services/plugin_dashboard_service.dart';

final pluginDashboardServiceProvider = Provider<PluginDashboardService>((ref) {
  final svc = PluginDashboardService(ref);
  ref.onDispose(svc.dispose);
  return svc;
});

/// Late subscribers see the service's current snapshot map without
/// waiting for the next poll tick. Mirrors the `_withSeed` helper in
/// `dashboard_provider.dart`.
Stream<Map<String, PluginTileSnapshot?>> _withSeed(
  Map<String, PluginTileSnapshot?> seed,
  Stream<Map<String, PluginTileSnapshot?>> stream,
) async* {
  yield seed;
  yield* stream;
}

final pluginTileSnapshotsProvider =
    StreamProvider<Map<String, PluginTileSnapshot?>>((ref) {
      final svc = ref.watch(pluginDashboardServiceProvider);
      return _withSeed(svc.seed, svc.snapshots);
    });
