import 'dart:async';
import 'dart:convert';

import 'package:common/src/services/blitz_api/sse_event.dart';
import 'package:common/src/services/dashboard/sources/blitz_api_bridge_source.dart';
import 'package:test/test.dart';

void main() {
  group('BlitzApiBridgeSource', () {
    test('btc_info SSE event → bitcoin TileEvent', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      addTearDown(clientEvents.close);
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      addTearDown(s.dispose);
      await s.start();
      final got = <Map<String, dynamic>>[];
      s.events.listen((ev) => got.add({'tile': ev.tileId, 'data': ev.data}));

      clientEvents.add(
        SseEvent(
          event: 'btc_info',
          data: jsonEncode({'blocks': 100, 'verification_progress': 0.99}),
        ),
      );
      await Future.delayed(Duration.zero);

      expect(got.length, 1);
      expect(got.first['tile'], 'bitcoin');
      expect((got.first['data'] as Map)['blocks'], 100);
    });

    test('btc_mempool_status SSE event → bitcoin TileEvent', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      addTearDown(clientEvents.close);
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      addTearDown(s.dispose);
      await s.start();
      final got = <String>[];
      s.events.listen((ev) => got.add(ev.tileId));

      clientEvents.add(
        SseEvent(
          event: 'btc_mempool_status',
          data: jsonEncode({'count': 1234}),
        ),
      );
      await Future.delayed(Duration.zero);

      expect(got, ['bitcoin']);
    });

    test('ln_info SSE event → lightning TileEvent', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      addTearDown(clientEvents.close);
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      addTearDown(s.dispose);
      await s.start();
      final got = <String>[];
      s.events.listen((ev) => got.add(ev.tileId));

      clientEvents.add(
        SseEvent(
          event: 'ln_info',
          data: jsonEncode({'identity_pubkey': 'abc', 'alias': 'node'}),
        ),
      );
      await Future.delayed(Duration.zero);

      expect(got, ['lightning']);
    });

    test('wallet_balance SSE event → lightning TileEvent', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      addTearDown(clientEvents.close);
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      addTearDown(s.dispose);
      await s.start();
      final got = <String>[];
      s.events.listen((ev) => got.add(ev.tileId));

      clientEvents.add(
        SseEvent(event: 'wallet_balance', data: jsonEncode({'onchain': 1000})),
      );
      await Future.delayed(Duration.zero);

      expect(got, ['lightning']);
    });

    test('client error propagates as stream error', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      addTearDown(clientEvents.close);
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      addTearDown(s.dispose);
      await s.start();
      Object? err;
      s.events.listen(
        (_) {},
        onError: (e) {
          err = e;
        },
      );
      clientEvents.addError('boom');
      await Future.delayed(Duration.zero);
      expect(err, 'boom');
    });

    test('unhandled SSE event types are silently ignored', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      addTearDown(clientEvents.close);
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      addTearDown(s.dispose);
      await s.start();
      final got = <String>[];
      s.events.listen((ev) => got.add(ev.tileId));

      clientEvents.add(SseEvent(event: 'random_other_event', data: '{}'));
      await Future.delayed(Duration.zero);

      expect(got, isEmpty);
    });

    test('malformed JSON in SSE data is dropped, no event emitted', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      addTearDown(clientEvents.close);
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      addTearDown(s.dispose);
      await s.start();
      final got = <String>[];
      s.events.listen((ev) => got.add(ev.tileId));

      clientEvents.add(SseEvent(event: 'btc_info', data: 'not-json{{{'));
      await Future.delayed(Duration.zero);

      expect(got, isEmpty);
    });
  });
}
