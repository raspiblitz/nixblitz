# Plugin Extraction: blitz-api — Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move blitz-api from a built-in core feature to a real plugin in a separate repository (`forge.f44.fyi/f44/nixblitz-plugin-blitz-api`). Plugin ships its own NixOS module + Python subprocess streamer + manifest with declared deps. Delete `BlitzApiBridgeSource`, `InProcessAdapterSource`, `BlitzApiClient`, `sse_event` from core. Real plugin lifecycle (install consent, dep check, marker-driven `plugins.list`, tile-id event filtering) lands as a side effect.

**Architecture:** Plugin manifest gains `requires`, `module`, `streamers` fields. TUI install flow writes a `.nixblitz-installed.json` marker; `plugins.list` is regenerated from markers (orphan paths dropped + logged). Plugin's Python streamer reads SSE from blitz-api, emits JSON-line tile events on stdout. Core's `tileSourceRegistryProvider` registers plugin streamers via `StreamerSubprocessSource`; tile-id filtering at the source-listener glue prevents cross-plugin event smuggling. Install consent prompt enumerates privilege positions; dep-resolution prompt auto-fills URLs from `requires[].url` to prevent typosquat.

**Tech Stack:** Dart (TUI core), Python 3 (plugin streamer), NixOS modules, jj VCS. Plugin repo is separate from core.

**Spec:** `docs/superpowers/specs/2026-05-06-blitz-api-plugin-extraction-design.md`

---

## Two-repo work

This phase touches two repositories:

- **Core**: `~/dev/blitz/nixblitz/` (the main dev tree, branch `main`)
- **Plugin**: `~/dev/blitz/nixblitz-plugin-blitz-api/` (NEW — created in Task 5; pushed to `forge.f44.fyi/f44/nixblitz-plugin-blitz-api` when ready)

Tasks call out which repo they target. The plugin repo doesn't exist on the forge yet; operator creates it via the forge UI before Task 5's push step (or Task 5's report calls out that the repo needs to exist before push lands).

---

## File Structure

### Plugin repo (new)

```
nixblitz-plugin-blitz-api/
├── plugin.json                    # manifest with requires/module/streamers/config_schema
├── module.nix                     # NixOS module (was core's templates/modules/apps/blitz-api.nix)
├── streamers/
│   └── blitz_api_stream.py        # SSE consumer → JSON-lines on stdout
├── tests/
│   └── test_blitz_api_stream.py   # pytest-based unit tests
├── README.md
└── .gitignore
```

### Core (modified)

```
common/lib/src/models/plugin/
  plugin_manifest.dart                # +requires, +module, +streamers fields
  plugin_dep.dart                     # NEW — sealed Requires (AppDep, PluginDep)
  plugin_streamer_spec.dart           # NEW — StreamerSpec model

common/lib/src/services/plugin/
  plugin_marker.dart                  # NEW — read/write .nixblitz-installed.json
  plugin_list_regen.dart              # NEW — regenerate plugins.list from markers
  plugin_dep_check.dart               # NEW — checkPluginDeps function

common/lib/src/providers/
  dashboard_provider.dart             # tile_ids filter at source-listener glue
                                      # plugin streamer registration
  plugin_dep_check_provider.dart      # NEW — Riverpod provider
  installed_plugins_provider.dart     # NEW — reads markers, exposes manifests

tui/lib/src/ui/views/plugins/
  plugin_install_view.dart            # consent prompt + clone + marker + regen
  plugin_enable_disable_view.dart     # toggles disabled flag in marker

tui/lib/src/ui/views/dashboard_view.dart
                                      # banner for missing-dep plugins

templates/hosts/installed.nix         # plugins.list import block
```

### Core (deleted in Task 12)

```
templates/modules/apps/blitz-api.nix                                  # DELETED
common/lib/src/services/configure/bundled/manifests/blitz_api.json    # DELETED
common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart  # DELETED
common/lib/src/services/dashboard/sources/in_process_adapter_source.dart  # DELETED
common/lib/src/services/blitz_api/blitz_api_client.dart               # DELETED
common/lib/src/services/blitz_api/sse_event.dart                      # DELETED
```

### Untouched

- `templates/modules/apps/{bitcoind,lnd,cln,blitz-web}.nix` — Phases 5+.
- `templates/hosts/installed-pi5.nix` (still imports `installed.nix`).
- `NixblitzConfig` shape, the v18 `app_configs` JSON.
- All Phase 1-3 dashboard / config / UI infrastructure.
- `bitcoin.json` + `lightning.json` tile manifests (move to bitcoind/lnd/cln plugins in later phases).
- `system-stats` streamer.

---

## Conventions

- **Trio gate** at the end of each core-touching task: `just test && just analyze && just format`. All tasks land green-trio. Plugin-repo tasks have their own `pytest` + `nix-instantiate --parse` checks.
- **Per-test runs**: `cd common && dart test test/path/foo_test.dart` or `cd tui && dart test test/path/foo_test.dart`. For Python: `cd ~/dev/blitz/nixblitz-plugin-blitz-api && pytest tests/`.
- **Commit format** (both repos): `<type>(<scope>): <subject>` + concise body focused on the why + `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` footer. **No issue refs. No personal email addresses anywhere.**
- **VCS**: jj for the core repo. Plain git for the plugin repo (it's new and operator handles its push to forge).
- Subagents commit per task in the core repo via `jj commit -m '...'` HEREDOC. For plugin-repo tasks, subagents use `git commit -m '...'`.

---

## Task 1: Extend `PluginManifest` with `requires` / `module` / `streamers` fields (core)

**Files:**

- Modify: `common/lib/src/models/plugin/plugin_manifest.dart`
- Create: `common/lib/src/models/plugin/plugin_dep.dart`
- Create: `common/lib/src/models/plugin/plugin_streamer_spec.dart`
- Test: `common/test/models/plugin/plugin_dep_test.dart`
- Test: `common/test/models/plugin/plugin_streamer_spec_test.dart`
- Test: `common/test/models/plugin/plugin_manifest_test.dart` (extend existing)

**Spec reference:** "Plugin manifest schema additions" section.

- [ ] **Step 1: Write failing tests for `PluginDep` (sealed Requires type)**

```dart
// common/test/models/plugin/plugin_dep_test.dart
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:test/test.dart';

void main() {
  group('PluginDep.fromJson', () {
    test('app dep', () {
      final d = PluginDep.fromJson({'type': 'app', 'id': 'bitcoind'});
      expect(d, isA<AppDep>());
      expect((d as AppDep).id, 'bitcoind');
    });

    test('plugin dep', () {
      final d = PluginDep.fromJson({
        'type': 'plugin',
        'url': 'git+https://forge.example/x',
      });
      expect(d, isA<PluginUrlDep>());
      expect((d as PluginUrlDep).url, 'git+https://forge.example/x');
    });

    test('unknown type throws', () {
      expect(
        () => PluginDep.fromJson({'type': 'donut', 'id': 'x'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('missing type throws', () {
      expect(
        () => PluginDep.fromJson({'id': 'x'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('app dep missing id throws', () {
      expect(
        () => PluginDep.fromJson({'type': 'app'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('plugin dep missing url throws', () {
      expect(
        () => PluginDep.fromJson({'type': 'plugin'}),
        throwsA(isA<PluginManifestError>()),
      );
    });
  });
}
```

- [ ] **Step 2: Write failing tests for `StreamerSpec`**

```dart
// common/test/models/plugin/plugin_streamer_spec_test.dart
import 'package:common/src/models/plugin/plugin_streamer_spec.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';   // for PluginManifestError
import 'package:test/test.dart';

void main() {
  group('StreamerSpec.fromJson', () {
    test('full spec', () {
      final s = StreamerSpec.fromJson({
        'name': 'blitz-api-stream',
        'command': 'python3',
        'args': ['streamers/blitz_api_stream.py'],
        'tile_ids': ['bitcoin', 'lightning'],
      });
      expect(s.name, 'blitz-api-stream');
      expect(s.command, 'python3');
      expect(s.args, ['streamers/blitz_api_stream.py']);
      expect(s.tileIds, {'bitcoin', 'lightning'});
    });

    test('empty args', () {
      final s = StreamerSpec.fromJson({
        'name': 'x',
        'command': 'sleep',
        'args': [],
        'tile_ids': ['t1'],
      });
      expect(s.args, isEmpty);
    });

    test('missing name throws', () {
      expect(
        () => StreamerSpec.fromJson({
          'command': 'x', 'args': [], 'tile_ids': [],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('missing command throws', () {
      expect(
        () => StreamerSpec.fromJson({
          'name': 'x', 'args': [], 'tile_ids': [],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('empty tile_ids throws', () {
      expect(
        () => StreamerSpec.fromJson({
          'name': 'x', 'command': 'sleep', 'args': [], 'tile_ids': [],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });
  });
}
```

- [ ] **Step 3: Implement `plugin_dep.dart` + `plugin_streamer_spec.dart`**

```dart
// common/lib/src/models/plugin/plugin_dep.dart
import 'package:meta/meta.dart';

class PluginManifestError implements Exception {
  final String message;
  PluginManifestError(this.message);
  @override String toString() => 'PluginManifestError: $message';
}

@immutable
sealed class PluginDep {
  const PluginDep();

  factory PluginDep.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String) {
      throw PluginManifestError('PluginDep.type required (string)');
    }
    return switch (type) {
      'app' => AppDep._fromJson(json),
      'plugin' => PluginUrlDep._fromJson(json),
      _ => throw PluginManifestError('unknown PluginDep type: $type'),
    };
  }
}

@immutable
class AppDep extends PluginDep {
  final String id;
  const AppDep({required this.id});
  factory AppDep._fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) {
      throw PluginManifestError('AppDep.id required (non-empty string)');
    }
    return AppDep(id: id);
  }
}

@immutable
class PluginUrlDep extends PluginDep {
  final String url;
  const PluginUrlDep({required this.url});
  factory PluginUrlDep._fromJson(Map<String, dynamic> j) {
    final url = j['url'];
    if (url is! String || url.isEmpty) {
      throw PluginManifestError('PluginUrlDep.url required (non-empty string)');
    }
    return PluginUrlDep(url: url);
  }
}
```

```dart
// common/lib/src/models/plugin/plugin_streamer_spec.dart
import 'package:meta/meta.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';

@immutable
class StreamerSpec {
  final String name;
  final String command;
  final List<String> args;
  final Set<String> tileIds;

  const StreamerSpec({
    required this.name,
    required this.command,
    required this.args,
    required this.tileIds,
  });

  factory StreamerSpec.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw PluginManifestError('StreamerSpec.name required (non-empty string)');
    }
    final command = json['command'];
    if (command is! String || command.isEmpty) {
      throw PluginManifestError('StreamerSpec.command required (non-empty string)');
    }
    final args = (json['args'] as List?)?.cast<String>() ?? const [];
    final tileIds = (json['tile_ids'] as List?)?.cast<String>().toSet() ?? const {};
    if (tileIds.isEmpty) {
      throw PluginManifestError('StreamerSpec.tile_ids required (non-empty list)');
    }
    return StreamerSpec(
      name: name,
      command: command,
      args: args,
      tileIds: tileIds,
    );
  }
}
```

- [ ] **Step 4: Extend `PluginManifest` with new fields**

Read existing `plugin_manifest.dart`. Add:

```dart
final List<PluginDep> requires;
final String? module;            // path within plugin checkout to module.nix
final List<StreamerSpec> streamers;
```

In `fromJson`:

```dart
final requires = (json['requires'] as List?)?
    .cast<Map<String, dynamic>>()
    .map(PluginDep.fromJson)
    .toList()
    ?? const [];
final module = json['module'] as String?;
final streamers = (json['streamers'] as List?)?
    .cast<Map<String, dynamic>>()
    .map(StreamerSpec.fromJson)
    .toList()
    ?? const [];
```

Add tests in `plugin_manifest_test.dart`:

```dart
test('manifest with requires + module + streamers', () {
  final m = PluginManifest.fromJson({
    'id': 'p', 'name': 'P', 'version': '1.0.0',
    'url': 'git+https://x',
    'requires': [
      {'type': 'app', 'id': 'bitcoind'},
    ],
    'module': 'module.nix',
    'streamers': [
      {
        'name': 's', 'command': 'python3', 'args': ['x.py'],
        'tile_ids': ['t1'],
      },
    ],
  });
  expect(m.requires.length, 1);
  expect(m.requires.first, isA<AppDep>());
  expect(m.module, 'module.nix');
  expect(m.streamers.length, 1);
});

test('manifest without requires/module/streamers', () {
  final m = PluginManifest.fromJson({
    'id': 'p', 'name': 'P', 'version': '1.0.0',
  });
  expect(m.requires, isEmpty);
  expect(m.module, isNull);
  expect(m.streamers, isEmpty);
});
```

- [ ] **Step 5: Run tests + trio + commit**

```bash
cd common && dart test test/models/plugin/
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(plugin): PluginManifest gains requires + module + streamers fields

Extends Phase 3's PluginManifest schema with:
  - requires: List<PluginDep> — sealed AppDep | PluginUrlDep
  - module: String? — relative path to NixOS module
  - streamers: List<StreamerSpec> — name + command + args + tile_ids

Tile_ids is a Set<String>; required non-empty (a streamer that emits
for no tiles is meaningless). All other field validation: required
non-empty strings, throws PluginManifestError on malformed input.

Phase 4 foundation — install flow + dep check + tile event filtering
(Tasks 2-4) build on these models.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Marker file utility — read/write/regenerate `plugins.list` (core)

**Files:**

- Create: `common/lib/src/services/plugin/plugin_marker.dart`
- Create: `common/lib/src/services/plugin/plugin_list_regen.dart`
- Test: `common/test/services/plugin/plugin_marker_test.dart`
- Test: `common/test/services/plugin/plugin_list_regen_test.dart`

**Spec reference:** "Authoritative state vs. derived file" + "TUI plugin install flow" sections.

- [ ] **Step 1: Write failing tests for marker file roundtrip**

```dart
// common/test/services/plugin/plugin_marker_test.dart
import 'dart:io';

import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plugin_marker_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('PluginMarker', () {
    test('write + read roundtrip', () {
      final marker = PluginMarker(
        id: 'blitz-api',
        url: 'git+https://forge.example/x',
        version: '1.0.0',
        rev: 'abcd1234',
        installedAt: DateTime.utc(2026, 5, 6, 12, 0),
        disabled: false,
      );
      final pluginDir = Directory('${tmp.path}/blitz-api')..createSync();
      writeMarker(pluginDir.path, marker);
      final back = readMarker(pluginDir.path);
      expect(back, isNotNull);
      expect(back!.id, 'blitz-api');
      expect(back.url, 'git+https://forge.example/x');
      expect(back.disabled, isFalse);
    });

    test('readMarker returns null for missing file', () {
      final pluginDir = Directory('${tmp.path}/nonexistent')..createSync();
      expect(readMarker(pluginDir.path), isNull);
    });

    test('readMarker returns null for malformed file', () {
      final pluginDir = Directory('${tmp.path}/bad')..createSync();
      File('${pluginDir.path}/.nixblitz-installed.json')
          .writeAsStringSync('not json');
      expect(readMarker(pluginDir.path), isNull);
    });

    test('disabled flag persists', () {
      final pluginDir = Directory('${tmp.path}/x')..createSync();
      writeMarker(pluginDir.path, PluginMarker(
        id: 'x', url: 'u', version: '1', rev: 'r',
        installedAt: DateTime.utc(2026, 5, 6),
        disabled: true,
      ));
      expect(readMarker(pluginDir.path)!.disabled, isTrue);
    });
  });

  group('discoverInstalledMarkers', () {
    test('finds all markers under plugins/', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      for (final id in ['a', 'b', 'c']) {
        final pd = Directory('${pluginsRoot.path}/$id')..createSync();
        writeMarker(pd.path, PluginMarker(
          id: id, url: 'u', version: '1', rev: 'r',
          installedAt: DateTime.utc(2026, 5, 6),
          disabled: false,
        ));
      }
      // One directory without a marker — should be ignored.
      Directory('${pluginsRoot.path}/d').createSync();
      final found = discoverInstalledMarkers(pluginsRoot.path);
      expect(found.map((m) => m.id).toSet(), {'a', 'b', 'c'});
    });

    test('returns empty when plugins/ is missing', () {
      expect(discoverInstalledMarkers('${tmp.path}/missing'), isEmpty);
    });
  });
}
```

- [ ] **Step 2: Write failing tests for `regeneratePluginsList`**

```dart
// common/test/services/plugin/plugin_list_regen_test.dart
import 'dart:io';

import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/plugin/plugin_list_regen.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('regen_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('regeneratePluginsList', () {
    test('writes one path per enabled marker', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      _writeMarker(pluginsRoot.path, 'b', false);
      final result = regeneratePluginsList(
        baseDir: tmp.path,
        satisfiedPluginIds: {'a', 'b'},
      );
      expect(result.dropped, isEmpty);
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list.split('\n').where((l) => l.isNotEmpty).toSet(), {
        '${pluginsRoot.path}/a',
        '${pluginsRoot.path}/b',
      });
    });

    test('skips disabled plugins', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      _writeMarker(pluginsRoot.path, 'b', true);   // disabled
      final result = regeneratePluginsList(
        baseDir: tmp.path,
        satisfiedPluginIds: {'a', 'b'},
      );
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list, contains('${pluginsRoot.path}/a'));
      expect(list, isNot(contains('${pluginsRoot.path}/b')));
    });

    test('skips plugins with unsatisfied deps', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      _writeMarker(pluginsRoot.path, 'b', false);
      final result = regeneratePluginsList(
        baseDir: tmp.path,
        satisfiedPluginIds: {'a'},   // b is missing
      );
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list, contains('${pluginsRoot.path}/a'));
      expect(list, isNot(contains('${pluginsRoot.path}/b')));
    });

    test('detects + drops orphan paths in old plugins.list', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      // Pre-existing plugins.list with an orphan path:
      File('${tmp.path}/plugins.list').writeAsStringSync(
        '${pluginsRoot.path}/a\n${pluginsRoot.path}/orphan\n',
      );
      final result = regeneratePluginsList(
        baseDir: tmp.path,
        satisfiedPluginIds: {'a'},
      );
      expect(result.dropped, contains('${pluginsRoot.path}/orphan'));
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list, isNot(contains('orphan')));
    });
  });
}

void _writeMarker(String pluginsRoot, String id, bool disabled) {
  final pd = Directory('$pluginsRoot/$id')..createSync();
  writeMarker(pd.path, PluginMarker(
    id: id, url: 'u', version: '1', rev: 'r',
    installedAt: DateTime.utc(2026, 5, 6),
    disabled: disabled,
  ));
}
```

- [ ] **Step 3: Implement `plugin_marker.dart`**

```dart
// common/lib/src/services/plugin/plugin_marker.dart
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

const _markerFilename = '.nixblitz-installed.json';

@immutable
class PluginMarker {
  final String id;
  final String url;
  final String version;
  final String rev;
  final DateTime installedAt;
  final bool disabled;

  const PluginMarker({
    required this.id,
    required this.url,
    required this.version,
    required this.rev,
    required this.installedAt,
    required this.disabled,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'version': version,
    'rev': rev,
    'installed_at': installedAt.toIso8601String(),
    if (disabled) 'disabled': true,
  };

  factory PluginMarker.fromJson(Map<String, dynamic> j) => PluginMarker(
    id: j['id'] as String,
    url: j['url'] as String,
    version: j['version'] as String,
    rev: j['rev'] as String,
    installedAt: DateTime.parse(j['installed_at'] as String),
    disabled: (j['disabled'] as bool?) ?? false,
  );
}

void writeMarker(String pluginDir, PluginMarker marker) {
  File('$pluginDir/$_markerFilename')
      .writeAsStringSync(jsonEncode(marker.toJson()));
}

PluginMarker? readMarker(String pluginDir) {
  final f = File('$pluginDir/$_markerFilename');
  if (!f.existsSync()) return null;
  try {
    return PluginMarker.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  } catch (_) {
    return null;
  }
}

List<PluginMarker> discoverInstalledMarkers(String pluginsRoot) {
  final dir = Directory(pluginsRoot);
  if (!dir.existsSync()) return const [];
  final out = <PluginMarker>[];
  for (final entry in dir.listSync()) {
    if (entry is Directory) {
      final m = readMarker(entry.path);
      if (m != null) out.add(m);
    }
  }
  return out;
}
```

- [ ] **Step 4: Implement `plugin_list_regen.dart`**

```dart
// common/lib/src/services/plugin/plugin_list_regen.dart
import 'dart:io';

import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

class RegenResult {
  final List<String> written;
  final List<String> dropped;
  const RegenResult({required this.written, required this.dropped});
}

RegenResult regeneratePluginsList({
  required String baseDir,
  required Set<String> satisfiedPluginIds,
}) {
  final pluginsRoot = '$baseDir/plugins';
  final markers = discoverInstalledMarkers(pluginsRoot);

  final eligibleMarkers = markers.where((m) =>
    !m.disabled && satisfiedPluginIds.contains(m.id),
  ).toList();

  final eligiblePaths = eligibleMarkers
      .map((m) => '$pluginsRoot/${m.id}')
      .toSet();

  final listFile = File('$baseDir/plugins.list');
  final dropped = <String>[];
  if (listFile.existsSync()) {
    final old = listFile.readAsStringSync()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    for (final path in old) {
      if (!eligiblePaths.contains(path)) {
        dropped.add(path);
        LogService.warn(
          'plugins.list: dropped orphan path on regen — '
          'no marker found at $path',
        );
      }
    }
  }

  final newPaths = eligibleMarkers
      .map((m) => '$pluginsRoot/${m.id}')
      .toList()
    ..sort();
  listFile.writeAsStringSync('${newPaths.join("\n")}\n');

  return RegenResult(written: newPaths, dropped: dropped);
}
```

- [ ] **Step 5: Run tests + trio + commit**

```bash
cd common && dart test test/services/plugin/
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(plugin): marker file utility + plugins.list regen

PluginMarker is the authoritative install record:
  ~/nixblitz/plugins/<id>/.nixblitz-installed.json
  {id, url, version, rev, installed_at, disabled?}

discoverInstalledMarkers() walks plugins/, returns all valid markers.
regeneratePluginsList() rewrites plugins.list from the marker set,
filtered by enabled+dep-satisfied predicates. Orphan paths in the
previous plugins.list (no corresponding marker) are dropped and
warn-logged — catches malicious already-installed plugins that try
to sneak unauthorized imports into the rebuild.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Plugin dependency check (core)

**Files:**

- Create: `common/lib/src/services/plugin/plugin_dep_check.dart`
- Create: `common/lib/src/providers/plugin_dep_check_provider.dart`
- Test: `common/test/services/plugin/plugin_dep_check_test.dart`

**Spec reference:** "Dependency check" section.

- [ ] **Step 1: Write failing tests**

```dart
// common/test/services/plugin/plugin_dep_check_test.dart
import 'package:common/src/models/configure/app_config_field.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/plugin/plugin_dep_check.dart';
import 'package:test/test.dart';

PluginManifest _m(String id, {List<PluginDep> requires = const [], String url = 'u'}) =>
    PluginManifest(
      id: id, name: id, version: '1.0.0', url: url,
      requires: requires,
    );

NixblitzConfig _cfg(Map<String, Map<String, dynamic>> apps) =>
    NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig(/* fill in fallback values */),
      appConfigs: apps,
    );

void main() {
  group('checkPluginDeps', () {
    test('plugin with no deps → ok', () {
      final p = _m('a');
      final result = checkPluginDeps([p], _cfg({}));
      expect(result['a'], DepStatus.ok);
    });

    test('plugin app dep satisfied → ok', () {
      final p = _m('blitz-api', requires: [const AppDep(id: 'bitcoind')]);
      final result = checkPluginDeps(
        [p],
        _cfg({'bitcoind': {'enabled': true}}),
      );
      expect(result['blitz-api'], DepStatus.ok);
    });

    test('plugin app dep missing → unsatisfied', () {
      final p = _m('blitz-api', requires: [const AppDep(id: 'bitcoind')]);
      final result = checkPluginDeps([p], _cfg({}));
      expect(result['blitz-api'], isA<DepMissing>());
      expect((result['blitz-api'] as DepMissing).missing.first, isA<AppDep>());
    });

    test('plugin app dep disabled in config → unsatisfied', () {
      final p = _m('blitz-api', requires: [const AppDep(id: 'bitcoind')]);
      final result = checkPluginDeps(
        [p],
        _cfg({'bitcoind': {'enabled': false}}),
      );
      expect(result['blitz-api'], isA<DepMissing>());
    });

    test('plugin url dep satisfied (other plugin installed) → ok', () {
      final dep = _m('bitcoind-plugin', url: 'git+https://x/bitcoind');
      final p = _m('blitz-api', requires: [
        const PluginUrlDep(url: 'git+https://x/bitcoind'),
      ]);
      final result = checkPluginDeps([dep, p], _cfg({}));
      expect(result['blitz-api'], DepStatus.ok);
    });

    test('plugin url dep missing → unsatisfied', () {
      final p = _m('blitz-api', requires: [
        const PluginUrlDep(url: 'git+https://x/missing'),
      ]);
      final result = checkPluginDeps([p], _cfg({}));
      expect(result['blitz-api'], isA<DepMissing>());
    });
  });
}
```

(Adapt `SystemConfig(...)` to actual constructor; tests may need a `_systemFallback()` helper.)

- [ ] **Step 2: Implement `plugin_dep_check.dart`**

```dart
// common/lib/src/services/plugin/plugin_dep_check.dart
import 'package:meta/meta.dart';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';

@immutable
sealed class DepStatus {
  const DepStatus();
  static const ok = _DepOk();
}

class _DepOk extends DepStatus {
  const _DepOk();
}

@immutable
class DepMissing extends DepStatus {
  final List<PluginDep> missing;
  const DepMissing(this.missing);
}

Map<String, DepStatus> checkPluginDeps(
  List<PluginManifest> plugins,
  NixblitzConfig config,
) {
  final installedUrls = plugins.map((p) => p.url).toSet();
  final result = <String, DepStatus>{};

  for (final plugin in plugins) {
    final missing = <PluginDep>[];
    for (final dep in plugin.requires) {
      switch (dep) {
        case AppDep(:final id):
          if (!config.isAppEnabled(id)) {
            missing.add(dep);
          }
        case PluginUrlDep(:final url):
          if (!installedUrls.contains(url)) {
            missing.add(dep);
          }
      }
    }
    result[plugin.id] = missing.isEmpty ? DepStatus.ok : DepMissing(missing);
  }
  return result;
}
```

- [ ] **Step 3: Implement Riverpod provider**

```dart
// common/lib/src/providers/plugin_dep_check_provider.dart
import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/plugin/plugin_dep_check.dart';
// import the provider that exposes installed plugin manifests
// (Task 5 may add this; for Phase 4 Task 3 it can be a placeholder
// returning an empty list; updated in subsequent tasks.)

final pluginDepCheckProvider = Provider<Map<String, DepStatus>>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  // final plugins = ref.watch(installedPluginsProvider);   // wired in later task
  if (config == null) return const {};
  return checkPluginDeps(/* plugins */ const [], config);
});
```

(The plugin-list source is added later when `installedPluginsProvider` lands. For now, the provider returns `{}` because no plugins are installed.)

- [ ] **Step 4: Run tests + trio + commit**

```bash
cd common && dart test test/services/plugin/plugin_dep_check_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(plugin): dependency check + Riverpod provider

checkPluginDeps walks each plugin's `requires` array, resolves each
PluginDep against the config (for AppDep) or installed plugin set
(for PluginUrlDep). Returns a map of pluginId → DepStatus
(ok | missing).

pluginDepCheckProvider exposes the result reactively. The
installedPluginsProvider it depends on lands in a later task; for
now Phase 4 Task 3 returns an empty map until plugin discovery is
wired up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Tile event filtering at source-listener glue (core)

**Files:**

- Modify: `common/lib/src/providers/dashboard_provider.dart`
- Modify: `common/test/providers/dashboard_provider_test.dart` (or create)

**Spec reference:** "streamers — dashboard tile event sources" section, tile_ids enforcement.

- [ ] **Step 1: Find existing source-listener glue**

```bash
grep -nE 'src.events.listen|cache.apply|providedTileIds' common/lib/src/providers/dashboard_provider.dart
```

The Phase 1 code does something like:

```dart
src.events.listen(cache.apply, onError: (e, st) { ... });
```

This pumps every event into the cache regardless of whether the event's
`tileId` is in the source's declared `providedTileIds`.

- [ ] **Step 2: Update glue to filter unauthorized tile events**

```dart
// In tileDataCacheProvider's setup loop, replace:
//   subs.add(src.events.listen(cache.apply, onError: ...));
// with:

subs.add(src.events.listen(
  (event) {
    if (src.providedTileIds.contains(event.tileId)) {
      cache.apply(event);
    } else {
      LogService.warn(
        'source ${src.id} emitted event for unauthorized tile '
        '"${event.tileId}" (declared: ${src.providedTileIds.join(", ")}); '
        'dropped',
      );
    }
  },
  onError: (e, st) {
    for (final tid in src.providedTileIds) cache.applyError(tid, e);
  },
));
```

- [ ] **Step 3: Write tests for the filter**

```dart
// common/test/providers/dashboard_provider_test.dart (or extend existing)
import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
// ... other imports ...

class _Concrete extends InProcessAdapterSource {
  _Concrete({required Set<String> tileIds})
      : super(id: 'fake', providedTileIds: tileIds);
  void pump(TileEvent e) => emit(e);
}

void main() {
  group('tile event filter', () {
    test('events for declared tiles flow through to cache', () async {
      // Construct a ProviderContainer with a fake source declaring
      // providedTileIds={'foo'}. Pump an event with tileId='foo'.
      // Assert cache.snapshotFor('foo').data was updated.
    });

    test('events for undeclared tiles are dropped + warn-logged', () async {
      // Source declares providedTileIds={'foo'}. Pump event with
      // tileId='bar'. Assert cache.snapshotFor('bar') is empty.
      // (LogService.warn assertion is best-effort; OK to skip if
      // there's no easy hook.)
    });
  });
}
```

(Concrete test setup depends on how dashboard_provider's test
infrastructure works — check existing tests in the file.)

- [ ] **Step 4: Run tests + trio + commit**

```bash
cd common && dart test test/providers/dashboard_provider_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): enforce streamers[].tile_ids at source-listener glue

Phase 1's TileEventSource.providedTileIds was advisory; events for
arbitrary tileIds flowed through to the cache. Phase 4 makes this
authoritative: events whose tileId isn't in the source's declared
providedTileIds are dropped and warn-logged. Prevents cross-plugin
tile event spoofing — a malicious plugin can't emit fake bitcoin
tile state if its declared tile_ids is just ['lightning'].

Filter applied at the listener that pumps events into TileDataCache
(common/lib/src/providers/dashboard_provider.dart).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Bootstrap `nixblitz-plugin-blitz-api` repo (plugin repo)

**Working directory:** `/home/f44/dev/blitz/nixblitz-plugin-blitz-api/` (NEW directory; create as part of this task).

**Files:**

- Create directory: `~/dev/blitz/nixblitz-plugin-blitz-api/`
- Create: `plugin.json`
- Create: `README.md`
- Create: `.gitignore`

**Spec reference:** "Plugin manifest schema additions" + the in-spec example.

This task only creates the manifest and bootstrap files. `module.nix` is
Task 6; the Python streamer is Task 7.

- [ ] **Step 1: Create the directory + git init**

```bash
mkdir -p /home/f44/dev/blitz/nixblitz-plugin-blitz-api
cd /home/f44/dev/blitz/nixblitz-plugin-blitz-api
git init
```

- [ ] **Step 2: Write `plugin.json`**

The schema follows the existing v2 nested `manifest` block with the
Phase 4 `id` / `url` / `version` / `requires` / `module` / `streamers`
fields as top-level siblings of `config_schema`:

```json
{
  "manifest": {
    "schema_version": 2,
    "min_tui_version": 2,
    "name": "Blitz API",
    "description": "FastAPI backend for the Blitz web frontend"
  },

  "id": "blitz-api",
  "version": "0.1.0",
  "url": "git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api",

  "requires": [{ "type": "app", "id": "bitcoind" }],

  "module": "module.nix",

  "streamers": [
    {
      "name": "blitz-api-stream",
      "command": "python3",
      "args": ["streamers/blitz_api_stream.py"],
      "tile_ids": ["bitcoin", "lightning"]
    }
  ],

  "config_schema": {
    "label": "Blitz API",
    "description": "FastAPI backend for the Blitz web frontend",
    "capabilities": [],
    "fields": [
      {
        "name": "enabled",
        "type": "bool",
        "label": "Enabled",
        "default": false
      }
    ]
  }
}
```

- [ ] **Step 3: Write `README.md`**

```markdown
# nixblitz-plugin-blitz-api

NixBlitz plugin: blitz-api FastAPI backend.

This plugin provides:

- A NixOS module configuring `services.blitz-api` (the upstream FastAPI app)
  with sensible defaults for a NixBlitz install (regtest/mainnet modes,
  ZMQ wiring, `.login-password` perms for admin access).
- A Python subprocess streamer that translates blitz-api's SSE event
  stream into NixBlitz dashboard tile events for the bitcoin + lightning
  tiles.

## Install

In NixBlitz: Configure → Plugins → Install from URL →
`git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api`.

Plugin requires `bitcoind` (currently a built-in NixBlitz app; will become
a plugin in a later phase).

## License

MIT.
```

- [ ] **Step 4: Write `.gitignore`**

```
__pycache__/
*.pyc
.pytest_cache/
*.egg-info/
.venv/
```

- [ ] **Step 5: Validate `plugin.json` parses against core's PluginManifest**

```bash
# From the core dev tree:
cd /home/f44/dev/blitz/nixblitz/common
dart run -e "
import 'dart:io';
import 'package:common/src/models/plugin/plugin_manifest.dart';
void main() {
  final s = File('/home/f44/dev/blitz/nixblitz-plugin-blitz-api/plugin.json').readAsStringSync();
  final m = PluginManifest.fromJsonString(s);
  print('id: \${m.id}, version: \${m.version}, url: \${m.url}');
  print('requires: \${m.requires.length}, streamers: \${m.streamers.length}');
}
"
```

(Or write a small one-off test that does the same.) Expected: prints
plugin info without throwing.

- [ ] **Step 6: Initial git commit**

```bash
cd /home/f44/dev/blitz/nixblitz-plugin-blitz-api
git add plugin.json README.md .gitignore
git commit -m "$(cat <<'EOF'
feat: bootstrap nixblitz blitz-api plugin

Initial plugin manifest declaring:
  - dependency on bitcoind (currently core; later a plugin)
  - module.nix entry point (Task 6)
  - Python subprocess streamer for SSE → tile events (Task 7)
  - config_schema with single 'enabled' field

This is the canonical first-party plugin for NixBlitz. Operator
installs via TUI; consent prompt enumerates root-level NixOS module
+ operator-user streamer subprocess privileges.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(No push to forge yet — operator handles that when the repo is ready.)

---

## Task 6: Write `module.nix` in plugin repo (plugin repo)

**Working directory:** `/home/f44/dev/blitz/nixblitz-plugin-blitz-api/`

**Files:**

- Create: `module.nix`

**Spec reference:** "What gets deleted from core" — the file's content is
the wrapper-style content that lived at `templates/modules/apps/blitz-api.nix`.

- [ ] **Step 1: Read core's existing wrapper for reference**

```bash
cat /home/f44/dev/blitz/nixblitz/templates/modules/apps/blitz-api.nix
```

The plugin's `module.nix` is essentially a copy with two adjustments:

1. **No `features.apps.blitz-api` option layer.** The plugin's module.nix
   directly enables `services.blitz-api` based on the user's intent, not
   wrapped in a `cfg.enable` gate. Whether the plugin is loaded at all is
   controlled by `~/nixblitz/plugins.list`. If the plugin's `module.nix`
   is imported, the plugin is meant to be active.
2. **The module reads the user's blitz-api config from `cfg.app_configs.blitz_api`.**
   Same generic-shape reads as core's `installed.nix` does for other apps
   (Phase 2's `appOpt` lambda style).

- [ ] **Step 2: Write `module.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = builtins.fromJSON (builtins.readFile /home/admin/nixblitz/config.json);
  apps = cfg.app_configs or {};
  appOpt = name: key: default:
    let m = apps.${name} or {}; in m.${key} or default;
  appEnabled = name: (cfg.initialized or false) && (appOpt name "enabled" false);

  blitzApiEnabled = appEnabled "blitz_api";
  lndEnabled = config.features.apps.lnd.enable;
  clnEnabled = config.features.apps.cln.enable;
in {
  config = lib.mkIf blitzApiEnabled {
    # bitcoind is still a hard requirement — the API can't start without
    # it. LN is optional.
    assertions = [
      {
        assertion = config.features.apps.bitcoind.enable;
        message = "blitz-api plugin requires features.apps.bitcoind.enable";
      }
    ];

    services.redis.servers."".enable = true;

    services.blitz-api = {
      enable = true;
      generateDotEnvFile = true;
      network = config.features.apps.bitcoind.network;
      rootPath = "/api";
      ln.connectionType =
        if lndEnabled
        then "lnd_grpc"
        else if clnEnabled
        then "cln_jrpc"
        else "none";
      nginx = {
        enable = true;
        hostName = "localhost";
        location = "/api";
        openFirewall = true;
      };
    };

    # ZMQ backstop: upstream blitz-api's setup-env script splits
    # bitcoind.zmqpubrawblock and indexes [2]. nix-bitcoin's lnd/cln
    # set this default; with no LN backend the option stays null.
    services.bitcoind.zmqpubrawblock = lib.mkIf
      (!lndEnabled && !clnEnabled)
      (lib.mkDefault "tcp://127.0.0.1:28332");
    services.bitcoind.zmqpubrawtx = lib.mkIf
      (!lndEnabled && !clnEnabled)
      (lib.mkDefault "tcp://127.0.0.1:28333");

    # Make .login-password readable to wheel members (admin user) and
    # chown the dataDir so blitzapi keeps owner perms (celery worker
    # runs as blitzapi).
    systemd.services.blitz-api-setup-env.postStart = ''
      if [ -f /var/lib/blitz_api/.login-password ]; then
        chgrp wheel /var/lib/blitz_api/.login-password
        chmod 0640 /var/lib/blitz_api/.login-password
      fi
      chown blitzapi:wheel /var/lib/blitz_api
      chmod 0750 /var/lib/blitz_api
    '';
  };
}
```

(Adapt the `cfg.initialized` check + `app_configs` reads to whatever
core's installed.nix uses post-Phase-2.)

- [ ] **Step 3: Validate Nix syntax**

```bash
cd /home/f44/dev/blitz/nixblitz-plugin-blitz-api
nix-instantiate --parse module.nix > /dev/null
echo "syntax ok: $?"
```

- [ ] **Step 4: Commit**

```bash
git add module.nix
git commit -m "$(cat <<'EOF'
feat: add NixOS module

module.nix configures services.blitz-api when app_configs.blitz_api.enabled
is true. Pulls bitcoin network from features.apps.bitcoind.network;
selects ln.connectionType based on which LN backend (lnd/cln) is enabled.
Backstops bitcoind.zmqpubrawblock + zmqpubrawtx when no LN backend is on
(workaround for upstream blitz-api's elemAt-on-1-element bug).
postStart hook chowns dataDir blitzapi:wheel + chmods .login-password
0640 root:wheel for admin read access without sudo.

This is the content that lived at NixBlitz core's
templates/modules/apps/blitz-api.nix; it follows the plugin out as
part of Phase 4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Write `streamers/blitz_api_stream.py` + tests (plugin repo)

**Working directory:** `/home/f44/dev/blitz/nixblitz-plugin-blitz-api/`

**Files:**

- Create: `streamers/blitz_api_stream.py`
- Create: `tests/test_blitz_api_stream.py`
- Create: `tests/__init__.py`

**Spec reference:** "Streamer: `blitz_api_stream.py`" section.

- [ ] **Step 1: Write the Python streamer**

```python
#!/usr/bin/env python3
"""
blitz-api SSE → JSON-line streamer.

Reads the blitz-api SSE event stream and emits JSON-lines on stdout in
the NixBlitz tile-event format:

    {"tile": "bitcoin"|"lightning", "data": {...}, "ts": <unix_ms>}

Config (env vars; defaults match the canonical setup):
    BLITZ_API_HOST       default 127.0.0.1
    BLITZ_API_PORT       default 2121
    BLITZ_API_PASSWORD_FILE  default /var/lib/blitz_api/.login-password

Exit codes:
    0  graceful shutdown (SIGTERM)
    1  authentication failed (password file missing/unreadable, JWT
       refused)
    2  SSE connection lost (causes restart-with-backoff in the parent
       StreamerSubprocessSource)
"""
import json
import os
import sys
import time
from pathlib import Path

import requests
import sseclient


HOST = os.environ.get("BLITZ_API_HOST", "127.0.0.1")
PORT = int(os.environ.get("BLITZ_API_PORT", "2121"))
PWD_FILE = os.environ.get(
    "BLITZ_API_PASSWORD_FILE", "/var/lib/blitz_api/.login-password"
)
BASE = f"http://{HOST}:{PORT}"


# Map SSE event name → tile id.
EVENT_TO_TILE = {
    "btc_info": "bitcoin",
    "btc_mempool_status": "bitcoin",
    "ln_info": "lightning",
    "wallet_balance": "lightning",
}


def _read_password() -> str:
    p = Path(PWD_FILE)
    if not p.exists():
        sys.stderr.write(
            f"password file not found: {PWD_FILE} "
            "(blitz-api-setup-env.service may not have run)\n"
        )
        sys.exit(1)
    try:
        return p.read_text().strip()
    except PermissionError:
        sys.stderr.write(
            f"password file unreadable: {PWD_FILE} "
            "(check group perms — should be 0640 root:wheel)\n"
        )
        sys.exit(1)


def _login(password: str) -> str:
    r = requests.post(
        f"{BASE}/system/login", json={"password": password}, timeout=10
    )
    if r.status_code != 200:
        sys.stderr.write(f"login failed: HTTP {r.status_code} {r.text}\n")
        sys.exit(1)
    body = r.json()
    if isinstance(body, str):
        return body
    if isinstance(body, dict) and "access_token" in body:
        return body["access_token"]
    sys.stderr.write(f"unexpected login response: {body!r}\n")
    sys.exit(1)


def _emit(tile: str, data: dict) -> None:
    sys.stdout.write(
        json.dumps(
            {"tile": tile, "data": data, "ts": int(time.time() * 1000)}
        )
        + "\n"
    )
    sys.stdout.flush()


def _route_event(name: str, data: dict) -> None:
    tile = EVENT_TO_TILE.get(name)
    if tile is None:
        return  # ignored event type
    _emit(tile, data)


def main() -> int:
    password = _read_password()
    jwt = _login(password)
    r = requests.get(
        f"{BASE}/sse/subscribe",
        headers={"Authorization": f"Bearer {jwt}"},
        stream=True,
        timeout=None,
    )
    if r.status_code != 200:
        sys.stderr.write(f"SSE subscribe failed: HTTP {r.status_code}\n")
        sys.exit(2)
    client = sseclient.SSEClient(r)
    for event in client.events():
        if not event.event:
            continue
        try:
            data = json.loads(event.data) if event.data else {}
        except json.JSONDecodeError:
            sys.stderr.write(f"malformed event data: {event.data!r}\n")
            continue
        _route_event(event.event, data)
    return 2  # SSE stream ended unexpectedly


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Write Python unit tests**

```python
# tests/test_blitz_api_stream.py
"""
Unit tests for blitz_api_stream's pure-function bits. The SSE-loop
itself isn't unit-tested (would need a mock SSE source); covered by
manual smoke + the future VM regression test (issue #26).
"""
import io
import json
import sys
from unittest.mock import patch

# Add streamers/ to path
sys.path.insert(
    0,
    str(__import__("pathlib").Path(__file__).parent.parent / "streamers"),
)

import blitz_api_stream as s   # noqa: E402


def test_event_to_tile_mapping():
    assert s.EVENT_TO_TILE["btc_info"] == "bitcoin"
    assert s.EVENT_TO_TILE["btc_mempool_status"] == "bitcoin"
    assert s.EVENT_TO_TILE["ln_info"] == "lightning"
    assert s.EVENT_TO_TILE["wallet_balance"] == "lightning"


def test_emit_writes_json_line():
    buf = io.StringIO()
    with patch.object(sys, "stdout", buf):
        s._emit("bitcoin", {"blocks": 100, "headers": 100})
    line = buf.getvalue().strip()
    parsed = json.loads(line)
    assert parsed["tile"] == "bitcoin"
    assert parsed["data"] == {"blocks": 100, "headers": 100}
    assert "ts" in parsed
    assert isinstance(parsed["ts"], int)


def test_route_known_event_emits():
    buf = io.StringIO()
    with patch.object(sys, "stdout", buf):
        s._route_event("btc_info", {"blocks": 100})
    parsed = json.loads(buf.getvalue().strip())
    assert parsed["tile"] == "bitcoin"


def test_route_unknown_event_no_emit():
    buf = io.StringIO()
    with patch.object(sys, "stdout", buf):
        s._route_event("unknown_event", {"x": 1})
    assert buf.getvalue() == ""
```

- [ ] **Step 3: Empty `tests/__init__.py`** so pytest discovers the package.

```bash
touch tests/__init__.py
```

- [ ] **Step 4: Run pytest**

```bash
cd /home/f44/dev/blitz/nixblitz-plugin-blitz-api
python3 -m pytest tests/ -v
```

(Need `pip install requests sseclient-py pytest` if those aren't in
the environment. Could vendor in a `requirements-dev.txt`.)

- [ ] **Step 5: Commit**

```bash
git add streamers/ tests/
git commit -m "$(cat <<'EOF'
feat: blitz-api SSE → tile-event Python streamer

streamers/blitz_api_stream.py reads /var/lib/blitz_api/.login-password
(must be 0640 root:wheel for non-sudo read by the operator-user
streamer subprocess), logs in via /system/login, subscribes to
/sse/subscribe, routes events:
  btc_info, btc_mempool_status → tile=bitcoin
  ln_info, wallet_balance       → tile=lightning
  others                        → ignored

Emits JSON-lines on stdout in the tile-event format Phase 1's
StreamerSubprocessSource expects. Exits non-zero on auth failure or
SSE drop (parent does restart-with-backoff).

Same logic as core's deleted-in-Task-12 BlitzApiBridgeSource +
BlitzApiClient, in Python.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `installed_plugins_provider` + plugin streamer registration (core)

**Files:**

- Create: `common/lib/src/providers/installed_plugins_provider.dart`
- Modify: `common/lib/src/providers/dashboard_provider.dart` — register plugin streamers
- Modify: `common/lib/src/providers/plugin_dep_check_provider.dart` — wire to installed plugins
- Test: `common/test/providers/installed_plugins_provider_test.dart`

**Spec reference:** "What gets added to core" — `tileSourceRegistryProvider` reads installed-and-enabled plugin manifests.

- [ ] **Step 1: Implement `installed_plugins_provider`**

```dart
// common/lib/src/providers/installed_plugins_provider.dart
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/log_service.dart';

/// All plugins discovered under ~/nixblitz/plugins/<id>/ that have a
/// .nixblitz-installed.json marker AND a parseable plugin.json.
final installedPluginsProvider = Provider<List<PluginManifest>>((ref) {
  final baseDir = '${Platform.environment['HOME']}/nixblitz';
  final pluginsRoot = '$baseDir/plugins';
  final markers = discoverInstalledMarkers(pluginsRoot);
  final manifests = <PluginManifest>[];
  for (final marker in markers) {
    final manifestFile = File('$pluginsRoot/${marker.id}/plugin.json');
    if (!manifestFile.existsSync()) {
      LogService.warn(
        'plugin ${marker.id}: marker present but plugin.json missing; skipping',
      );
      continue;
    }
    try {
      final m = PluginManifest.fromJsonString(manifestFile.readAsStringSync());
      manifests.add(m);
    } catch (e) {
      LogService.warn('plugin ${marker.id}: plugin.json parse error: $e');
    }
  }
  return List.unmodifiable(manifests);
});
```

- [ ] **Step 2: Wire `pluginDepCheckProvider` to it**

Update `plugin_dep_check_provider.dart`:

```dart
final pluginDepCheckProvider = Provider<Map<String, DepStatus>>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final plugins = ref.watch(installedPluginsProvider);
  if (config == null) return const {};
  return checkPluginDeps(plugins, config);
});
```

- [ ] **Step 3: Register plugin streamers in `tileSourceRegistryProvider`**

In `dashboard_provider.dart`, find `tileSourceRegistryProvider`. Add
plugin streamer registration alongside system-stats:

```dart
final tileSourceRegistryProvider = Provider<TileEventSourceRegistry>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final plugins = ref.watch(installedPluginsProvider);
  final depStatuses = ref.watch(pluginDepCheckProvider);

  final reg = TileEventSourceRegistry();

  // system-stats (unconditional, core)
  reg.register(StreamerSubprocessSource(
    id: 'system-stats',
    providedTileIds: const {'hardware', 'system'},
    command: Platform.resolvedExecutable,
    args: const ['streamer', 'system-stats',
        '--units', 'blitz-api,blitz-web,nginx,redis'],
  ));

  // Plugin streamers — only for enabled plugins with satisfied deps.
  final pluginsRoot = '${Platform.environment['HOME']}/nixblitz/plugins';
  for (final plugin in plugins) {
    final status = depStatuses[plugin.id];
    if (status is! _DepOk) continue;   // skip missing-dep
    // Skip disabled plugins (their marker has disabled: true).
    final marker = readMarker('$pluginsRoot/${plugin.id}');
    if (marker == null || marker.disabled) continue;

    for (final spec in plugin.streamers) {
      reg.register(StreamerSubprocessSource(
        id: '${plugin.id}/${spec.name}',
        providedTileIds: spec.tileIds,
        command: spec.command,
        args: spec.args,
        workingDirectory: '$pluginsRoot/${plugin.id}',   // resolve relative paths from plugin root
      ));
    }
  }

  unawaited(reg.startAll());
  ref.onDispose(reg.disposeAll);
  return reg;
});
```

(Note: `StreamerSubprocessSource` from Phase 1 may not have a
`workingDirectory` parameter — check its constructor and add if missing.
Alternatively, plugin streamers must use absolute paths in their args,
which is fine for `command: 'python3'` + absolute `args[0]`.)

- [ ] **Step 4: Test**

Sketch in `installed_plugins_provider_test.dart`: write a fixture
`~/nixblitz/plugins/test-plugin/` with marker + plugin.json, override
HOME via env var (or use a test-specific path constant), assert the
provider returns the manifest.

- [ ] **Step 5: Run trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(plugin): installed_plugins_provider + plugin streamer registration

installedPluginsProvider walks ~/nixblitz/plugins/<id>/ for marker
files, parses each plugin.json, exposes the list reactively.

pluginDepCheckProvider now reads from it (was returning empty).

tileSourceRegistryProvider registers plugin streamers as
StreamerSubprocessSource per streamer entry, but only for plugins
whose deps are satisfied AND that aren't marked disabled in their
marker file.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Plugin install flow — consent prompt + clone + marker + regen (core)

**Files:**

- Create or modify: `tui/lib/src/ui/views/plugins/plugin_install_view.dart`
- Test: `tui/test/ui/views/plugins/plugin_install_view_test.dart`

**Spec reference:** "Install consent + trust contract" + "TUI plugin install flow" sections.

This is the largest UI task. Mirror the existing plugin install flow if
one exists; otherwise build from scratch.

- [ ] **Step 1: Find existing install flow**

```bash
grep -rn 'plugin.*install\|installPlugin\|cloneRepo' tui/lib/src/ui/views/plugin* tui/lib/src/ui/views/*plugin* 2>/dev/null | head -20
```

The Phase 3 work added a Plugins screen; check what's there for
discovery. The new install flow plugs in alongside or replaces.

- [ ] **Step 2: Implement the consent prompt**

Renders the URL, version, requires array, and the privilege-position
text from the spec (verbatim):

```dart
class _PluginConsentPrompt extends StatelessComponent {
  final String url;
  final String version;
  final String rev;
  final List<PluginDep> requires;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  // ...

  @override
  Component build(BuildContext context) {
    return Column(children: [
      Text('Install plugin'),
      Text('  from: $url'),
      Text('  version: $version (rev $rev)'),
      if (requires.isNotEmpty) ...[
        Text('  requires:'),
        for (final r in requires)
          Text('    - ${_describeRequire(r)}'),
      ],
      const SizedBox(height: 1),
      const Text('This plugin runs on your system in two privileged positions:'),
      const Text(''),
      const Text('  • NixOS module activation runs AS ROOT on every system rebuild.'),
      const Text('    The module can define users, services, network rules, file'),
      const Text('    permissions — anything a root-level NixOS module can do.'),
      const Text(''),
      const Text('  • A subprocess streamer runs as the operator user (admin)'),
      const Text('    with full network access. It can read'),
      const Text('    /var/lib/blitz_api/.login-password (the JWT), invoke'),
      const Text('    systemctl, and make outbound network requests.'),
      const SizedBox(height: 1),
      Focusable(
        focused: true,
        onKeyEvent: (event) {
          if (event.logicalKey == LogicalKey.keyY) {
            onConfirm();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyN ||
              event.logicalKey == LogicalKey.escape) {
            onCancel();
            return true;
          }
          return false;
        },
        child: const Text('Confirm install? [y/N]'),
      ),
    ]);
  }
}
```

- [ ] **Step 3: Implement the install action**

```dart
Future<void> _doInstall(String url) async {
  // 1. Clone to /tmp/nixblitz-plugin-install-<pid>/
  final stagingDir = await _cloneRepo(url);
  if (stagingDir == null) {
    _appendLine('clone failed; install aborted');
    return;
  }

  // 2. Read plugin.json from staging
  final manifest = _readManifest(stagingDir);
  if (manifest == null) {
    _appendLine('plugin.json missing or malformed; install aborted');
    return;
  }

  // 3. Get rev from staging git checkout
  final rev = _shortRev(stagingDir);

  // 4. Show consent prompt; await result
  final confirmed = await _consentPrompt(manifest, url, rev);
  if (!confirmed) {
    _appendLine('install cancelled');
    return;
  }

  // 5. Move staging → ~/nixblitz/plugins/<id>/
  final pluginDir = '$baseDir/plugins/${manifest.id}';
  await _moveStagingToPluginDir(stagingDir, pluginDir);

  // 6. Write marker
  writeMarker(pluginDir, PluginMarker(
    id: manifest.id, url: url, version: manifest.version,
    rev: rev, installedAt: DateTime.now(), disabled: false,
  ));

  // 7. Regenerate plugins.list (filtered by current dep status)
  final config = ref.read(configProvider).value;
  final allPlugins = [...ref.read(installedPluginsProvider), manifest];
  final depStatus = checkPluginDeps(allPlugins, config!);
  final satisfiedIds = depStatus.entries
      .where((e) => e.value == DepStatus.ok)
      .map((e) => e.key)
      .toSet();
  final result = regeneratePluginsList(
    baseDir: baseDir,
    satisfiedPluginIds: satisfiedIds,
  );
  for (final dropped in result.dropped) {
    _appendLine('warning: dropped orphan plugins.list path: $dropped');
  }
  _appendLine('installed ${manifest.id} v${manifest.version}');
  _appendLine('run [a] Apply to rebuild');
}
```

- [ ] **Step 4: Run trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(plugin): install flow with consent prompt + marker write

Plugin install via TUI:
  1. clone URL → /tmp/staging
  2. read + validate plugin.json
  3. consent prompt enumerates privilege positions
  4. on confirm: move staging → ~/nixblitz/plugins/<id>/
  5. write .nixblitz-installed.json marker
  6. regenerate plugins.list from all markers (filtered by dep
     satisfaction; orphan paths in old list dropped + warn-logged)
  7. operator runs Apply to rebuild

Consent prompt text per Phase 4 spec — privilege positions, not
theoretical attack surfaces. No security theatre.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Plugin enable/disable flow + dep banner + auto-fill dep prompt (core)

**Files:**

- Create or modify: `tui/lib/src/ui/views/plugins/plugin_manage_view.dart`
- Modify: `tui/lib/src/ui/views/dashboard_view.dart` — banner for missing-dep plugins
- Test: applicable test files

**Spec reference:** "What gets added to core" — enable/disable, banner, dep auto-fill.

- [ ] **Step 1: Enable/disable toggles `disabled` flag in marker**

```dart
Future<void> _setDisabled(String pluginId, bool disabled) async {
  final pluginDir = '$baseDir/plugins/$pluginId';
  final marker = readMarker(pluginDir);
  if (marker == null) return;
  writeMarker(pluginDir, PluginMarker(
    id: marker.id, url: marker.url, version: marker.version,
    rev: marker.rev, installedAt: marker.installedAt,
    disabled: disabled,
  ));
  // Regenerate plugins.list immediately
  // ... same as install Step 7 ...
}
```

- [ ] **Step 2: Dashboard banner for missing-dep plugins**

In `dashboard_view.dart`, add a banner widget that watches
`pluginDepCheckProvider` and renders a row per plugin in
`DepMissing` state:

```dart
final depStatuses = ref.watch(pluginDepCheckProvider);
final missingDeps = depStatuses.entries
    .where((e) => e.value is DepMissing)
    .toList();

if (missingDeps.isNotEmpty) {
  // render banner with plugin name + missing deps; offer to install
  // (URL auto-fill from requires[].url for plugin-type deps)
}
```

- [ ] **Step 3: Dependency-resolution prompt (URL auto-fill)**

When operator opens "install missing dep" from the banner, the URL is
**not** typed — it comes from the plugin's `requires[].url`:

```dart
void _showInstallMissingDepPrompt(PluginUrlDep dep) {
  // Show prompt with the URL pre-filled, no operator typing.
  _showPrompt('Install dependency from ${dep.url}? [y/N]');
}
```

App-type deps get a different prompt: "this plugin requires the
built-in `bitcoind` app. Enable it via Configure → bitcoind → Enabled,
then run Apply."

- [ ] **Step 4: Run trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(plugin): enable/disable flow + missing-dep banner + URL auto-fill

Plugin enable/disable flips the `disabled` flag in the marker file
and regenerates plugins.list (disabled plugins filtered out before
write, so the rebuild simply doesn't import them).

Dashboard banner surfaces plugins in DepMissing state with the
missing dep enumerated. For PluginUrlDep entries: clicking
"install" auto-fills the URL from requires[].url — operator never
types a URL in this flow, eliminating typosquat. For AppDep
entries: "enable via Configure → <app>" guidance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `installed.nix` plugins.list import (core)

**Files:**

- Modify: `templates/hosts/installed.nix`

**Spec reference:** "Nix module discovery: ~/nixblitz/plugins.list" section.

- [ ] **Step 1: Add the imports block**

Read existing `installed.nix`. Find the `imports = […]` list.
Add a let-binding above and merge:

```nix
{
  imports =
    let
      pluginsListPath = ./plugins.list;
      pluginsListContent =
        if builtins.pathExists pluginsListPath
        then builtins.readFile pluginsListPath
        else "";
      pluginPaths = lib.filter (s: s != "")
        (lib.splitString "\n" pluginsListContent);
      pluginModules = map (path: import "${path}/module.nix") pluginPaths;
    in
      [ /* … existing imports … */ ] ++ pluginModules;
  # … existing config block …
}
```

(Adapt placement to the existing file structure.)

- [ ] **Step 2: Regenerate embedded templates**

```bash
just gen-templates
```

- [ ] **Step 3: Run trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(nix): installed.nix imports plugins via plugins.list

Reads ~/nixblitz/plugins.list (TUI-managed, regenerated from markers
on every install/enable/disable/Apply). One absolute path per line;
each path's module.nix is imported as a NixOS module.

Plugins with missing deps and disabled plugins are filtered out by
the TUI before write, so the Nix evaluation never sees them — the
rebuild succeeds even with broken plugins installed.

Embedded templates regenerated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Cleanup — delete obsolete core code (core)

**Files (deleted):**

- `templates/modules/apps/blitz-api.nix`
- `common/lib/src/services/configure/bundled/manifests/blitz_api.json`
- `common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart`
- `common/lib/src/services/dashboard/sources/in_process_adapter_source.dart`
- `common/lib/src/services/blitz_api/blitz_api_client.dart`
- `common/lib/src/services/blitz_api/sse_event.dart`
- The associated test files

**Spec reference:** "What gets deleted from core".

- [ ] **Step 1: Confirm no callers remain**

```bash
grep -rln 'BlitzApiBridgeSource\|InProcessAdapterSource\|BlitzApiClient\|SseEvent\|sse_event' \
  common/lib/ tui/lib/ tui/bin/ 2>&1 | grep -v '\.g\.dart'
```

Should be empty.

- [ ] **Step 2: Delete files**

```bash
rm common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart
rm common/lib/src/services/dashboard/sources/in_process_adapter_source.dart
rm -rf common/lib/src/services/blitz_api/
rm common/lib/src/services/configure/bundled/manifests/blitz_api.json
rm templates/modules/apps/blitz-api.nix
# Test files
rm -f common/test/services/dashboard/sources/blitz_api_bridge_source_test.dart
rm -f common/test/services/dashboard/sources/in_process_adapter_source_test.dart
rm -rf common/test/services/blitz_api/
```

- [ ] **Step 3: Update `common.dart` re-exports**

```bash
grep -nE 'blitz_api|BlitzApiClient|SseEvent|BlitzApiBridgeSource|InProcessAdapterSource' \
  common/lib/common.dart
```

Remove any matching export lines.

- [ ] **Step 4: Regenerate codegen artefacts**

```bash
just gen-templates
just gen-app-schemas
just gen-manifests   # in case dashboard manifests reference removed code
```

- [ ] **Step 5: Trio**

```bash
just test && just analyze && just format
```

All three must be GREEN.

- [ ] **Step 6: Commit**

```bash
jj commit -m "$(cat <<'EOF'
refactor(core): delete obsolete blitz-api code now that it's a plugin

Removes the in-process bridge that Phase 1 introduced as a
transitional shim:
  - BlitzApiBridgeSource — fed bitcoin/lightning tiles via SSE
  - InProcessAdapterSource — base class only used by the bridge
  - BlitzApiClient + sse_event — SSE consumer logic
  - templates/modules/apps/blitz-api.nix — Nix module
  - bundled blitz_api.json config schema

All replaced by the nixblitz-plugin-blitz-api plugin: its
streamers/blitz_api_stream.py replaces the bridge + client +
sse_event; its module.nix replaces the core Nix module; its
plugin.json embeds the config_schema.

Codegen artefacts regenerated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Manual smoke + final trio (operator)

**Files:** none (verification only).

- [ ] **Step 1: Final trio in core**

```bash
cd /home/f44/dev/blitz/nixblitz
just test && just analyze && just format
```

- [ ] **Step 2: Push core commits to forge**

```bash
jj git push
```

- [ ] **Step 3: Push plugin repo to forge**

Operator creates the forge repo at
`forge.f44.fyi/f44/nixblitz-plugin-blitz-api` (via forge UI). Then:

```bash
cd /home/f44/dev/blitz/nixblitz-plugin-blitz-api
git remote add origin git@forge.f44.fyi:f44/nixblitz-plugin-blitz-api.git
git push -u origin main
```

- [ ] **Step 4: Deploy on Pi 5**

```bash
# On Pi:
cd ~/nixblitz
nix flake update nixblitz
sudo nixos-rebuild switch --flake .
```

The first deploy after this will fail because
`templates/modules/apps/blitz-api.nix` is gone but
`config.app_configs.blitz_api.enabled = true`. Expected — the consent
flow needs to install the plugin:

```bash
nixblitz                                # open TUI
# → Configure → Plugins → Install from URL
# → paste git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api
# → review consent prompt → confirm
# → Apply → rebuild succeeds
```

- [ ] **Step 5: Verify dashboard tiles**

- bitcoin tile populates within ~10s (SSE prime via plugin streamer)
- lightning tile populates similarly (or shows "no source" if no LN
  backend is enabled)
- hardware + system tiles unaffected (system-stats still core-bundled)
- service health (Debug → Service Health) shows blitz-api as `active`

- [ ] **Step 6: Verify enable/disable**

- Configure → Plugins → toggle blitz-api off → Apply
- blitz-api service stops; bitcoin tile starts showing "no source"
  in footer
- toggle back on → Apply → service restarts; tiles repopulate

- [ ] **Step 7: Verify dep check**

- Configure → bitcoind → Enabled = false → Apply
- Dashboard banner appears: "blitz-api plugin: missing dependency: bitcoind"
- bitcoin/lightning tiles render "no source" (streamer didn't spawn)
- toggle bitcoind back on → Apply → banner disappears, tiles repopulate

- [ ] **Step 8: Optional asciinema for the record**

```bash
# On dev box, capture: ssh into Pi, demonstrate the install flow:
asciinema rec /tmp/phase4-smoke.cast
# ... run through install + enable + dep check ...
```

If captured, drop it into
`docs/superpowers/specs/2026-05-06-blitz-api-plugin-extraction-design/` and commit.

---

## Self-review

**Spec coverage:**

| Spec section                                                | Implementing task |
| ----------------------------------------------------------- | ----------------- |
| `requires`, `module`, `streamers` manifest fields           | Task 1            |
| Marker file format + `plugins.list` regen                   | Task 2            |
| Dep check function                                          | Task 3            |
| `tile_ids` enforcement                                      | Task 4            |
| Plugin repo bootstrap (plugin.json + README)                | Task 5            |
| Plugin's `module.nix` (transcribed core wrapper)            | Task 6            |
| Plugin's Python streamer (Auth + SSE + routing)             | Task 7            |
| `installed_plugins_provider` + plugin streamer registration | Task 8            |
| Install consent prompt + marker write + regen               | Task 9            |
| Enable/disable + dep banner + URL auto-fill prompt          | Task 10           |
| `installed.nix` plugins.list import                         | Task 11           |
| Cleanup (delete BlitzApiBridge etc.)                        | Task 12           |
| Manual smoke (deploy + install + dashboard verify)          | Task 13           |

All spec sections covered.

**Type / API consistency check:**

- `PluginManifest`, `PluginDep` (sealed `AppDep` | `PluginUrlDep`), `StreamerSpec`, `PluginMarker`, `DepStatus` (sealed `_DepOk` | `DepMissing`), `RegenResult` — names consistent across tasks.
- `installedPluginsProvider`, `pluginDepCheckProvider`, `tileSourceRegistryProvider` — provider names consistent.
- `regeneratePluginsList`, `discoverInstalledMarkers`, `readMarker`, `writeMarker`, `checkPluginDeps` — function names consistent.

**Placeholder scan:** every task shows complete code or precise translation patterns. The `_describeRequire` helper in Task 9 is mentioned but not defined inline — implementer fills in based on PluginDep variants. Same with the `_cloneRepo`, `_readManifest`, `_shortRev`, `_consentPrompt`, `_appendLine` helpers in Task 9 — left to implementer to wire up against the existing TUI patterns. Acknowledged.

**Trio gate per task:** every core-touching task ends with `just test && just analyze && just format` green. Plugin-repo tasks have their own `pytest` + `nix-instantiate --parse` checks.

**Plugin repo / core repo separation:** Tasks 1-4, 8-12 are in core (jj commits). Tasks 5-7 are in the plugin repo (git commits). Task 13 spans both.

---

## Plan complete

Saved to: `docs/superpowers/plans/2026-05-06-blitz-api-plugin-extraction.md`
