import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/plugin/plugin_tile.dart';
import 'package:common/src/services/plugin_dashboard_service.dart';

final pluginDashboardServiceProvider = Provider<PluginDashboardService>((ref) {
  final pluginDashboardService = PluginDashboardService(ref);
  ref.onDispose(pluginDashboardService.dispose);
  return pluginDashboardService;
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
      final pluginDashboardService = ref.watch(pluginDashboardServiceProvider);
      return _withSeed(
        pluginDashboardService.seed,
        pluginDashboardService.snapshots,
      );
    });
