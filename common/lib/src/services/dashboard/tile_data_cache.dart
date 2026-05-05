import 'dart:async';

import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';

class TileDataCache {
  final Map<String, TileSnapshot> _snapshots = {};
  final Map<String, StreamController<TileSnapshot>> _controllers = {};

  TileSnapshot snapshotFor(String tileId) =>
      _snapshots[tileId] ?? const TileSnapshot();

  Stream<TileSnapshot> streamFor(String tileId) {
    final c = _controllers.putIfAbsent(
      tileId,
      () => StreamController<TileSnapshot>.broadcast(),
    );
    return c.stream;
  }

  void apply(TileEvent ev) {
    final prev = _snapshots[ev.tileId] ?? const TileSnapshot();
    final next = prev.copyWith(
      data: {...prev.data, ...ev.data},
      lastEventTs: ev.ts,
      clearError: true,
    );
    _snapshots[ev.tileId] = next;
    _controllers[ev.tileId]?.add(next);
  }

  void applyError(String tileId, Object e) {
    final prev = _snapshots[tileId] ?? const TileSnapshot();
    final next = prev.copyWith(lastError: e);
    _snapshots[tileId] = next;
    _controllers[tileId]?.add(next);
  }

  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
    _snapshots.clear();
  }
}
