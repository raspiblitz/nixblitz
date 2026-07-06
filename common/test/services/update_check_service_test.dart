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

  group('parseDryRunStderr', () {
    test('empty input → empty plan', () {
      final plan = parseDryRunStderr('');
      expect(plan.wouldBuild, isEmpty);
      expect(plan.wouldFetch, isEmpty);
    });

    test('parses both stanzas (build + fetch)', () {
      const stderr = '''
warning: ignoring untrusted setting
these 2 derivations will be built:
  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-rustc-1.87.0.drv
  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-cargo-helper-0.1.drv
these 3 paths will be fetched (456.00 MiB download, 789.00 MiB unpacked):
  /nix/store/cccccccccccccccccccccccccccccccc-libfoo-2.3.drv
  /nix/store/dddddddddddddddddddddddddddddddd-libbar-4.5.drv
  /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-libbaz-6.7.drv
''';
      final plan = parseDryRunStderr(stderr);
      expect(plan.wouldBuild, ['cargo-helper-0.1', 'rustc-1.87.0']);
      expect(plan.wouldFetch, ['libbar-4.5', 'libbaz-6.7', 'libfoo-2.3']);
    });

    test('handles singular header variants', () {
      const stderr = '''
this derivation will be built:
  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-only-one.drv
this path will be fetched (1.00 MiB):
  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other-thing.drv
''';
      final plan = parseDryRunStderr(stderr);
      expect(plan.wouldBuild, ['only-one']);
      expect(plan.wouldFetch, ['other-thing']);
    });

    test('blank line ends the section (no spurious cross-pollination)', () {
      const stderr = '''
these 1 derivations will be built:
  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-built.drv

  /nix/store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-stray.drv
these 1 paths will be fetched:
  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-fetched.drv
''';
      final plan = parseDryRunStderr(stderr);
      expect(plan.wouldBuild, ['built']);
      expect(plan.wouldFetch, ['fetched']);
    });

    test('only-fetch stanza (substitutes-only update)', () {
      const stderr = '''
these 2 paths will be fetched (10 MiB):
  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo-1.0.drv
  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bar-2.0.drv
''';
      final plan = parseDryRunStderr(stderr);
      expect(plan.wouldBuild, isEmpty);
      expect(plan.wouldFetch, ['bar-2.0', 'foo-1.0']);
    });

    test('strips .drv suffix and store hash prefix', () {
      const stderr = '''
this derivation will be built:
  /nix/store/0123456789abcdef0123456789abcdef-some-pkg-with-dashes-9.9.drv
''';
      final plan = parseDryRunStderr(stderr);
      expect(plan.wouldBuild, ['some-pkg-with-dashes-9.9']);
    });
  });

  group('lockedInputForPlugin', () {
    test('parses github: scheme', () {
      final p = _marker(url: 'github:example/foo', rev: 'a' * 40);
      final li = lockedInputForPlugin(p);
      expect(li, isNotNull);
      expect(li!.type, 'github');
      expect(li.owner, 'example');
      expect(li.repo, 'foo');
      expect(li.ref, 'main');
      expect(li.lockedRev, 'a' * 40);
    });

    test('parses forgejo: scheme', () {
      final p = _marker(url: 'forgejo:forge.example/owner/repo', rev: 'b' * 40);
      final li = lockedInputForPlugin(p);
      expect(li!.type, 'git');
      expect(li.host, 'forge.example');
      expect(li.owner, 'owner');
      expect(li.repo, 'repo');
    });

    test('returns null for unsupported transport (file://)', () {
      final p = _marker(url: 'file:///tmp/local-plugin', rev: 'c' * 40);
      expect(lockedInputForPlugin(p), isNull);
    });
  });

  group('UpdateCheckService.probeUpstreamMovement (plugins)', () {
    late Directory tmp;
    late String flakePath;
    late String statusPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('nbz-probe-plugins-');
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
    /// than silently look like "no upstream". Values can be any
    /// JSON-encodable shape — maps for single-resource endpoints,
    /// lists for collection endpoints.
    http.Client stubHttp(Map<String, Object?> byUrl) {
      return MockClient((req) async {
        if (!byUrl.containsKey(req.url.toString())) {
          return http.Response('no fixture for ${req.url}', 500);
        }
        return http.Response(jsonEncode(byUrl[req.url.toString()]), 200);
      });
    }

    UpdateCheckService svcWith({
      required http.Client httpClient,
      required List<PluginMarker> Function() markersReader,
    }) {
      return UpdateCheckService(
        flakePath: flakePath,
        statusPath: statusPath,
        // Isolate staging writes from /var/lib in tests.
        stagingService: StagingService(basePath: '${tmp.path}/staging'),
        httpClient: httpClient,
        markersReader: markersReader,
      );
    }

    test('walks active auto-update plugins', () async {
      final svc = svcWith(
        httpClient: stubHttp({
          'https://api.github.com/repos/example/foo/commits/main': {
            'sha': 'b' * 40,
          },
        }),
        markersReader: () => [
          _marker(id: 'fixture', url: 'github:example/foo', rev: 'a' * 40),
        ],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, hasLength(1));
      expect(r.pluginsAhead.single.upstreamRev, 'b' * 40);
      expect(r.pluginsAhead.single.currentRev, 'a' * 40);
      expect(r.pluginsAhead.single.pluginId, 'fixture');
    });

    test('skips pinned (autoUpdate=false) plugins', () async {
      var httpCalls = 0;
      final svc = svcWith(
        httpClient: MockClient((req) async {
          httpCalls++;
          return http.Response('should not be called', 500);
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: 'a' * 40, autoUpdate: false),
        ],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, isEmpty);
      expect(httpCalls, 0);
    });

    test('skips disabled plugins', () async {
      var httpCalls = 0;
      final svc = svcWith(
        httpClient: MockClient((req) async {
          httpCalls++;
          return http.Response('should not be called', 500);
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: 'a' * 40, disabled: true),
        ],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, isEmpty);
      expect(httpCalls, 0);
    });

    test('per-plugin error does not abort run', () async {
      // Plugin "bad" returns 500 → throws inside _queryUpstreamRev,
      // caller catches and records an error. Plugin "good" still gets
      // walked and emits a PluginAhead entry.
      final svc = svcWith(
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
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, hasLength(1));
      expect(r.pluginsAhead.single.pluginId, 'good-plugin');
      expect(r.pluginsAhead.single.upstreamRev, 'd' * 40);
      expect(r.errors, isNotEmpty);
      expect(r.errors.any((e) => e.contains('bad-plugin')), isTrue);
    });

    test('skips plugins with unsupported transport', () async {
      var httpCalls = 0;
      final svc = svcWith(
        httpClient: MockClient((req) async {
          httpCalls++;
          return http.Response('should not be called', 500);
        }),
        markersReader: () => [_marker(url: 'file:///tmp/local', rev: 'a' * 40)],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, isEmpty);
      expect(httpCalls, 0);
    });

    test('emits no PluginAhead when upstream matches pin', () async {
      final svc = svcWith(
        httpClient: stubHttp({
          'https://api.github.com/repos/example/foo/commits/main': {
            'sha': 'a' * 40,
          },
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: 'a' * 40),
        ],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, isEmpty);
    });

    test('version-aware probe: upstream version > pinned → ahead', () async {
      // Stub the branch HEAD probe (returns new SHA), the manifest
      // fetch at upstream HEAD (returns version 1.2.0), the
      // commits-affecting-path query (returns one commit), and the
      // manifest fetch at that introducing commit (version 1.2.0
      // still). The plugin's marker reports version 1.1.0.
      final upstreamSha = 'b' * 40;
      final pinnedSha = 'a' * 40;
      final svc = svcWith(
        httpClient: stubHttp({
          'https://api.github.com/repos/example/foo/commits/main': {
            'sha': upstreamSha,
          },
          'https://api.github.com/repos/example/foo/contents/plugin.json?ref=$upstreamSha':
              _contentsResponse('1.2.0'),
          'https://api.github.com/repos/example/foo/commits?path=plugin.json&sha=$upstreamSha&per_page=50':
              <Map<String, dynamic>>[
                {'sha': upstreamSha},
              ],
          'https://api.github.com/repos/example/foo/contents/plugin.json?ref=$pinnedSha':
              _contentsResponse('1.1.0'),
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: pinnedSha, version: '1.1.0'),
        ],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, hasLength(1));
      final ahead = r.pluginsAhead.single;
      expect(ahead.currentVersion, '1.1.0');
      expect(ahead.upstreamVersion, '1.2.0');
      expect(ahead.isDowngrade, isFalse);
    });

    test(
      'version-aware probe: upstream version < pinned → isDowngrade',
      () async {
        final upstreamSha = 'b' * 40;
        final pinnedSha = 'a' * 40;
        final svc = svcWith(
          httpClient: stubHttp({
            'https://api.github.com/repos/example/foo/commits/main': {
              'sha': upstreamSha,
            },
            'https://api.github.com/repos/example/foo/contents/plugin.json?ref=$upstreamSha':
                _contentsResponse('1.0.0'),
          }),
          markersReader: () => [
            _marker(
              url: 'github:example/foo',
              rev: pinnedSha,
              version: '1.2.0',
            ),
          ],
        );
        final r = await svc.probeUpstreamMovement();
        expect(r.pluginsAhead, hasLength(1));
        final ahead = r.pluginsAhead.single;
        expect(ahead.isDowngrade, isTrue);
        expect(ahead.currentVersion, '1.2.0');
        expect(ahead.upstreamVersion, '1.0.0');
      },
    );

    test('version-aware probe: same upstream version → no PluginAhead', () async {
      // Mono-repo false-positive case: a commit lands that doesn't
      // touch this plugin's manifest. Upstream SHA moves but the
      // version field is unchanged. Old code reported "ahead" purely
      // on SHA inequality; introducing-commit pinning means we
      // suppress the row.
      final upstreamSha = 'b' * 40;
      final pinnedSha = 'a' * 40;
      final svc = svcWith(
        httpClient: stubHttp({
          'https://api.github.com/repos/example/foo/commits/main': {
            'sha': upstreamSha,
          },
          'https://api.github.com/repos/example/foo/contents/plugin.json?ref=$upstreamSha':
              _contentsResponse('1.2.0'),
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: pinnedSha, version: '1.2.0'),
        ],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, isEmpty);
    });

    test('unversioned plugin falls through to SHA tracking', () async {
      // Marker has version='' (pre-version-field install). Upstream
      // manifest fetch returns 404 (no plugin.json at this path).
      // Both null → fall back to pure SHA comparison, ahead emitted.
      final upstreamSha = 'b' * 40;
      final pinnedSha = 'a' * 40;
      final svc = svcWith(
        httpClient: MockClient((req) async {
          final url = req.url.toString();
          if (url == 'https://api.github.com/repos/example/foo/commits/main') {
            return http.Response(jsonEncode({'sha': upstreamSha}), 200);
          }
          // Everything else 404s — version-tracking unavailable.
          return http.Response('not found', 404);
        }),
        markersReader: () => [
          _marker(url: 'github:example/foo', rev: pinnedSha, version: ''),
        ],
      );
      final r = await svc.probeUpstreamMovement();
      expect(r.pluginsAhead, hasLength(1));
      final ahead = r.pluginsAhead.single;
      expect(ahead.currentRev, pinnedSha);
      expect(ahead.upstreamRev, upstreamSha);
      expect(ahead.currentVersion, isNull);
      expect(ahead.upstreamVersion, isNull);
      expect(ahead.isDowngrade, isFalse);
    });
  });
}

/// Helper: build a Forgejo/GitHub-style contents-API response body
/// containing a plugin.json with the given version.
Map<String, dynamic> _contentsResponse(String version) {
  final manifestJson = jsonEncode({
    'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'fixture'},
    'id': 'fixture',
    'version': version,
  });
  return {'content': base64.encode(utf8.encode(manifestJson))};
}

PluginMarker _marker({
  String id = 'fixture',
  required String url,
  required String rev,
  String branch = 'main',
  bool disabled = false,
  bool autoUpdate = true,
  String version = '0.1.0',
}) => PluginMarker(
  id: id,
  url: url,
  version: version,
  rev: rev,
  installedAt: DateTime.utc(2026, 1, 1),
  disabled: disabled,
  branch: branch,
  autoUpdate: autoUpdate,
);
