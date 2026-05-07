import 'dart:async';

import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/dashboard/tile_event_source.dart';
import 'package:meta/meta.dart';

/// Base class for tile event sources implemented entirely in-process
/// (no subprocess). Phase 1 used this for the in-tree
/// `BlitzApiBridgeSource`; Phase 4 retired that path (blitz-api is
/// now a plugin shipping a Python subprocess streamer). The class
/// stays as a useful base for test fakes — see e.g. the
/// `_FakeSource` in `dashboard_provider_test.dart`.
abstract class InProcessAdapterSource implements TileEventSource {
  @override
  final String id;
  @override
  final Set<String> providedTileIds;

  final StreamController<TileEvent> _ctrl =
      StreamController<TileEvent>.broadcast();
  @visibleForTesting
  bool started = false;
  @visibleForTesting
  int startedCount = 0;
  @visibleForTesting
  bool disposed = false;

  InProcessAdapterSource({required this.id, required this.providedTileIds});

  @override
  Stream<TileEvent> get events => _ctrl.stream;

  @override
  Future<void> start() async {
    if (started) return;
    started = true;
    startedCount++;
    await onStart();
  }

  /// Subclass hook. Override to wire up the underlying source. Default no-op.
  Future<void> onStart() async {}

  /// Subclass hook for emitting events. Silently dropped if disposed.
  void emit(TileEvent ev) {
    if (!_ctrl.isClosed) _ctrl.add(ev);
  }

  /// Subclass hook for emitting errors. Silently dropped if disposed.
  void emitError(Object e, [StackTrace? st]) {
    if (!_ctrl.isClosed) _ctrl.addError(e, st);
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await onDispose();
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  /// Subclass hook for tearing down (cancel subscriptions, etc.). Default no-op.
  Future<void> onDispose() async {}
}
