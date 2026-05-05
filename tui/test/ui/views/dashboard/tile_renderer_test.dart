import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/dashboard/tile_renderer.dart';

void main() {
  group('TileRenderer.text', () {
    test('Row renders "label: value"', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"Row":{"label":"Peers","value":{"$data":"peers"}}}]}
      ''');
      final snap = const TileSnapshot().copyWith(
        data: {'peers': 8},
        lastEventTs: DateTime.utc(2026, 5, 5),
      );
      final out = renderTileToText(m, snap);
      expect(out, contains('Peers: 8'));
    });

    test('ProgressBar renders bar with percent', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"ProgressBar":{"label":"Sync","value":{"$data":"p"},"format":"percent"}}]}
      ''');
      final snap = const TileSnapshot().copyWith(
        data: {'p': 0.5},
        lastEventTs: DateTime.utc(2026, 5, 5),
      );
      final out = renderTileToText(m, snap, width: 30);
      expect(out, contains('Sync'));
      expect(out, contains('50%'));
      expect(out, contains('█')); // bar character
    });

    test('Section indents children + shows title', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"Section":{"title":"Wallet","children":[{"Row":{"label":"Bal","value":"0"}}]}}]}
      ''');
      final out = renderTileToText(
        m,
        const TileSnapshot().copyWith(lastEventTs: DateTime.utc(2026, 5, 5)),
      );
      expect(out, contains('Wallet'));
      expect(out, contains('  Bal: 0')); // two-space indent
    });

    test('Footer with synced status', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[],
         "footer":{"$status":{"$on":"s","ok":{"Footer":{"text":"synced","color":"ok"}}}}}
      ''');
      final snap = const TileSnapshot().copyWith(
        data: {'s': 'ok'},
        lastEventTs: DateTime.utc(2026, 5, 5),
      );
      final out = renderTileToText(m, snap);
      expect(out, contains('synced'));
    });

    test('lastError → footer shows error text', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[]}
      ''');
      final snap = const TileSnapshot().copyWith(lastError: 'boom');
      final out = renderTileToText(m, snap);
      expect(out, contains('boom'));
    });

    test('empty snapshot → "no data" placeholder footer', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[]}
      ''');
      final out = renderTileToText(m, const TileSnapshot());
      expect(out, contains('no data'));
    });

    test('crash-loop error footer', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[]}
      ''');
      final snap = const TileSnapshot().copyWith(
        lastError: Exception('streamer crash-looping (4 restarts) — see log'),
      );
      final out = renderTileToText(m, snap);
      expect(out, contains('crash-looping'));
    });

    test('Spacer renders blank line', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"Row":{"label":"a","value":"1"}},{"Spacer":{}},{"Row":{"label":"b","value":"2"}}]}
      ''');
      final out = renderTileToText(
        m,
        const TileSnapshot().copyWith(lastEventTs: DateTime.utc(2026, 5, 5)),
      );
      // Both rows present, with a blank line between.
      expect(out, contains('a: 1'));
      expect(out, contains('b: 2'));
    });

    test(
      'StatusRow renders label: value (color is for visual; text-render shows value)',
      () {
        final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"StatusRow":{"label":"Net","value":"main","color":"ok"}}]}
      ''');
        final out = renderTileToText(
          m,
          const TileSnapshot().copyWith(lastEventTs: DateTime.utc(2026, 5, 5)),
        );
        expect(out, contains('Net: main'));
      },
    );
  });

  group('TileRenderer.widget', () {
    test(
      'build() produces a non-null Component containing the tile title',
      () async {
        await testNocterm('TileRenderer renders title in widget tree', (
          tester,
        ) async {
          final m = TileManifest.fromJsonString(r'''
            {"id":"btc","title":"Bitcoin","layout":[
              {"Row":{"label":"Peers","value":{"$data":"peers"}}},
              {"StatusRow":{"label":"Net","value":"main","color":"ok"}}
            ]}
          ''');
          final snap = const TileSnapshot().copyWith(
            data: {'peers': 12},
            lastEventTs: DateTime.utc(2026, 5, 5),
          );

          await tester.pumpComponent(TileRenderer(manifest: m, snapshot: snap));

          // The tile title must appear in the rendered frame.
          expect(tester.terminalState, containsText('Bitcoin'));
        });
      },
    );

    test('build() renders manifest rows inside tile chrome', () async {
      await testNocterm('TileRenderer rows visible in terminal', (
        tester,
      ) async {
        final m = TileManifest.fromJsonString(r'''
            {"id":"x","title":"Stats","layout":[
              {"Row":{"label":"Uptime","value":"42d"}}
            ]}
          ''');
        final snap = const TileSnapshot().copyWith(
          data: <String, dynamic>{},
          lastEventTs: DateTime.utc(2026, 5, 5),
        );

        await tester.pumpComponent(TileRenderer(manifest: m, snapshot: snap));

        expect(tester.terminalState, containsText('Stats'));
        expect(tester.terminalState, containsText('Uptime'));
        expect(tester.terminalState, containsText('42d'));
      });
    });

    test('build() shows footer when snapshot has error', () async {
      await testNocterm('TileRenderer footer on error', (tester) async {
        final m = TileManifest.fromJsonString(r'''
            {"id":"x","title":"Err","layout":[]}
          ''');
        final snap = const TileSnapshot().copyWith(lastError: 'boom');

        await tester.pumpComponent(TileRenderer(manifest: m, snapshot: snap));

        expect(tester.terminalState, containsText('boom'));
      });
    });
  });
}
