import 'package:common/src/services/dashboard/tile_event_source.dart';
import 'package:common/src/services/log_service.dart';

class TileEventSourceRegistry {
  final List<TileEventSource> _sources = [];
  final Set<String> _ids = {};
  bool _started = false;

  Iterable<TileEventSource> get sources => List.unmodifiable(_sources);

  /// Register a source. Throws [StateError] on duplicate [TileEventSource.id].
  ///
  /// Sources registered after [startAll] has been called will NOT be
  /// auto-started; call [TileEventSource.start] on them directly. The
  /// current usage pattern (register all sources first, then `startAll`
  /// once) avoids this entirely.
  void register(TileEventSource source) {
    if (!_ids.add(source.id)) {
      throw StateError('Duplicate TileEventSource id: ${source.id}');
    }
    _sources.add(source);
    LogService.info(
      'TileEventSource registered: ${source.id} '
      '(tiles: ${source.providedTileIds.join(", ")})',
    );
  }

  Future<void> startAll() async {
    if (_started) return;
    _started = true;
    for (final s in _sources) {
      await s.start();
    }
  }

  Future<void> disposeAll() async {
    for (final s in _sources) {
      try {
        await s.dispose();
      } catch (e, st) {
        LogService.warn('TileEventSource ${s.id} dispose error: $e\n$st');
      }
    }
    _sources.clear();
    _ids.clear();
    _started = false;
  }
}
