import 'dart:async';
import 'dart:convert';

import 'package:common/src/services/blitz_api/blitz_api_client.dart';
import 'package:common/src/services/blitz_api/sse_event.dart';
import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/log_service.dart';

/// In-process adapter that wraps [BlitzApiClient] and translates SSE
/// events into [TileEvent]s for the bitcoin + lightning tiles.
///
/// Phase 1 transitional. In Phase 4 the same translation logic ships
/// inside the blitz-api plugin's subprocess streamer, this class is
/// deleted, and [InProcessAdapterSource] goes away with it.
class BlitzApiBridgeSource extends InProcessAdapterSource {
  /// Held only on the production code path so resource ownership is
  /// explicit. Null in the [forTest] path. The class delegates to
  /// the client's lifecycle methods regardless of which path
  /// constructed the instance.
  // ignore: unused_field
  final BlitzApiClient? _client;

  final Stream<SseEvent> _eventsStream;
  final Future<void> Function() _onStart;
  final Future<void> Function() _onDispose;
  StreamSubscription<SseEvent>? _sub;

  /// Production constructor: wraps a fresh [BlitzApiClient].
  BlitzApiBridgeSource() : this._withClient(BlitzApiClient());

  BlitzApiBridgeSource._withClient(BlitzApiClient client)
    : _client = client,
      _eventsStream = client.events,
      _onStart = client.start,
      _onDispose = client.dispose,
      super(
        id: 'blitz-api-bridge',
        providedTileIds: const {'bitcoin', 'lightning'},
      );

  /// Test seam: inject a stream + lifecycle hooks without spinning up
  /// a real BlitzApiClient.
  factory BlitzApiBridgeSource.forTest({
    required Stream<SseEvent> eventsStream,
    required Future<void> Function() startCallback,
    required Future<void> Function() disposeCallback,
  }) {
    return BlitzApiBridgeSource._forTest(
      eventsStream: eventsStream,
      onStart: startCallback,
      onDispose: disposeCallback,
    );
  }

  BlitzApiBridgeSource._forTest({
    required Stream<SseEvent> eventsStream,
    required Future<void> Function() onStart,
    required Future<void> Function() onDispose,
  }) : _client = null,
       _eventsStream = eventsStream,
       _onStart = onStart,
       _onDispose = onDispose,
       super(
         id: 'blitz-api-bridge',
         providedTileIds: const {'bitcoin', 'lightning'},
       );

  @override
  Future<void> onStart() async {
    await _onStart();
    _sub = _eventsStream.listen(_handleSse, onError: emitError);
  }

  void _handleSse(SseEvent e) {
    late Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(e.data) as Map<String, dynamic>;
    } catch (err) {
      // Malformed JSON from the API — log and drop.
      LogService.warn(
        'blitz-api-bridge: malformed SSE data dropped (event=${e.event}): $err',
      );
      return;
    }

    switch (e.event) {
      case 'btc_info':
      case 'btc_mempool_status':
        emit(TileEvent(tileId: 'bitcoin', data: decoded, ts: DateTime.now()));
        break;
      case 'ln_info':
      case 'wallet_balance':
        emit(TileEvent(tileId: 'lightning', data: decoded, ts: DateTime.now()));
        break;
      // Other event types are ignored — Phase 1 only routes the four
      // the current tiles consumed.
    }
  }

  @override
  Future<void> onDispose() async {
    await _sub?.cancel();
    _sub = null;
    await _onDispose();
  }
}
