import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:common/common.dart';

void main() {
  group('UpdateCheckService.filterStillAhead', () {
    late Directory tmp;
    late String flakePath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('nbz-update-filter-');
      flakePath = tmp.path;
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Build a minimal `flake.lock` JSON whose `root.inputs` references
    /// nodes with the given (name → lockedRev) pairs. Mirrors the shape
    /// `parseRootInputs` reads.
    String lockJson(Map<String, String> nameToLockedRev) {
      final nodes = <String, dynamic>{
        'root': {
          'inputs': {for (final name in nameToLockedRev.keys) name: name},
        },
      };
      for (final entry in nameToLockedRev.entries) {
        nodes[entry.key] = {
          'locked': {
            'type': 'github',
            'owner': 'fusion44',
            'repo': entry.key,
            'rev': entry.value,
          },
          'original': {
            'type': 'github',
            'owner': 'fusion44',
            'repo': entry.key,
          },
        };
      }
      return jsonEncode({'nodes': nodes, 'root': 'root', 'version': 7});
    }

    void writeLock(String json) {
      File('$flakePath/flake.lock').writeAsStringSync(json);
    }

    test('drops entries whose lock has caught up to upstream', () {
      // Cached snapshot: nixblitz lock=A, upstream=B.
      // Live lock now also at B → lock moved → drop.
      writeLock(
        lockJson({'nixblitz': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'}),
      );

      final cached = [
        const InputAhead(
          name: 'nixblitz',
          currentRev: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          upstreamRev: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          url: 'forge.f44.fyi/f44/nixblitz_ng',
        ),
      ];

      final filtered = UpdateCheckService.filterStillAhead(
        cached,
        flakePath: flakePath,
      );
      expect(filtered, isEmpty);
    });

    test('drops entries whose lock advanced past the cached upstream', () {
      // Cached: lock=A, upstream=B. Live lock=C (newer commit pushed
      // between the lightweight check and this dashboard render).
      // Lock has moved — snapshot is stale — drop. The earlier filter
      // version compared `liveRev != upstreamRev` and missed this case;
      // pinning the regression so it can't come back.
      writeLock(
        lockJson({'nixblitz': 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'}),
      );

      final cached = [
        const InputAhead(
          name: 'nixblitz',
          currentRev: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          upstreamRev: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          url: 'forge.f44.fyi/f44/nixblitz_ng',
        ),
      ];

      final filtered = UpdateCheckService.filterStillAhead(
        cached,
        flakePath: flakePath,
      );
      expect(filtered, isEmpty);
    });

    test('keeps entries whose lock is unchanged since the cache', () {
      // Cached: nixblitz lock=A, upstream=B. Live lock still at A.
      writeLock(
        lockJson({'nixblitz': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'}),
      );

      final cached = [
        const InputAhead(
          name: 'nixblitz',
          currentRev: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          upstreamRev: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          url: 'forge.f44.fyi/f44/nixblitz_ng',
        ),
      ];

      final filtered = UpdateCheckService.filterStillAhead(
        cached,
        flakePath: flakePath,
      );
      expect(filtered, hasLength(1));
      expect(filtered.first.name, 'nixblitz');
    });

    test('mixed: filters one, keeps another', () {
      writeLock(
        lockJson({
          // nixblitz lock has moved — drop.
          'nixblitz': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          // nixpkgs lock unchanged since the snapshot — keep.
          'nixpkgs': 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
        }),
      );

      final cached = [
        const InputAhead(
          name: 'nixblitz',
          currentRev: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          upstreamRev: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          url: '',
        ),
        const InputAhead(
          name: 'nixpkgs',
          currentRev: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
          upstreamRev: 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
          url: '',
        ),
      ];

      final filtered = UpdateCheckService.filterStillAhead(
        cached,
        flakePath: flakePath,
      );
      expect(filtered, hasLength(1));
      expect(filtered.first.name, 'nixpkgs');
    });

    test('keeps entries when the input vanished from the lock', () {
      // Edge case: cached snapshot mentions an input that no longer
      // exists in the live lock (renamed / removed). Trust the cache
      // — operator should see *something* on the dashboard rather
      // than silently nothing.
      writeLock(lockJson({'nixpkgs': 'AAAAAA'}));

      final cached = [
        const InputAhead(
          name: 'nixblitz',
          currentRev: 'AAAAAA',
          upstreamRev: 'BBBBBB',
          url: '',
        ),
      ];

      final filtered = UpdateCheckService.filterStillAhead(
        cached,
        flakePath: flakePath,
      );
      expect(filtered, hasLength(1));
    });

    test('returns input unchanged when flake.lock is missing', () {
      // No lock file written.
      final cached = [
        const InputAhead(
          name: 'nixblitz',
          currentRev: 'A',
          upstreamRev: 'B',
          url: '',
        ),
      ];

      final filtered = UpdateCheckService.filterStillAhead(
        cached,
        flakePath: flakePath,
      );
      expect(filtered, equals(cached));
    });

    test('returns input unchanged when flake.lock is unparseable', () {
      File('$flakePath/flake.lock').writeAsStringSync('not json {{{');

      final cached = [
        const InputAhead(
          name: 'nixblitz',
          currentRev: 'A',
          upstreamRev: 'B',
          url: '',
        ),
      ];

      final filtered = UpdateCheckService.filterStillAhead(
        cached,
        flakePath: flakePath,
      );
      expect(filtered, equals(cached));
    });
  });
}
