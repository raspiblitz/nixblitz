import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
          'nixblitz': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
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

  group('lockedInputForPlugin', () {
    test('parses github: scheme', () {
      final p = _marker(url: 'github:example/foo', rev: 'a' * 40);
      final li = UpdateCheckService.lockedInputForPlugin(p);
      expect(li, isNotNull);
      expect(li!.type, 'github');
      expect(li.owner, 'example');
      expect(li.repo, 'foo');
      expect(li.ref, 'main');
      expect(li.lockedRev, 'a' * 40);
    });

    test('parses forgejo: scheme', () {
      final p = _marker(url: 'forgejo:forge.example/owner/repo', rev: 'b' * 40);
      final li = UpdateCheckService.lockedInputForPlugin(p);
      expect(li!.type, 'git');
      expect(li.host, 'forge.example');
      expect(li.owner, 'owner');
      expect(li.repo, 'repo');
    });

    test('returns null for unsupported transport (file://)', () {
      final p = _marker(url: 'file:///tmp/local-plugin', rev: 'c' * 40);
      expect(UpdateCheckService.lockedInputForPlugin(p), isNull);
    });
  });

  group('UpdateCheckService.runLightweight (plugins)', () {
    late Directory tmp;
    late String flakePath;
    late String statusPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('nbz-update-light-plugins-');
      flakePath = tmp.path;
      statusPath = '${tmp.path}/update-status.json';
      // Empty flake.lock — root has no inputs, so the inputs loop is
      // a no-op and we exercise just the plugin walk.
      File('$flakePath/flake.lock').writeAsStringSync(
        jsonEncode({
          'nodes': {
            'root': {'inputs': {}},
          },
          'root': 'root',
          'version': 7,
        }),
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Stub HTTP client returning canned bodies keyed by full request URL.
    /// Unmatched URLs respond 500 so missing fixtures fail loud rather
    /// than silently look like "no upstream".
    http.Client stubHttp(Map<String, Map<String, dynamic>> byUrl) {
      return MockClient((req) async {
        final body = byUrl[req.url.toString()];
        if (body == null) {
          return http.Response('no fixture for ${req.url}', 500);
        }
        return http.Response(jsonEncode(body), 200);
      });
    }

    test('runLightweight walks active auto-update plugins', () async {
      final updateCheckService = UpdateCheckService(
        flakePath: flakePath,
        statusPath: statusPath,
        httpClient: stubHttp({
          'https://api.github.com/repos/example/foo/commits/main': {
            'sha': 'b' * 40,
          },
        }),
        markersReader: () => [
          _marker(id: 'fixture', url: 'github:example/foo', rev: 'a' * 40),
        ],
      );
      final exit = await updateCheckService.runLightweight();
      expect(exit, 0);
      final status = updateCheckService.readStatus();
      expect(status.lightweight!.ok, isTrue);
      expect(status.lightweight!.pluginsAhead, hasLength(1));
      expect(status.lightweight!.pluginsAhead.single.upstreamRev, 'b' * 40);
      expect(status.lightweight!.pluginsAhead.single.currentRev, 'a' * 40);
      expect(status.lightweight!.pluginsAhead.single.pluginId, 'fixture');
    });

    test('runLightweight skips pinned (autoUpdate=false) plugins', () async {
      var httpCalls = 0;
      final updateCheckService = UpdateCheckService(
        flakePath: flakePath,
        statusPath: statusPath,
        httpClient: MockClient((req) async {
          httpCalls++;
          return http.Response('should not be called', 500);
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: 'a' * 40, autoUpdate: false),
        ],
      );
      final exit = await updateCheckService.runLightweight();
      expect(exit, 0);
      final status = updateCheckService.readStatus();
      expect(status.lightweight!.pluginsAhead, isEmpty);
      expect(httpCalls, 0);
    });

    test('runLightweight skips disabled plugins', () async {
      var httpCalls = 0;
      final updateCheckService = UpdateCheckService(
        flakePath: flakePath,
        statusPath: statusPath,
        httpClient: MockClient((req) async {
          httpCalls++;
          return http.Response('should not be called', 500);
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: 'a' * 40, disabled: true),
        ],
      );
      final exit = await updateCheckService.runLightweight();
      expect(exit, 0);
      final status = updateCheckService.readStatus();
      expect(status.lightweight!.pluginsAhead, isEmpty);
      expect(httpCalls, 0);
    });

    test('runLightweight per-plugin error does not abort run', () async {
      // Plugin "bad" returns 500 → throws inside _queryUpstreamRev,
      // caller catches and records an error. Plugin "good" still gets
      // walked and emits a PluginAhead entry.
      final updateCheckService = UpdateCheckService(
        flakePath: flakePath,
        statusPath: statusPath,
        httpClient: stubHttp({
          'https://api.github.com/repos/example/good/commits/main': {
            'sha': 'd' * 40,
          },
          // bad/foo intentionally absent — stub returns 500.
        }),
        markersReader: () => [
          _marker(id: 'bad-plugin', url: 'github:bad/foo', rev: 'a' * 40),
          _marker(id: 'good-plugin', url: 'github:example/good', rev: 'c' * 40),
        ],
      );
      final exit = await updateCheckService.runLightweight();
      expect(exit, 0);
      final status = updateCheckService.readStatus();
      expect(status.lightweight!.ok, isTrue);
      expect(status.lightweight!.pluginsAhead, hasLength(1));
      expect(status.lightweight!.pluginsAhead.single.pluginId, 'good-plugin');
      expect(status.lightweight!.pluginsAhead.single.upstreamRev, 'd' * 40);
      expect(status.lightweight!.error, isNotNull);
      expect(status.lightweight!.error, contains('bad-plugin'));
    });

    test('runLightweight skips plugins with unsupported transport', () async {
      var httpCalls = 0;
      final updateCheckService = UpdateCheckService(
        flakePath: flakePath,
        statusPath: statusPath,
        httpClient: MockClient((req) async {
          httpCalls++;
          return http.Response('should not be called', 500);
        }),
        markersReader: () => [_marker(url: 'file:///tmp/local', rev: 'a' * 40)],
      );
      final exit = await updateCheckService.runLightweight();
      expect(exit, 0);
      final status = updateCheckService.readStatus();
      expect(status.lightweight!.pluginsAhead, isEmpty);
      expect(httpCalls, 0);
    });

    test(
      'runLightweight emits no PluginAhead when upstream matches pin',
      () async {
        final updateCheckService = UpdateCheckService(
          flakePath: flakePath,
          statusPath: statusPath,
          httpClient: stubHttp({
            'https://api.github.com/repos/example/foo/commits/main': {
              'sha': 'a' * 40,
            },
          }),
          markersReader: () => [
            _marker(url: 'github:example/foo', rev: 'a' * 40),
          ],
        );
        final exit = await updateCheckService.runLightweight();
        expect(exit, 0);
        final status = updateCheckService.readStatus();
        expect(status.lightweight!.pluginsAhead, isEmpty);
      },
    );
  });
}

PluginMarker _marker({
  String id = 'fixture',
  required String url,
  required String rev,
  String branch = 'main',
  bool disabled = false,
  bool autoUpdate = true,
}) => PluginMarker(
  id: id,
  url: url,
  version: '0.1.0',
  rev: rev,
  installedAt: DateTime.utc(2026, 1, 1),
  disabled: disabled,
  branch: branch,
  autoUpdate: autoUpdate,
);
