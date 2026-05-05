import 'package:common/src/services/dashboard/tile_event.dart';

/// Single contract every dashboard data source implements. Sources emit
/// [TileEvent]s into a broadcast stream; the [TileEventSourceRegistry]
/// manages their lifecycle (start/dispose) and the [TileDataCache]
/// merges their events into per-tile snapshots.
abstract class TileEventSource {
  /// Stable identifier used in logs + the "no data — `<id>` not running"
  /// footer surfacing.
  String get id;

  /// Tile ids this source advertises. Advisory: the cache still accepts
  /// events for tile ids outside this set (forward-compat for plugins
  /// that ship their own tiles).
  Set<String> get providedTileIds;

  /// Begin emitting. Idempotent.
  Future<void> start();

  /// Broadcast stream of events. Errors propagate via [Stream.addError].
  Stream<TileEvent> get events;

  Future<void> dispose();
}
