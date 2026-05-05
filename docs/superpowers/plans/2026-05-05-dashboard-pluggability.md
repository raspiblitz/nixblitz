# Dashboard Pluggability — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dashboard's hand-coded tile widgets with a generic, manifest-driven renderer fed by JSON-lines tile event sources, and detach hardware/system tiles from blitz-api.

**Architecture:** Tile manifests (JSON, embedded as Dart string constants) describe what to render via a small primitive registry (`Row`, `StatusRow`, `ProgressBar`, `Section`, `Spacer`, `Footer`) and a binding directive language (`$data`, `$bytes`, `$duration`, `$pct`, `$truncate`, `$format`, `$status`). `TileEventSource` implementations (`StreamerSubprocessSource`, `InProcessAdapterSource`) emit `TileEvent(tileId, data)` tuples that flow into a `TileDataCache`, which is consumed by one generic `TileRenderer` widget per manifest. Bundled streamers in core: `system-stats` (real subprocess, reads procfs/sysfs) and `blitz-api-bridge` (in-process adapter wrapping the existing SSE consumer; transitional, dies in Phase 4).

**Tech Stack:** Dart, nocterm TUI, Riverpod, JSON, procfs/sysfs, Dart `Process.start` for subprocess management.

**Spec:** `docs/superpowers/specs/2026-05-05-dashboard-pluggability-design.md`

---

## File Structure

### New files

```
common/lib/src/services/dashboard/
  tile_event.dart                    # TileEvent value class
  tile_snapshot.dart                 # TileSnapshot value class
  tile_event_source.dart             # abstract TileEventSource
  tile_event_source_registry.dart    # TileEventSourceRegistry
  tile_data_cache.dart               # TileDataCache (apply / streamFor)
  colors.dart                        # semantic color names → nocterm colors
  dsl/
    primitives.dart                  # Row / StatusRow / ProgressBar / Section / Spacer / Footer typed nodes
    tile_manifest.dart               # TileManifest model + JSON parser
    binding_resolver.dart            # $data/$bytes/$duration/$pct/$truncate/$format/$status
  sources/
    in_process_adapter_source.dart   # transitional base; deleted in Phase 4
    streamer_subprocess_source.dart  # spawn long-lived process, parse JSON-lines
    blitz_api_bridge_source.dart     # wraps BlitzApiClient + sse_event for tile output
  bundled/
    manifests/
      bitcoin.json                   # source-of-truth manifest
      lightning.json
      hardware.json
      system.json
    embedded_manifests.dart          # `part of` library that embeds the JSON via codegen
    embedded_manifests.g.dart        # GENERATED — `dart run scripts/gen_dashboard_manifests.dart`
    registry.dart                    # bundledManifests: List<TileManifest>

common/lib/src/streamers/
  system_stats_streamer.dart         # main() entry — procfs/sysfs reader + JSON-line emit

tui/lib/src/ui/views/dashboard/
  tile_renderer.dart                 # paints any TileManifest given a TileSnapshot
  dashboard_chrome.dart              # hostname/platform/network identity header

scripts/
  gen_dashboard_manifests.dart       # mirrors gen_embedded_templates.dart pattern

common/test/services/dashboard/        # tests parallel the source tree
tui/test/ui/views/dashboard/           # renderer + chrome tests
```

### Modified files

- `tui/bin/nixblitz.dart` — argv dispatch: `nixblitz streamer <name>` → run streamer entry, skip TUI
- `tui/lib/src/ui/views/dashboard_view.dart` — replace four hardcoded tiles with chrome + tile-manifest list + TileRenderer per manifest
- `common/lib/src/providers/dashboard_provider.dart` — replace `dashboardDataSourceProvider` + 4 snapshot providers with `tileSourceRegistryProvider` + `tileDataCacheProvider` + `tileSnapshotProvider.family` + `tileManifestsProvider`
- `justfile` — add `gen-manifests` recipe
- `common/lib/src/services/blitz_api/blitz_api_client.dart` — no behavioural change; just gains a new caller (`BlitzApiBridgeSource`)

### Deleted files

- `common/lib/src/services/dashboard/dashboard_data_source.dart` (interface + `NullDashboardSource`)
- `common/lib/src/services/dashboard/api_dashboard_source.dart` (logic moves into `BlitzApiBridgeSource`)
- `common/lib/src/models/dashboard/snapshots.dart` (`SystemSnapshot`, `HardwareSnapshot`, `BtcSnapshot`, `LnSnapshot`)
- `tui/lib/src/ui/views/dashboard/bitcoin_tile.dart`
- `tui/lib/src/ui/views/dashboard/lightning_tile.dart`
- `tui/lib/src/ui/views/dashboard/hardware_tile.dart`
- `tui/lib/src/ui/views/dashboard/system_tile.dart`

---

## Conventions

- **Tests live next to the code they cover** under `common/test/...` and `tui/test/...`. Test file mirrors source path.
- **Per-test runs during TDD**: `cd common && dart test test/services/dashboard/foo_test.dart -p vm -n 'test name substring'`
- **Trio gate** at the end of every task before commit:
  ```bash
  just test
  just analyze
  just format
  ```
  All three must pass / produce no diff before committing.
- **Commit format** (CLAUDE.md):
  ```
  <type>(<scope>): <subject>

  <body — focused on the why>

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```
  Types: `feat`, `fix`, `refactor`, `chore`, `test`. No issue refs.
- **VCS**: jj colocated. New files are auto-staged. Commit with `jj commit -m '...'` or `git commit` — both work.

---

## Task 1: TileEvent + TileSnapshot value classes

**Files:**
- Create: `common/lib/src/services/dashboard/tile_event.dart`
- Create: `common/lib/src/services/dashboard/tile_snapshot.dart`
- Test: `common/test/services/dashboard/tile_event_test.dart`
- Test: `common/test/services/dashboard/tile_snapshot_test.dart`

**Spec reference:** "Architecture" + "TileEventSource contract" sections — `TileEvent` is what sources emit; `TileSnapshot` is what providers expose to renderers.

- [ ] **Step 1: Write failing tests for `TileEvent`**

```dart
// common/test/services/dashboard/tile_event_test.dart
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

void main() {
  group('TileEvent', () {
    test('holds tileId, data, ts', () {
      final ts = DateTime.utc(2026, 5, 5);
      final ev = TileEvent(tileId: 'bitcoin', data: const {'blocks': 100}, ts: ts);
      expect(ev.tileId, 'bitcoin');
      expect(ev.data['blocks'], 100);
      expect(ev.ts, ts);
    });

    test('equality by all fields', () {
      final ts = DateTime.utc(2026, 5, 5);
      final a = TileEvent(tileId: 'a', data: const {'x': 1}, ts: ts);
      final b = TileEvent(tileId: 'a', data: const {'x': 1}, ts: ts);
      final c = TileEvent(tileId: 'a', data: const {'x': 2}, ts: ts);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });
}
```

- [ ] **Step 2: Write failing tests for `TileSnapshot`**

```dart
// common/test/services/dashboard/tile_snapshot_test.dart
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:test/test.dart';

void main() {
  group('TileSnapshot', () {
    test('default is empty / null error / null ts', () {
      const s = TileSnapshot();
      expect(s.data, isEmpty);
      expect(s.lastError, isNull);
      expect(s.lastEventTs, isNull);
    });

    test('isEmpty getter true on default', () {
      expect(const TileSnapshot().isEmpty, isTrue);
    });

    test('copyWith preserves untouched fields', () {
      final ts = DateTime.utc(2026, 5, 5);
      final s = const TileSnapshot().copyWith(
        data: {'a': 1},
        lastEventTs: ts,
      );
      expect(s.data['a'], 1);
      expect(s.lastEventTs, ts);
      expect(s.lastError, isNull);

      final s2 = s.copyWith(lastError: 'boom');
      expect(s2.data['a'], 1);
      expect(s2.lastEventTs, ts);
      expect(s2.lastError, 'boom');
    });
  });
}
```

- [ ] **Step 3: Run tests — confirm they fail (files don't exist yet)**

```bash
cd common && dart test test/services/dashboard/tile_event_test.dart test/services/dashboard/tile_snapshot_test.dart
```

Expected: compilation error / file not found.

- [ ] **Step 4: Implement `TileEvent`**

```dart
// common/lib/src/services/dashboard/tile_event.dart
import 'package:meta/meta.dart';

/// Single update from a [TileEventSource]. The source emits one of
/// these per logical state change; the [TileDataCache] merges
/// `data` into the per-tile snapshot.
@immutable
class TileEvent {
  final String tileId;
  final Map<String, dynamic> data;
  final DateTime ts;

  const TileEvent({
    required this.tileId,
    required this.data,
    required this.ts,
  });

  @override
  bool operator ==(Object other) =>
      other is TileEvent &&
      other.tileId == tileId &&
      _mapEquals(other.data, data) &&
      other.ts == ts;

  @override
  int get hashCode => Object.hash(tileId, _mapHashCode(data), ts);
}

bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k) || a[k] != b[k]) return false;
  }
  return true;
}

int _mapHashCode(Map<String, dynamic> m) {
  var h = 0;
  for (final e in m.entries) {
    h ^= Object.hash(e.key, e.value);
  }
  return h;
}
```

- [ ] **Step 5: Implement `TileSnapshot`**

```dart
// common/lib/src/services/dashboard/tile_snapshot.dart
import 'package:meta/meta.dart';

/// Per-tile state the renderer consumes. Built up by the
/// [TileDataCache] from successive [TileEvent]s.
@immutable
class TileSnapshot {
  final Map<String, dynamic> data;
  final Object? lastError;
  final DateTime? lastEventTs;

  const TileSnapshot({
    this.data = const {},
    this.lastError,
    this.lastEventTs,
  });

  bool get isEmpty => data.isEmpty && lastError == null && lastEventTs == null;

  TileSnapshot copyWith({
    Map<String, dynamic>? data,
    Object? lastError,
    DateTime? lastEventTs,
    bool clearError = false,
  }) => TileSnapshot(
    data: data ?? this.data,
    lastError: clearError ? null : (lastError ?? this.lastError),
    lastEventTs: lastEventTs ?? this.lastEventTs,
  );
}
```

- [ ] **Step 6: Run tests — confirm pass**

```bash
cd common && dart test test/services/dashboard/tile_event_test.dart test/services/dashboard/tile_snapshot_test.dart
```

Expected: all pass.

- [ ] **Step 7: Trio**

```bash
just test
just analyze
just format
```

Expected: all green; no diff on format.

- [ ] **Step 8: Commit**

```bash
jj commit -m "$(cat <<'EOF'
feat(dashboard): add TileEvent + TileSnapshot value classes

Foundation for the dashboard refactor: sources emit TileEvent tuples,
the cache exposes TileSnapshot to the renderer. Plain immutable data
classes; no behaviour yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Color name → nocterm color mapping

**Files:**
- Create: `common/lib/src/services/dashboard/colors.dart`
- Test: `common/test/services/dashboard/colors_test.dart`

**Spec reference:** "Colors" sub-section. Semantic names (`ok`, `warn`, `error`, `accent`, `muted`, `default`) plus hex passthrough.

- [ ] **Step 1: Write failing tests**

```dart
// common/test/services/dashboard/colors_test.dart
import 'package:common/src/services/dashboard/colors.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('resolveTileColor', () {
    test('semantic ok → green', () {
      expect(resolveTileColor('ok', accent: const Color(0xff000000)),
          equals(Color.fromARGB(255, 0x4c, 0xaf, 0x50)));
    });

    test('semantic accent returns the supplied accent color', () {
      const accent = Color(0xfff7931a);
      expect(resolveTileColor('accent', accent: accent), equals(accent));
    });

    test('hex string returns the parsed color', () {
      expect(
        resolveTileColor('#ff8800', accent: const Color(0xff000000)),
        equals(Color.fromARGB(255, 0xff, 0x88, 0x00)),
      );
    });

    test('null returns default theme color', () {
      expect(resolveTileColor(null, accent: const Color(0xff000000)),
          isNotNull);
    });

    test('unknown name returns default + does not throw', () {
      expect(
        () => resolveTileColor('nonsense', accent: const Color(0xff000000)),
        returnsNormally,
      );
    });
  });

  group('parseHex', () {
    test('#rrggbb', () {
      expect(parseHex('#ff8800'),
          equals(Color.fromARGB(255, 0xff, 0x88, 0x00)));
    });
    test('rejects bad input', () {
      expect(parseHex('not-a-color'), isNull);
      expect(parseHex('#xyz'), isNull);
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail**

```bash
cd common && dart test test/services/dashboard/colors_test.dart
```

Expected: file not found.

- [ ] **Step 3: Implement `colors.dart`**

```dart
// common/lib/src/services/dashboard/colors.dart
import 'package:nocterm/nocterm.dart';

/// Resolve a manifest color string to a concrete nocterm [Color].
///
/// Accepts:
/// - Semantic names: `ok`, `warn`, `error`, `accent`, `muted`, `default`.
/// - `#rrggbb` hex strings (case-insensitive).
/// - `null` → default theme color (current foreground).
///
/// Unknown inputs fall back to the default; we do not throw, because a
/// plugin author's typo should not crash the dashboard.
Color resolveTileColor(String? name, {required Color accent}) {
  if (name == null) return _defaultColor;
  if (name.startsWith('#')) {
    final parsed = parseHex(name);
    if (parsed != null) return parsed;
    return _defaultColor;
  }
  switch (name) {
    case 'ok':      return _ok;
    case 'warn':    return _warn;
    case 'error':   return _error;
    case 'accent':  return accent;
    case 'muted':   return _muted;
    case 'default': return _defaultColor;
  }
  return _defaultColor;
}

/// Parses `#rrggbb`. Returns null if input is not a valid 6-digit hex.
Color? parseHex(String s) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(s)) return null;
  final n = int.parse(s.substring(1), radix: 16);
  return Color.fromARGB(255, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
}

const _ok           = Color.fromARGB(255, 0x4c, 0xaf, 0x50);
const _warn         = Color.fromARGB(255, 0xff, 0xa7, 0x26);
const _error        = Color.fromARGB(255, 0xef, 0x53, 0x50);
const _muted        = Color.fromARGB(255, 0x9e, 0x9e, 0x9e);
const _defaultColor = Color.fromARGB(255, 0xee, 0xee, 0xee);
```

- [ ] **Step 4: Run tests — confirm pass**

```bash
cd common && dart test test/services/dashboard/colors_test.dart
```

Expected: PASS.

- [ ] **Step 5: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): semantic color resolver for tile DSL

Maps manifest color strings (ok / warn / error / accent / muted /
default and #rrggbb hex) to nocterm Color values. Unknown inputs fall
back silently — a plugin author's typo should not crash the
dashboard.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Layout primitive data classes

**Files:**
- Create: `common/lib/src/services/dashboard/dsl/primitives.dart`
- Test: `common/test/services/dashboard/dsl/primitives_test.dart`

**Spec reference:** "Primitive registry (Phase 1)" table.

- [ ] **Step 1: Write failing tests**

```dart
// common/test/services/dashboard/dsl/primitives_test.dart
import 'package:common/src/services/dashboard/dsl/primitives.dart';
import 'package:test/test.dart';

void main() {
  group('Primitive.fromJson', () {
    test('Row', () {
      final p = Primitive.fromJson({
        'Row': {'label': 'Peers', 'value': {'\$data': 'peers'}},
      });
      expect(p, isA<Row>());
      expect((p as Row).label, 'Peers');
      expect(p.value, {'\$data': 'peers'});
    });

    test('StatusRow', () {
      final p = Primitive.fromJson({
        'StatusRow': {'label': 'Net', 'value': 'mainnet', 'color': 'ok'},
      });
      expect(p, isA<StatusRow>());
      expect((p as StatusRow).color, 'ok');
    });

    test('ProgressBar with default max', () {
      final p = Primitive.fromJson({
        'ProgressBar': {'label': 'Sync', 'value': {'\$data': 'p'}, 'format': 'percent'},
      });
      expect(p, isA<ProgressBar>());
      expect((p as ProgressBar).max, 1.0);
      expect(p.format, 'percent');
    });

    test('Section with nested children', () {
      final p = Primitive.fromJson({
        'Section': {
          'title': 'Wallet',
          'children': [
            {'Row': {'label': 'On-chain', 'value': '0'}},
          ],
        },
      });
      expect(p, isA<Section>());
      expect((p as Section).children.length, 1);
      expect(p.children.first, isA<Row>());
    });

    test('Spacer default height 1', () {
      final p = Primitive.fromJson({'Spacer': {}});
      expect(p, isA<Spacer>());
      expect((p as Spacer).height, 1);
    });

    test('Footer with text + color', () {
      final p = Primitive.fromJson({
        'Footer': {'text': 'synced', 'color': 'ok'},
      });
      expect(p, isA<Footer>());
      expect((p as Footer).text, 'synced');
    });

    test('Section rejects Footer in children', () {
      expect(
        () => Primitive.fromJson({
          'Section': {'children': [{'Footer': {'text': 'x'}}]},
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('unknown primitive throws', () {
      expect(
        () => Primitive.fromJson({'NotAThing': {}}),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('multiple keys at root throws', () {
      expect(
        () => Primitive.fromJson({'Row': {}, 'Spacer': {}}),
        throwsA(isA<TileManifestError>()),
      );
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail**

```bash
cd common && dart test test/services/dashboard/dsl/primitives_test.dart
```

- [ ] **Step 3: Implement `primitives.dart`**

```dart
// common/lib/src/services/dashboard/dsl/primitives.dart
import 'package:meta/meta.dart';

/// Thrown when a manifest JSON tree is malformed.
class TileManifestError implements Exception {
  final String message;
  TileManifestError(this.message);
  @override String toString() => 'TileManifestError: $message';
}

/// Parent type for all primitive nodes. JSON shape is a single-key map
/// whose key names the primitive and whose value is the args map.
@immutable
sealed class Primitive {
  const Primitive();

  factory Primitive.fromJson(Map<String, dynamic> json,
      {bool allowFooter = false}) {
    if (json.length != 1) {
      throw TileManifestError(
        'Primitive node must have exactly one key, got ${json.keys.toList()}',
      );
    }
    final name = json.keys.first;
    final args = (json.values.first as Map?)?.cast<String, dynamic>() ?? {};
    switch (name) {
      case 'Row':         return Row._fromJson(args);
      case 'StatusRow':   return StatusRow._fromJson(args);
      case 'ProgressBar': return ProgressBar._fromJson(args);
      case 'Section':     return Section._fromJson(args);
      case 'Spacer':      return Spacer._fromJson(args);
      case 'Footer':
        if (!allowFooter) {
          throw TileManifestError('Footer is only legal inside `footer:`');
        }
        return Footer._fromJson(args);
      default:
        throw TileManifestError('Unknown primitive: $name');
    }
  }
}

class Row extends Primitive {
  final String label;
  final dynamic value;          // literal, or a binding directive map
  final String? valueColor;
  Row({required this.label, required this.value, this.valueColor});
  factory Row._fromJson(Map<String, dynamic> a) {
    final label = a['label'];
    if (label is! String) {
      throw TileManifestError('Row.label is required (string)');
    }
    if (!a.containsKey('value')) {
      throw TileManifestError('Row.value is required');
    }
    return Row(label: label, value: a['value'], valueColor: a['value_color'] as String?);
  }
}

class StatusRow extends Primitive {
  final String label;
  final dynamic value;
  final dynamic color;          // literal or directive
  StatusRow({required this.label, required this.value, required this.color});
  factory StatusRow._fromJson(Map<String, dynamic> a) {
    final label = a['label'];
    if (label is! String) {
      throw TileManifestError('StatusRow.label is required (string)');
    }
    if (!a.containsKey('value') || !a.containsKey('color')) {
      throw TileManifestError('StatusRow requires value + color');
    }
    return StatusRow(label: label, value: a['value'], color: a['color']);
  }
}

class ProgressBar extends Primitive {
  final dynamic value;          // 0..1 if format=percent; current count if format=fraction/bytes
  final String? label;
  final double max;
  final String format;          // 'percent' | 'fraction' | 'bytes'
  final String? color;
  ProgressBar({
    required this.value,
    this.label,
    this.max = 1.0,
    this.format = 'percent',
    this.color,
  });
  factory ProgressBar._fromJson(Map<String, dynamic> a) {
    if (!a.containsKey('value')) {
      throw TileManifestError('ProgressBar.value is required');
    }
    final fmt = (a['format'] as String?) ?? 'percent';
    if (!const {'percent', 'fraction', 'bytes'}.contains(fmt)) {
      throw TileManifestError('ProgressBar.format must be percent|fraction|bytes');
    }
    return ProgressBar(
      value: a['value'],
      label: a['label'] as String?,
      max: ((a['max'] as num?) ?? 1.0).toDouble(),
      format: fmt,
      color: a['color'] as String?,
    );
  }
}

class Section extends Primitive {
  final String? title;
  final List<Primitive> children;
  Section({this.title, required this.children});
  factory Section._fromJson(Map<String, dynamic> a) {
    final raw = a['children'];
    if (raw is! List) {
      throw TileManifestError('Section.children must be a list');
    }
    final children = raw
        .cast<Map<String, dynamic>>()
        .map((j) => Primitive.fromJson(j))    // allowFooter defaults false
        .toList();
    return Section(title: a['title'] as String?, children: children);
  }
}

class Spacer extends Primitive {
  final int height;
  Spacer({this.height = 1});
  factory Spacer._fromJson(Map<String, dynamic> a) {
    final h = a['height'] as num?;
    return Spacer(height: h?.toInt() ?? 1);
  }
}

class Footer extends Primitive {
  final dynamic text;
  final dynamic color;
  Footer({required this.text, this.color});
  factory Footer._fromJson(Map<String, dynamic> a) {
    if (!a.containsKey('text')) {
      throw TileManifestError('Footer.text is required');
    }
    return Footer(text: a['text'], color: a['color']);
  }
}
```

- [ ] **Step 4: Run tests — confirm pass**

```bash
cd common && dart test test/services/dashboard/dsl/primitives_test.dart
```

- [ ] **Step 5: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): tile DSL primitive data classes

Six typed primitives (Row, StatusRow, ProgressBar, Section, Spacer,
Footer) plus JSON parsing and position validation. Footer is rejected
inside layout / Section.children; legal only in the manifest's
footer: block.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: TileManifest model + JSON parser

**Files:**
- Create: `common/lib/src/services/dashboard/dsl/tile_manifest.dart`
- Test: `common/test/services/dashboard/dsl/tile_manifest_test.dart`

**Spec reference:** "Tile manifest schema" section.

- [ ] **Step 1: Write failing tests**

```dart
// common/test/services/dashboard/dsl/tile_manifest_test.dart
import 'package:common/src/services/dashboard/dsl/primitives.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('TileManifest.fromJsonString', () {
    test('full round-trip', () {
      final m = TileManifest.fromJsonString('''
        {
          "id": "bitcoin",
          "title": "Bitcoin",
          "accent_color": "#f7931a",
          "layout": [
            {"Row": {"label": "Peers", "value": {"\$data": "peers"}}}
          ],
          "footer": {"Footer": {"text": "synced", "color": "ok"}}
        }
      ''');
      expect(m.id, 'bitcoin');
      expect(m.title, 'Bitcoin');
      expect(m.accentColor, '#f7931a');
      expect(m.layout.length, 1);
      expect(m.layout.first, isA<Row>());
      expect(m.footer, isNotNull);
    });

    test('layout-only manifest (no footer)', () {
      final m = TileManifest.fromJsonString('''
        {"id":"x","title":"X","layout":[{"Spacer":{}}]}
      ''');
      expect(m.footer, isNull);
    });

    test('rejects missing id', () {
      expect(
        () => TileManifest.fromJsonString('{"title":"X","layout":[]}'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => TileManifest.fromJsonString('not json'),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('footer can be a \$status directive (passes through opaque)', () {
      final m = TileManifest.fromJsonString('''
        {
          "id":"x","title":"X","layout":[],
          "footer":{"\$status":{"\$on":"sync_state","ok":{"Footer":{"text":"yes"}}}}
        }
      ''');
      expect(m.footer, isA<Map>());  // not parsed as Primitive at this stage
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail**

- [ ] **Step 3: Implement `tile_manifest.dart`**

```dart
// common/lib/src/services/dashboard/dsl/tile_manifest.dart
import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:common/src/services/dashboard/dsl/primitives.dart';

@immutable
class TileManifest {
  final String id;
  final String title;
  final String? accentColor;
  final List<Primitive> layout;

  /// Either a [Primitive] (Footer) or a Map containing a `\$status` directive.
  /// The renderer resolves directives at render time.
  final dynamic footer;

  const TileManifest({
    required this.id,
    required this.title,
    this.accentColor,
    required this.layout,
    this.footer,
  });

  factory TileManifest.fromJsonString(String s) {
    dynamic decoded;
    try {
      decoded = jsonDecode(s);
    } on FormatException catch (e) {
      throw TileManifestError('JSON parse failed: ${e.message}');
    }
    if (decoded is! Map) {
      throw TileManifestError('Manifest root must be an object');
    }
    return TileManifest.fromJson(decoded.cast<String, dynamic>());
  }

  factory TileManifest.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw TileManifestError('Manifest.id is required (non-empty string)');
    }
    final title = json['title'];
    if (title is! String) {
      throw TileManifestError('Manifest.title is required');
    }
    final layoutRaw = json['layout'];
    if (layoutRaw is! List) {
      throw TileManifestError('Manifest.layout must be a list');
    }
    final layout = layoutRaw
        .cast<Map<String, dynamic>>()
        .map((j) => Primitive.fromJson(j))
        .toList();

    dynamic footer;
    final f = json['footer'];
    if (f is Map) {
      // If the map has a single primitive key (Footer), parse it. Otherwise
      // leave it as a Map (likely a $status directive) for the renderer to
      // resolve later.
      final keys = f.keys.toList();
      if (keys.length == 1 && keys.first == 'Footer') {
        footer = Primitive.fromJson(f.cast<String, dynamic>(), allowFooter: true);
      } else {
        footer = f;
      }
    }

    return TileManifest(
      id: id,
      title: title,
      accentColor: json['accent_color'] as String?,
      layout: layout,
      footer: footer,
    );
  }
}
```

- [ ] **Step 4: Run tests — confirm pass + trio + commit**

```bash
cd common && dart test test/services/dashboard/dsl/tile_manifest_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): TileManifest model + JSON parser

Reads {id, title, accent_color, layout, footer} into a typed model.
Footer accepts either a Footer primitive directly or an unparsed Map
holding a \$status directive — the renderer resolves the latter at
render time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Binding directive resolver

**Files:**
- Create: `common/lib/src/services/dashboard/dsl/binding_resolver.dart`
- Test: `common/test/services/dashboard/dsl/binding_resolver_test.dart`

**Spec reference:** "Data binding language" section.

- [ ] **Step 1: Write failing tests covering all directives**

```dart
// common/test/services/dashboard/dsl/binding_resolver_test.dart
import 'package:common/src/services/dashboard/dsl/binding_resolver.dart';
import 'package:test/test.dart';

void main() {
  const data = {
    'blocks': 871234,
    'verification_progress': 0.99987,
    'size_on_disk': 543210000000,
    'uptime_sec': 90061,
    'pubkey': '03fffeeeddddccccbbbbaaaa999988887777666655554444333322221111',
    'sync_state': 'syncing',
    'sync_pct': 87,
  };

  group('resolveValue', () {
    test('literal passthrough', () {
      expect(resolveValue('hello', data), 'hello');
      expect(resolveValue(42, data), 42);
    });

    test('\$data with hit', () {
      expect(resolveValue({'\$data': 'blocks'}, data), 871234);
    });

    test('\$data with miss yields placeholder', () {
      expect(resolveValue({'\$data': 'nope'}, data), '—');
    });

    test('\$bytes formats human-readable', () {
      expect(resolveValue({'\$bytes': 'size_on_disk'}, data), '543.2 GB');
    });

    test('\$duration formats h/m/s', () {
      expect(resolveValue({'\$duration': 'uptime_sec'}, data), '1d 1h 1m');
    });

    test('\$pct formats 0..1 → percent', () {
      expect(resolveValue({'\$pct': 'verification_progress'}, data), '99.99%');
    });

    test('\$truncate', () {
      expect(
        resolveValue({'\$truncate': {'key': 'pubkey', 'len': 12}}, data),
        '03fffeeeddd…',
      );
    });

    test('\$format template', () {
      expect(
        resolveValue({'\$format': '{blocks} of {sync_pct}%'}, data),
        '871234 of 87%',
      );
    });

    test('\$status selects matching case', () {
      final result = resolveValue({
        '\$status': {
          '\$on': 'sync_state',
          'syncing': {'text': 'syncing', 'color': 'warn'},
          'synced':  {'text': 'synced',  'color': 'ok'},
        },
      }, data);
      expect(result, {'text': 'syncing', 'color': 'warn'});
    });

    test('\$status falls through to null when no case matches', () {
      final result = resolveValue({
        '\$status': {
          '\$on': 'sync_state',
          'unknown_value': {'text': 'x'},
        },
      }, data);
      expect(result, isNull);
    });
  });

  group('formatBytes', () {
    test('handles 0 / B / KB / MB / GB / TB', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(1500000), '1.5 MB');
      expect(formatBytes(2500000000), '2.5 GB');
      expect(formatBytes(3500000000000), '3.5 TB');
    });
  });

  group('formatDuration', () {
    test('seconds → days/hours/minutes', () {
      expect(formatDuration(0), '0m');
      expect(formatDuration(45), '0m');         // < 1m → 0m
      expect(formatDuration(90), '1m');
      expect(formatDuration(3700), '1h 1m');
      expect(formatDuration(90061), '1d 1h 1m');
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail**

- [ ] **Step 3: Implement `binding_resolver.dart`**

```dart
// common/lib/src/services/dashboard/dsl/binding_resolver.dart
import 'package:common/src/services/log_service.dart';

const _placeholder = '—';
final _missingKeyLogged = <String>{};   // dedupe per (tileId,key) — but tileId
                                         // isn't reachable here, so by key

/// Resolve a manifest value (literal, directive map, or list of literals)
/// against the per-tile [data] map.
dynamic resolveValue(dynamic node, Map<String, dynamic> data) {
  if (node is Map && node.length == 1 && (node.keys.first as String).startsWith('\$')) {
    final directive = node.keys.first;
    final arg = node.values.first;
    return _evalDirective(directive, arg, data);
  }
  return node;
}

dynamic _evalDirective(String directive, dynamic arg, Map<String, dynamic> data) {
  switch (directive) {
    case '\$data':
      return _lookup(arg as String, data) ?? _placeholder;
    case '\$bytes':
      final v = _lookup(arg as String, data);
      if (v is num) return formatBytes(v.toInt());
      return _placeholder;
    case '\$duration':
      final v = _lookup(arg as String, data);
      if (v is num) return formatDuration(v.toInt());
      return _placeholder;
    case '\$pct':
      final v = _lookup(arg as String, data);
      if (v is num) return '${(v * 100).toStringAsFixed(2)}%';
      return _placeholder;
    case '\$truncate':
      final spec = (arg as Map).cast<String, dynamic>();
      final s = _lookup(spec['key'] as String, data)?.toString();
      final len = (spec['len'] as num).toInt();
      if (s == null) return _placeholder;
      return s.length <= len ? s : '${s.substring(0, len - 1)}…';
    case '\$format':
      return _interpolate(arg as String, data);
    case '\$status':
      final spec = (arg as Map).cast<String, dynamic>();
      final on = spec['\$on'] as String;
      final v = _lookup(on, data)?.toString();
      if (v == null) return null;
      return spec[v];
    default:
      return _placeholder;
  }
}

dynamic _lookup(String key, Map<String, dynamic> data) {
  if (data.containsKey(key)) return data[key];
  if (_missingKeyLogged.add(key)) {
    LogService.warn('TileBinding: missing key "$key"');
  }
  return null;
}

String _interpolate(String template, Map<String, dynamic> data) {
  return template.replaceAllMapped(RegExp(r'\{([a-zA-Z0-9_]+)\}'), (m) {
    final key = m.group(1)!;
    final v = _lookup(key, data);
    return v?.toString() ?? _placeholder;
  });
}

/// Human-readable bytes. Uses 1000-base (network conventions); the
/// dashboard renders values like "5.4 GB" not "5.0 GiB".
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1000.0;
  var i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}

/// Human-readable seconds → "1d 2h 3m" / "5m" / "0m" (sub-minute is "0m").
String formatDuration(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h ${m}m';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
```

- [ ] **Step 4: Run tests — confirm pass + trio + commit**

```bash
cd common && dart test test/services/dashboard/dsl/binding_resolver_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): tile DSL binding directive resolver

Pure function evaluation of \$data / \$bytes / \$duration / \$pct /
\$truncate / \$format / \$status against per-tile data maps. Missing
keys render as "—" and log once.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: TileEventSource + Registry + TileDataCache + InProcessAdapterSource

**Files:**
- Create: `common/lib/src/services/dashboard/tile_event_source.dart`
- Create: `common/lib/src/services/dashboard/tile_event_source_registry.dart`
- Create: `common/lib/src/services/dashboard/tile_data_cache.dart`
- Create: `common/lib/src/services/dashboard/sources/in_process_adapter_source.dart`
- Test: `common/test/services/dashboard/tile_event_source_registry_test.dart`
- Test: `common/test/services/dashboard/tile_data_cache_test.dart`
- Test: `common/test/services/dashboard/sources/in_process_adapter_source_test.dart`

**Spec reference:** "TileEventSource contract" + "InProcessAdapterSource" sections.

- [ ] **Step 1: Define abstract `TileEventSource`**

```dart
// common/lib/src/services/dashboard/tile_event_source.dart
import 'package:common/src/services/dashboard/tile_event.dart';

abstract class TileEventSource {
  /// Stable identifier used in logs + the "no data — <id> not running"
  /// footer surfacing.
  String get id;

  /// Tile ids this source advertises. Advisory: events for tile ids
  /// outside this set are still accepted by the cache.
  Set<String> get providedTileIds;

  /// Begin emitting. Idempotent: calling twice after the first start is
  /// a no-op.
  Future<void> start();

  /// Broadcast stream of events. Errors propagate via [Stream.addError].
  Stream<TileEvent> get events;

  Future<void> dispose();
}
```

- [ ] **Step 2: Write failing tests for `TileEventSourceRegistry`**

```dart
// common/test/services/dashboard/tile_event_source_registry_test.dart
import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/dashboard/tile_event_source_registry.dart';
import 'package:test/test.dart';

class _Fake extends InProcessAdapterSource {
  _Fake(String id, Set<String> tileIds) : super(id: id, providedTileIds: tileIds);
}

void main() {
  group('TileEventSourceRegistry', () {
    test('register adds source', () {
      final r = TileEventSourceRegistry();
      final s = _Fake('a', {'x'});
      r.register(s);
      expect(r.sources, contains(s));
    });

    test('id collision throws', () {
      final r = TileEventSourceRegistry();
      r.register(_Fake('a', {'x'}));
      expect(() => r.register(_Fake('a', {'y'})), throwsA(isA<StateError>()));
    });

    test('startAll calls start on each source once', () async {
      final r = TileEventSourceRegistry();
      final s1 = _Fake('a', {'x'});
      final s2 = _Fake('b', {'y'});
      r.register(s1);
      r.register(s2);
      await r.startAll();
      expect(s1.started, isTrue);
      expect(s2.started, isTrue);
      // second startAll is a no-op
      s1.startedCount = 0;
      await r.startAll();
      expect(s1.startedCount, 0);
    });

    test('disposeAll clears state', () async {
      final r = TileEventSourceRegistry();
      final s = _Fake('a', {'x'});
      r.register(s);
      await r.disposeAll();
      expect(s.disposed, isTrue);
      expect(r.sources, isEmpty);
    });
  });
}
```

- [ ] **Step 3: Write failing tests for `TileDataCache`**

```dart
// common/test/services/dashboard/tile_data_cache_test.dart
import 'package:common/src/services/dashboard/tile_data_cache.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

void main() {
  group('TileDataCache', () {
    test('apply merges data by key', () {
      final c = TileDataCache();
      c.apply(TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)));
      c.apply(TileEvent(tileId: 'b', data: {'y': 2}, ts: DateTime.utc(2026, 5, 5)));
      expect(c.snapshotFor('b').data, {'x': 1, 'y': 2});
    });

    test('streamFor emits on every apply', () async {
      final c = TileDataCache();
      final events = <int>[];
      c.streamFor('b').listen((s) => events.add(s.data['x'] ?? -1));
      c.apply(TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)));
      c.apply(TileEvent(tileId: 'b', data: {'x': 2}, ts: DateTime.utc(2026, 5, 5)));
      await Future.delayed(Duration.zero);
      expect(events, [1, 2]);
    });

    test('applyError preserves data, sets lastError', () {
      final c = TileDataCache();
      c.apply(TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)));
      c.applyError('b', 'boom');
      final s = c.snapshotFor('b');
      expect(s.data, {'x': 1});
      expect(s.lastError, 'boom');
    });

    test('next successful apply clears lastError', () {
      final c = TileDataCache();
      c.applyError('b', 'boom');
      c.apply(TileEvent(tileId: 'b', data: {'x': 1}, ts: DateTime.utc(2026, 5, 5)));
      expect(c.snapshotFor('b').lastError, isNull);
    });
  });
}
```

- [ ] **Step 4: Write failing tests for `InProcessAdapterSource`**

```dart
// common/test/services/dashboard/sources/in_process_adapter_source_test.dart
import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

class _Concrete extends InProcessAdapterSource {
  _Concrete() : super(id: 'fake', providedTileIds: {'foo'});
  void emitForTest(TileEvent e) => emit(e);
  void emitErrorForTest(Object e, [StackTrace? st]) => emitError(e, st);
}

void main() {
  group('InProcessAdapterSource', () {
    test('emits events to listeners', () async {
      final s = _Concrete();
      await s.start();
      final got = <TileEvent>[];
      s.events.listen(got.add);
      s.emitForTest(TileEvent(tileId: 'foo', data: {'a': 1}, ts: DateTime.utc(2026,5,5)));
      await Future.delayed(Duration.zero);
      expect(got.length, 1);
      expect(got.first.data['a'], 1);
      await s.dispose();
    });

    test('emitError propagates on stream', () async {
      final s = _Concrete();
      await s.start();
      Object? err;
      s.events.listen((_) {}, onError: (e) { err = e; });
      s.emitErrorForTest('nope');
      await Future.delayed(Duration.zero);
      expect(err, 'nope');
      await s.dispose();
    });

    test('start is idempotent', () async {
      final s = _Concrete();
      await s.start();
      await s.start();   // does not throw
      await s.dispose();
    });
  });
}
```

- [ ] **Step 5: Implement `tile_event_source_registry.dart`**

```dart
// common/lib/src/services/dashboard/tile_event_source_registry.dart
import 'package:common/src/services/dashboard/tile_event_source.dart';
import 'package:common/src/services/log_service.dart';

class TileEventSourceRegistry {
  final List<TileEventSource> _sources = [];
  final Set<String> _ids = {};
  bool _started = false;

  Iterable<TileEventSource> get sources => List.unmodifiable(_sources);

  void register(TileEventSource source) {
    if (!_ids.add(source.id)) {
      throw StateError('Duplicate TileEventSource id: ${source.id}');
    }
    _sources.add(source);
    LogService.info('TileEventSource registered: ${source.id} '
        '(tiles: ${source.providedTileIds.join(", ")})');
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
      try { await s.dispose(); } catch (e, st) {
        LogService.warn('TileEventSource ${s.id} dispose error: $e\n$st');
      }
    }
    _sources.clear();
    _ids.clear();
    _started = false;
  }
}
```

- [ ] **Step 6: Implement `tile_data_cache.dart`**

```dart
// common/lib/src/services/dashboard/tile_data_cache.dart
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
```

- [ ] **Step 7: Implement `in_process_adapter_source.dart`**

```dart
// common/lib/src/services/dashboard/sources/in_process_adapter_source.dart
import 'dart:async';

import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/dashboard/tile_event_source.dart';

/// Transitional base class — sources implemented entirely in-process
/// (no subprocess). Used in Phase 1 by [BlitzApiBridgeSource]. Deleted
/// in Phase 4 when blitz-api becomes a plugin-shipped subprocess.
abstract class InProcessAdapterSource implements TileEventSource {
  @override final String id;
  @override final Set<String> providedTileIds;

  final StreamController<TileEvent> _ctrl = StreamController<TileEvent>.broadcast();
  bool started = false;
  int startedCount = 0;
  bool disposed = false;

  InProcessAdapterSource({
    required this.id,
    required this.providedTileIds,
  });

  @override
  Stream<TileEvent> get events => _ctrl.stream;

  @override
  Future<void> start() async {
    if (started) return;
    started = true;
    startedCount++;
    await onStart();
  }

  /// Subclass hook. Override to wire up the underlying source (e.g.
  /// open SSE, begin polling). Default is a no-op.
  Future<void> onStart() async {}

  /// Subclass hook for emitting events.
  void emit(TileEvent ev) {
    if (!_ctrl.isClosed) _ctrl.add(ev);
  }

  /// Subclass hook for emitting errors.
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

  /// Subclass hook for tearing down (cancel subscriptions, close
  /// connections, etc.). Default is a no-op.
  Future<void> onDispose() async {}
}
```

- [ ] **Step 8: Run all four test files — confirm pass**

```bash
cd common && dart test \
  test/services/dashboard/tile_event_source_registry_test.dart \
  test/services/dashboard/tile_data_cache_test.dart \
  test/services/dashboard/sources/in_process_adapter_source_test.dart
```

Expected: PASS.

- [ ] **Step 9: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): TileEventSource + Registry + TileDataCache

In-process source infrastructure for the new dashboard pipeline.
Registry rejects duplicate ids, calls start() once. TileDataCache
merges events by tileId and exposes per-tile broadcast streams; errors
are sticky until the next successful event.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: StreamerSubprocessSource

**Files:**
- Create: `common/lib/src/services/dashboard/sources/streamer_subprocess_source.dart`
- Create: `common/test/fixtures/streamers/echo_streamer.dart` (test fixture)
- Create: `common/test/fixtures/streamers/crashy_streamer.dart` (test fixture)
- Test: `common/test/services/dashboard/sources/streamer_subprocess_source_test.dart`

**Spec reference:** "StreamerSubprocessSource (the streamer protocol)" section.

- [ ] **Step 1: Write the test fixture streamers**

```dart
// common/test/fixtures/streamers/echo_streamer.dart
// Emits a fixed sequence of JSON-line events then exits cleanly.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  for (var i = 0; i < 3; i++) {
    stdout.writeln(jsonEncode({
      'tile': 'fix',
      'data': {'n': i},
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
    await Future.delayed(const Duration(milliseconds: 20));
  }
  // Optional: emit one malformed line to exercise the parser's drop path.
  stdout.writeln('this is not json');
  exit(0);
}
```

```dart
// common/test/fixtures/streamers/crashy_streamer.dart
// Emits one event then exits with code 1, to exercise restart logic.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  stdout.writeln(jsonEncode({
    'tile': 'fix',
    'data': {'attempt': int.parse(Platform.environment['ATTEMPT'] ?? '0')},
    'ts': DateTime.now().millisecondsSinceEpoch,
  }));
  await Future.delayed(const Duration(milliseconds: 20));
  exit(1);
}
```

- [ ] **Step 2: Write failing tests**

```dart
// common/test/services/dashboard/sources/streamer_subprocess_source_test.dart
import 'package:common/src/services/dashboard/sources/streamer_subprocess_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:test/test.dart';

void main() {
  group('StreamerSubprocessSource', () {
    test('happy path: spawns + parses JSON-lines + emits events', () async {
      final s = StreamerSubprocessSource(
        id: 'echo',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: ['test/fixtures/streamers/echo_streamer.dart'],
        backoff: const [],   // no backoff in tests
      );
      final got = <TileEvent>[];
      s.events.listen(got.add);
      await s.start();
      // Wait for the streamer to produce three events + exit
      await Future.delayed(const Duration(seconds: 1));
      expect(got.length, 3);
      expect(got.map((e) => e.data['n']), [0, 1, 2]);
      await s.dispose();
    });

    test('malformed line is dropped, not propagated', () async {
      final s = StreamerSubprocessSource(
        id: 'echo',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: ['test/fixtures/streamers/echo_streamer.dart'],
        backoff: const [],
      );
      final errs = <Object>[];
      s.events.listen((_) {}, onError: errs.add);
      await s.start();
      await Future.delayed(const Duration(seconds: 1));
      expect(errs, isEmpty);
      await s.dispose();
    });

    test('process exit triggers restart with backoff', () async {
      final s = StreamerSubprocessSource(
        id: 'crashy',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: ['test/fixtures/streamers/crashy_streamer.dart'],
        backoff: const [Duration(milliseconds: 50)],
      );
      final got = <TileEvent>[];
      s.events.listen(got.add);
      await s.start();
      // First start emits one event, exits, restarts after 50ms,
      // emits another event. Allow ~500ms.
      await Future.delayed(const Duration(milliseconds: 500));
      expect(got.length, greaterThanOrEqualTo(2));
      await s.dispose();
    });

    test('crash-loop after 3 restarts in 60s emits sticky error', () async {
      final s = StreamerSubprocessSource(
        id: 'crashy',
        providedTileIds: const {'fix'},
        command: 'dart',
        args: ['test/fixtures/streamers/crashy_streamer.dart'],
        backoff: const [Duration(milliseconds: 10)],
        crashLoopThreshold: 3,
        crashLoopWindow: const Duration(seconds: 60),
      );
      Object? err;
      s.events.listen((_) {}, onError: (e) { err = e; });
      await s.start();
      await Future.delayed(const Duration(milliseconds: 500));
      expect(err, isA<StreamerCrashLoopError>());
      await s.dispose();
    });

    test('dispose terminates the child', () async {
      final s = StreamerSubprocessSource(
        id: 'echo',
        providedTileIds: const {'fix'},
        command: 'sleep',
        args: ['60'],
        backoff: const [],
      );
      await s.start();
      await Future.delayed(const Duration(milliseconds: 100));
      await s.dispose();
      // If dispose hangs, test framework times out — that's the assertion.
    });
  });
}
```

- [ ] **Step 3: Run tests — confirm fail**

```bash
cd common && dart test test/services/dashboard/sources/streamer_subprocess_source_test.dart
```

- [ ] **Step 4: Implement `streamer_subprocess_source.dart`**

```dart
// common/lib/src/services/dashboard/sources/streamer_subprocess_source.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/dashboard/tile_event_source.dart';
import 'package:common/src/services/log_service.dart';

class StreamerCrashLoopError implements Exception {
  final String streamerId;
  final int restarts;
  StreamerCrashLoopError(this.streamerId, this.restarts);
  @override String toString() =>
      'streamer crash-looping ($restarts restarts) — see log';
}

class StreamerSubprocessSource implements TileEventSource {
  @override final String id;
  @override final Set<String> providedTileIds;

  final String command;
  final List<String> args;
  final Map<String, String>? environmentOverride;
  final List<Duration> backoff;
  final int crashLoopThreshold;
  final Duration crashLoopWindow;
  final int maxLineLength;

  final StreamController<TileEvent> _ctrl = StreamController.broadcast();
  Process? _proc;
  bool _started = false;
  bool _disposed = false;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final List<DateTime> _restartTs = [];

  StreamerSubprocessSource({
    required this.id,
    required this.providedTileIds,
    required this.command,
    required this.args,
    this.environmentOverride,
    this.backoff = const [Duration(seconds: 1), Duration(seconds: 2),
        Duration(seconds: 5), Duration(seconds: 10), Duration(seconds: 30)],
    this.crashLoopThreshold = 3,
    this.crashLoopWindow = const Duration(seconds: 60),
    this.maxLineLength = 64 * 1024,
  });

  @override
  Stream<TileEvent> get events => _ctrl.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    unawaited(_runLoop());
  }

  Future<void> _runLoop() async {
    var attempt = 0;
    while (!_disposed) {
      try {
        await _spawnAndPipe();
      } catch (e, st) {
        LogService.warn('streamer "$id" run failed: $e\n$st');
      }
      if (_disposed) return;

      // Crash-loop detection: count restarts within the window.
      final now = DateTime.now();
      _restartTs.add(now);
      _restartTs.removeWhere((t) => now.difference(t) > crashLoopWindow);
      if (_restartTs.length >= crashLoopThreshold) {
        if (!_ctrl.isClosed) {
          _ctrl.addError(StreamerCrashLoopError(id, _restartTs.length));
        }
        // Don't return — keep retrying, but the sticky error is now in
        // the cache. Wait the longest backoff to slow things down.
        await Future.delayed(backoff.isEmpty
            ? const Duration(seconds: 30)
            : backoff.last);
        continue;
      }

      final wait = backoff.isEmpty
          ? Duration.zero
          : backoff[attempt.clamp(0, backoff.length - 1)];
      attempt++;
      if (wait != Duration.zero) await Future.delayed(wait);
    }
  }

  Future<void> _spawnAndPipe() async {
    final env = environmentOverride ??
        {'PATH': Platform.environment['PATH'] ?? '', 'LANG': 'C.UTF-8'};
    _proc = await Process.start(command, args,
        environment: env, includeParentEnvironment: false);

    final firstEventCompleter = Completer<void>();

    _stdoutSub = _proc!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.length > maxLineLength) {
        LogService.warn('streamer "$id": dropped over-long line '
            '(${line.length} bytes)');
        return;
      }
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final ev = TileEvent(
          tileId: json['tile'] as String,
          data: ((json['data'] as Map?) ?? const {}).cast<String, dynamic>(),
          ts: DateTime.fromMillisecondsSinceEpoch(
              (json['ts'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch),
        );
        if (!_ctrl.isClosed) _ctrl.add(ev);
        if (!firstEventCompleter.isCompleted) firstEventCompleter.complete();
      } catch (e) {
        LogService.warn('streamer "$id": malformed line dropped: $e');
      }
    });

    _stderrSub = _proc!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => LogService.warn('streamer "$id" stderr: $line'));

    final exitCode = await _proc!.exitCode;
    LogService.info('streamer "$id" exited (code $exitCode)');

    // Reset restart-window counter on successful start, but only
    // after the first event arrived (otherwise a streamer that
    // exits before any event still counts as a crash).
    if (firstEventCompleter.isCompleted) _restartTs.clear();

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _proc = null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final p = _proc;
    if (p != null) {
      p.kill(ProcessSignal.sigterm);
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
        await p.exitCode;
      }
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}
```

- [ ] **Step 5: Run tests — confirm pass + trio + commit**

```bash
cd common && dart test test/services/dashboard/sources/streamer_subprocess_source_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): StreamerSubprocessSource

Spawns a long-lived child process and parses its stdout as
line-delimited JSON. Restarts with backoff [1,2,5,10,30]s on exit;
flags a crash-loop after 3 restarts within 60s. SIGTERM with 2s grace
then SIGKILL on dispose. Stderr drains to log.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: BlitzApiBridgeSource

**Files:**
- Create: `common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart`
- Test: `common/test/services/dashboard/sources/blitz_api_bridge_source_test.dart`
- Read for reference: `common/lib/src/services/dashboard/api_dashboard_source.dart` (the SSE-event → snapshot logic that needs porting)
- Read for reference: `common/lib/src/services/blitz_api/blitz_api_client.dart`
- Read for reference: `common/lib/src/services/blitz_api/sse_event.dart`

**Spec reference:** "blitz-api-bridge (in-process adapter, transitional)" section.

- [ ] **Step 1: Write failing tests**

```dart
// common/test/services/dashboard/sources/blitz_api_bridge_source_test.dart
import 'dart:async';

import 'package:common/src/services/blitz_api/sse_event.dart';
import 'package:common/src/services/dashboard/sources/blitz_api_bridge_source.dart';
import 'package:test/test.dart';

void main() {
  group('BlitzApiBridgeSource', () {
    test('btc_info SSE event → bitcoin TileEvent', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      await s.start();
      final got = <Map<String, dynamic>>[];
      s.events.listen((ev) => got.add({'tile': ev.tileId, 'data': ev.data}));

      clientEvents.add(SseEvent(
        type: 'btc_info',
        data: {'blocks': 100, 'verification_progress': 0.99},
      ));
      await Future.delayed(Duration.zero);

      expect(got.length, 1);
      expect(got.first['tile'], 'bitcoin');
      expect((got.first['data'] as Map)['blocks'], 100);

      await s.dispose();
      await clientEvents.close();
    });

    test('ln_info SSE event → lightning TileEvent', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      await s.start();
      final got = <String>[];
      s.events.listen((ev) => got.add(ev.tileId));

      clientEvents.add(SseEvent(
        type: 'ln_info',
        data: {'identity_pubkey': 'abc', 'alias': 'node'},
      ));
      await Future.delayed(Duration.zero);

      expect(got, ['lightning']);
      await s.dispose();
      await clientEvents.close();
    });

    test('client error propagates as stream error', () async {
      final clientEvents = StreamController<SseEvent>.broadcast();
      final s = BlitzApiBridgeSource.forTest(
        eventsStream: clientEvents.stream,
        startCallback: () async {},
        disposeCallback: () async {},
      );
      await s.start();
      Object? err;
      s.events.listen((_) {}, onError: (e) { err = e; });
      clientEvents.addError('boom');
      await Future.delayed(Duration.zero);
      expect(err, 'boom');
      await s.dispose();
      await clientEvents.close();
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail**

- [ ] **Step 3: Implement `blitz_api_bridge_source.dart`**

```dart
// common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart
import 'dart:async';

import 'package:common/src/services/blitz_api/blitz_api_client.dart';
import 'package:common/src/services/blitz_api/sse_event.dart';
import 'package:common/src/services/dashboard/sources/in_process_adapter_source.dart';
import 'package:common/src/services/dashboard/tile_event.dart';

/// In-process adapter that wraps [BlitzApiClient] and translates SSE
/// events into [TileEvent]s for the bitcoin + lightning tiles.
///
/// Phase 1 transitional. In Phase 4 the same translation logic ships
/// inside the blitz-api plugin's subprocess streamer, this class is
/// deleted, and [InProcessAdapterSource] goes away with it.
class BlitzApiBridgeSource extends InProcessAdapterSource {
  final BlitzApiClient? _client;
  final Stream<SseEvent> _eventsStream;
  final Future<void> Function() _onStart;
  final Future<void> Function() _onDispose;
  StreamSubscription<SseEvent>? _sub;

  BlitzApiBridgeSource()
      : this._(BlitzApiClient());

  BlitzApiBridgeSource._(BlitzApiClient client)
      : _client = client,
        _eventsStream = client.events,
        _onStart = client.start,
        _onDispose = client.dispose,
        super(id: 'blitz-api-bridge', providedTileIds: const {'bitcoin', 'lightning'});

  /// Test seam: inject a stream + lifecycle hooks without spinning up
  /// a real BlitzApiClient.
  factory BlitzApiBridgeSource.forTest({
    required Stream<SseEvent> eventsStream,
    required Future<void> Function() startCallback,
    required Future<void> Function() disposeCallback,
  }) {
    return BlitzApiBridgeSource.__(
      eventsStream: eventsStream,
      onStart: startCallback,
      onDispose: disposeCallback,
    );
  }

  BlitzApiBridgeSource.__({
    required Stream<SseEvent> eventsStream,
    required Future<void> Function() onStart,
    required Future<void> Function() onDispose,
  })  : _client = null,
        _eventsStream = eventsStream,
        _onStart = onStart,
        _onDispose = onDispose,
        super(id: 'blitz-api-bridge', providedTileIds: const {'bitcoin', 'lightning'});

  @override
  Future<void> onStart() async {
    await _onStart();
    _sub = _eventsStream.listen(_handleSse, onError: emitError);
  }

  void _handleSse(SseEvent e) {
    switch (e.type) {
      case 'btc_info':
      case 'btc_mempool_status':
        emit(TileEvent(tileId: 'bitcoin', data: e.data, ts: DateTime.now()));
        break;
      case 'ln_info':
      case 'wallet_balance':
        emit(TileEvent(tileId: 'lightning', data: e.data, ts: DateTime.now()));
        break;
      // Other event types: ignored. Phase 1 only routes the four the
      // current tiles consumed.
    }
  }

  @override
  Future<void> onDispose() async {
    await _sub?.cancel();
    _sub = null;
    await _onDispose();
  }
}
```

- [ ] **Step 4: Run tests — confirm pass + trio + commit**

```bash
cd common && dart test test/services/dashboard/sources/blitz_api_bridge_source_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): BlitzApiBridgeSource

In-process adapter wrapping BlitzApiClient. Translates btc_info /
btc_mempool_status / ln_info / wallet_balance SSE events into
TileEvents for the bitcoin + lightning tiles. Transitional — Phase 4
replaces this with a plugin-shipped subprocess streamer and deletes
this class plus InProcessAdapterSource.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: system-stats streamer

**Files:**
- Create: `common/lib/src/streamers/system_stats_streamer.dart`
- Create: `common/lib/src/streamers/system_stats_readers.dart`
- Test: `common/test/streamers/system_stats_readers_test.dart`

**Spec reference:** "system-stats (real subprocess streamer)" section.

- [ ] **Step 1: Write failing tests for the readers (pure parsing)**

```dart
// common/test/streamers/system_stats_readers_test.dart
import 'package:common/src/streamers/system_stats_readers.dart';
import 'package:test/test.dart';

void main() {
  group('parseProcStatCpu', () {
    test('extracts the aggregate cpu line', () {
      const sample = '''
cpu  100 50 200 10000 0 0 0 0 0 0
cpu0 50 25 100 5000 0 0 0 0 0 0
intr 12345
''';
      final s = parseProcStatCpu(sample);
      expect(s.user, 100);
      expect(s.idle, 10000);
      expect(s.total, 100 + 50 + 200 + 10000);
    });
  });

  group('cpuPercent', () {
    test('idle delta of 90 over total 100 → 10%', () {
      final a = CpuTimes(user: 0, system: 0, idle: 0, total: 0);
      final b = CpuTimes(user: 5, system: 5, idle: 90, total: 100);
      expect(cpuPercent(a, b), closeTo(10.0, 0.01));
    });
  });

  group('parseProcMeminfo', () {
    test('extracts MemTotal / MemAvailable', () {
      const sample = '''
MemTotal:        8192000 kB
MemFree:         1024000 kB
MemAvailable:    4096000 kB
Buffers:          512000 kB
''';
      final m = parseProcMeminfo(sample);
      expect(m.totalBytes, 8192000 * 1024);
      expect(m.availableBytes, 4096000 * 1024);
      expect(m.usedBytes, (8192000 - 4096000) * 1024);
    });
  });

  group('parseProcUptime', () {
    test('first field as seconds', () {
      expect(parseProcUptime('12345.67 9876.54'), 12345);
    });
  });

  group('parseTemperatureMilliC', () {
    test('45000 → 45.0 C', () {
      expect(parseTemperatureMilliC('45000\n'), closeTo(45.0, 0.01));
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail**

- [ ] **Step 3: Implement `system_stats_readers.dart`**

```dart
// common/lib/src/streamers/system_stats_readers.dart
class CpuTimes {
  final int user, system, idle, total;
  const CpuTimes({required this.user, required this.system,
      required this.idle, required this.total});
}

CpuTimes parseProcStatCpu(String s) {
  final line = s.split('\n').firstWhere((l) => l.startsWith('cpu '),
      orElse: () => '');
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length < 5) {
    return const CpuTimes(user: 0, system: 0, idle: 0, total: 0);
  }
  // user nice system idle iowait irq softirq steal guest guestnice
  int p(int i) => i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0;
  final user = p(1) + p(2);
  final system = p(3);
  final idle = p(4) + p(5);   // idle + iowait
  final total = [for (var i = 1; i < parts.length; i++) p(i)].fold(0, (a, b) => a + b);
  return CpuTimes(user: user, system: system, idle: idle, total: total);
}

double cpuPercent(CpuTimes a, CpuTimes b) {
  final dTotal = b.total - a.total;
  final dIdle = b.idle - a.idle;
  if (dTotal <= 0) return 0;
  return ((dTotal - dIdle) * 100.0) / dTotal;
}

class MemInfo {
  final int totalBytes, availableBytes, usedBytes;
  const MemInfo({required this.totalBytes, required this.availableBytes,
      required this.usedBytes});
}

MemInfo parseProcMeminfo(String s) {
  int? read(String key) {
    for (final line in s.split('\n')) {
      if (line.startsWith('$key:')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          final n = int.tryParse(parts[1]) ?? 0;
          return n * 1024;   // kB → bytes
        }
      }
    }
    return null;
  }
  final total = read('MemTotal') ?? 0;
  final avail = read('MemAvailable') ?? 0;
  return MemInfo(totalBytes: total, availableBytes: avail, usedBytes: total - avail);
}

int parseProcUptime(String s) {
  final first = s.trim().split(RegExp(r'\s+')).firstOrNull;
  return double.tryParse(first ?? '')?.toInt() ?? 0;
}

double? parseTemperatureMilliC(String s) {
  final n = int.tryParse(s.trim());
  return n == null ? null : n / 1000.0;
}
```

- [ ] **Step 4: Run reader tests — confirm pass**

- [ ] **Step 5: Implement `system_stats_streamer.dart` main entry**

```dart
// common/lib/src/streamers/system_stats_streamer.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/streamers/system_stats_readers.dart';

/// Entry point invoked via `nixblitz streamer system-stats`. Reads
/// procfs/sysfs and emits TileEvent JSON-lines on stdout for the
/// hardware + system tiles.
///
/// Args:
///   --units a,b,c   comma-separated list of systemd units to poll
///                   for is-active state. Empty = no service map.
Future<void> systemStatsMain(List<String> args) async {
  final units = _parseUnitsArg(args);

  // Hardware: every 2s. System: every 5s.
  Timer.periodic(const Duration(seconds: 2), (_) async {
    final ev = await _readHardware();
    _emit('hardware', ev);
  });
  Timer.periodic(const Duration(seconds: 5), (_) async {
    final ev = await _readSystem(units);
    _emit('system', ev);
  });

  // Emit once immediately so the UI populates fast.
  _emit('hardware', await _readHardware());
  _emit('system', await _readSystem(units));

  // Block forever (until parent SIGTERMs us).
  await Completer<void>().future;
}

List<String> _parseUnitsArg(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--units' && i + 1 < args.length) {
      return args[i + 1].split(',').where((s) => s.isNotEmpty).toList();
    }
  }
  return const [];
}

CpuTimes _lastCpu = const CpuTimes(user: 0, system: 0, idle: 0, total: 0);

Future<Map<String, dynamic>> _readHardware() async {
  final stat = await File('/proc/stat').readAsString();
  final cur = parseProcStatCpu(stat);
  final pct = cpuPercent(_lastCpu, cur);
  _lastCpu = cur;

  final meminfo = await File('/proc/meminfo').readAsString();
  final mem = parseProcMeminfo(meminfo);

  double? tempC;
  final tempFile = File('/sys/class/thermal/thermal_zone0/temp');
  if (tempFile.existsSync()) {
    try { tempC = parseTemperatureMilliC(await tempFile.readAsString()); }
    catch (_) {}
  }

  // Disk usage on /mnt/data (or / fallback).
  final diskMount = Directory('/mnt/data').existsSync() ? '/mnt/data' : '/';
  final df = await Process.run('df', ['-B1', diskMount]);
  int diskUsed = 0, diskTotal = 0;
  if (df.exitCode == 0) {
    final lines = (df.stdout as String).split('\n');
    if (lines.length >= 2) {
      final parts = lines[1].split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        diskTotal = int.tryParse(parts[1]) ?? 0;
        diskUsed = int.tryParse(parts[2]) ?? 0;
      }
    }
  }

  return {
    'cpu_percent': pct,
    'mem_used_bytes': mem.usedBytes,
    'mem_total_bytes': mem.totalBytes,
    'temperature_c': tempC,
    'disk_used_bytes': diskUsed,
    'disk_total_bytes': diskTotal,
    'disk_mount': diskMount,
  };
}

Future<Map<String, dynamic>> _readSystem(List<String> units) async {
  final uptime = parseProcUptime(await File('/proc/uptime').readAsString());
  final services = <String, String>{};
  for (final unit in units) {
    final r = await Process.run('systemctl', ['is-active', unit]);
    services[unit] = (r.stdout as String).trim();
  }
  return {
    'uptime_sec': uptime,
    'services': services,
  };
}

void _emit(String tile, Map<String, dynamic> data) {
  stdout.writeln(jsonEncode({
    'tile': tile,
    'data': data,
    'ts': DateTime.now().millisecondsSinceEpoch,
  }));
}
```

- [ ] **Step 6: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): system-stats streamer

Standalone procfs/sysfs reader entry-point. Emits hardware (2s) and
system (5s) TileEvents on stdout as JSON-lines. Reads /proc/stat,
/proc/meminfo, /proc/uptime, /sys/class/thermal/thermal_zone0/temp
(best-effort), and df on /mnt/data (or /). systemctl is-active polled
for each --units entry. No blitz-api dependency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Wire `nixblitz streamer <name>` argv dispatch

**Files:**
- Modify: `tui/bin/nixblitz.dart`

**Spec reference:** "system-stats (real subprocess streamer)" — single binary, hidden subcommand.

- [ ] **Step 1: Read `tui/bin/nixblitz.dart` to understand current argv handling**

Run: `cat tui/bin/nixblitz.dart`

- [ ] **Step 2: Modify the entry point**

Add an argv check before the TUI launch path. Place it as early as possible — before runZonedGuarded / nocterm setup.

```dart
// At the top of `main` in tui/bin/nixblitz.dart, before the TUI
// initialisation block:

import 'package:common/src/streamers/system_stats_streamer.dart';

// inside main(...):
if (args.isNotEmpty && args.first == 'streamer') {
  if (args.length < 2) {
    stderr.writeln('usage: nixblitz streamer <name> [args...]');
    exit(2);
  }
  final name = args[1];
  final streamerArgs = args.skip(2).toList();
  switch (name) {
    case 'system-stats':
      await systemStatsMain(streamerArgs);
      return;
    default:
      stderr.writeln('unknown streamer: $name');
      exit(2);
  }
}
```

(Adapt to the existing argv handling in the file; the help command added previously also lives here. The streamer dispatch should run BEFORE help / TUI startup.)

- [ ] **Step 3: Manual smoke**

```bash
just run
# (in another terminal)
dart run tui/bin/nixblitz.dart streamer system-stats --units nixblitz
# Expect JSON-lines on stdout, ~1 per second.
```

- [ ] **Step 4: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(tui): nixblitz streamer <name> argv dispatch

Hidden subcommand routes to a streamer entry point and skips TUI
startup. system-stats is the only streamer in Phase 1; future
streamers add a case to the switch. Same binary, no extra build
artifact.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Bundled tile manifests

**Files:**
- Create: `common/lib/src/services/dashboard/bundled/manifests/bitcoin.json`
- Create: `common/lib/src/services/dashboard/bundled/manifests/lightning.json`
- Create: `common/lib/src/services/dashboard/bundled/manifests/hardware.json`
- Create: `common/lib/src/services/dashboard/bundled/manifests/system.json`
- Test: `common/test/services/dashboard/bundled/manifests_test.dart`

**Spec reference:** "Bundled tile providers" → manifests subsection.

- [ ] **Step 1: Write `bitcoin.json`**

```json
{
  "id": "bitcoin",
  "title": "Bitcoin",
  "accent_color": "#f7931a",
  "layout": [
    {"StatusRow":   {"label": "Network",  "value": {"$data": "chain_name"}, "color": {"$data": "chain_color"}}},
    {"ProgressBar": {"label": "Sync",     "value": {"$data": "verification_progress"}, "format": "percent"}},
    {"Row":         {"label": "Blocks",   "value": {"$format": "{blocks}/{headers}"}}},
    {"Row":         {"label": "Peers",    "value": {"$data": "peers"}}},
    {"Row":         {"label": "Disk",     "value": {"$bytes": "size_on_disk"}}},
    {"Row":         {"label": "Mempool",  "value": {"$format": "{mempool_txs} txs"}}}
  ],
  "footer": {
    "$status": {
      "$on": "sync_state",
      "synced":  {"Footer": {"text": "synced", "color": "ok"}},
      "syncing": {"Footer": {"text": "syncing", "color": "warn"}},
      "stalled": {"Footer": {"text": "stalled", "color": "error"}}
    }
  }
}
```

- [ ] **Step 2: Write `lightning.json`**

```json
{
  "id": "lightning",
  "title": "Lightning",
  "accent_color": "#9b6cf2",
  "layout": [
    {"Row":       {"label": "Alias",    "value": {"$data": "alias"}}},
    {"Row":       {"label": "Pubkey",   "value": {"$truncate": {"key": "pubkey", "len": 12}}}},
    {"StatusRow": {"label": "Synced",   "value": {"$data": "synced_label"}, "color": {"$data": "synced_color"}}},
    {"Row":       {"label": "Channels", "value": {"$format": "{active}/{pending}"}}},
    {"Row":       {"label": "Peers",    "value": {"$data": "peers"}}},
    {"Row":       {"label": "On-chain", "value": {"$format": "{onchain_sats} sat"}}},
    {"Row":       {"label": "In-channel", "value": {"$format": "{channel_sats} sat"}}}
  ]
}
```

- [ ] **Step 3: Write `hardware.json`**

```json
{
  "id": "hardware",
  "title": "Hardware",
  "accent_color": "#4caf50",
  "layout": [
    {"ProgressBar": {"label": "CPU",  "value": {"$data": "cpu_percent"}, "max": 100, "format": "percent"}},
    {"ProgressBar": {"label": "Mem",  "value": {"$data": "mem_used_bytes"}, "max": 1, "format": "bytes"}},
    {"ProgressBar": {"label": "Disk", "value": {"$data": "disk_used_bytes"}, "max": 1, "format": "bytes"}},
    {"Row":         {"label": "Temp", "value": {"$format": "{temperature_c}°C"}}}
  ]
}
```

(The `bytes` format on ProgressBar takes the value and the data's `*_total_bytes` companion to compute the bar position; renderer task implements this.)

- [ ] **Step 4: Write `system.json`**

```json
{
  "id": "system",
  "title": "System",
  "accent_color": "#607d8b",
  "streamer_args": ["--units", "blitz-api,blitz-web,nginx,redis"],
  "layout": [
    {"Row": {"label": "Uptime", "value": {"$duration": "uptime_sec"}}},
    {"Section": {
      "title": "Services",
      "children": [
        {"StatusRow": {"label": "blitz-api", "value": {"$data": "services.blitz-api"}, "color": {"$status": {"$on": "services.blitz-api", "active": "ok", "inactive": "muted", "failed": "error"}}}},
        {"StatusRow": {"label": "blitz-web", "value": {"$data": "services.blitz-web"}, "color": {"$status": {"$on": "services.blitz-web", "active": "ok", "inactive": "muted", "failed": "error"}}}},
        {"StatusRow": {"label": "nginx",     "value": {"$data": "services.nginx"},     "color": {"$status": {"$on": "services.nginx",     "active": "ok", "inactive": "muted", "failed": "error"}}}},
        {"StatusRow": {"label": "redis",     "value": {"$data": "services.redis"},     "color": {"$status": {"$on": "services.redis",     "active": "ok", "inactive": "muted", "failed": "error"}}}}
      ]
    }}
  ]
}
```

(`services.<name>` notation is dot-path lookup; binding resolver Task 5 already handles flat keys, so the renderer Task 12 needs to flatten `services` map into `services.<name>` keys when applying the snapshot. Or the streamer can emit them flat directly. Streamer-flat is simpler — see Task 9 step 5 update below.)

- [ ] **Step 5: Update `system_stats_streamer.dart` to flatten services**

Replace the `services` block in `_readSystem` with:

```dart
final result = {'uptime_sec': uptime};
for (final unit in units) {
  final r = await Process.run('systemctl', ['is-active', unit]);
  result['services.$unit'] = (r.stdout as String).trim();
}
return result;
```

- [ ] **Step 6: Write a manifest validation test**

```dart
// common/test/services/dashboard/bundled/manifests_test.dart
import 'dart:io';

import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:test/test.dart';

void main() {
  for (final name in ['bitcoin', 'lightning', 'hardware', 'system']) {
    test('$name.json parses', () {
      final s = File('lib/src/services/dashboard/bundled/manifests/$name.json')
          .readAsStringSync();
      expect(() => TileManifest.fromJsonString(s), returnsNormally);
    });
  }
}
```

- [ ] **Step 7: Run tests + trio + commit**

```bash
cd common && dart test test/services/dashboard/bundled/manifests_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): bundled tile manifests for the four core tiles

Bitcoin, lightning, hardware, system manifests express today's tile
UX in the new DSL. Hardware uses the system-stats streamer (no
blitz-api dependency); bitcoin/lightning still flow through
blitz-api-bridge. system.json declares streamer_args to pin the unit
list passed to system-stats.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Embed manifests + bundled registry

**Files:**
- Create: `scripts/gen_dashboard_manifests.dart`
- Create: `common/lib/src/services/dashboard/bundled/embedded_manifests.dart`
- Create: `common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart` (generated)
- Create: `common/lib/src/services/dashboard/bundled/registry.dart`
- Modify: `justfile` — add `gen-manifests` recipe
- Read for reference: `scripts/gen_embedded_templates.dart` (mirror its structure)
- Test: `common/test/services/dashboard/bundled/registry_test.dart`

**Spec reference:** "Bundled manifests are JSON files" decision; mirrors `EmbeddedTemplates` pattern.

- [ ] **Step 1: Read the existing template generator**

```bash
cat scripts/gen_embedded_templates.dart
```

- [ ] **Step 2: Write `gen_dashboard_manifests.dart` mirroring it**

```dart
// scripts/gen_dashboard_manifests.dart
import 'dart:io';

void main() {
  final dir = Directory('common/lib/src/services/dashboard/bundled/manifests');
  final files = dir.listSync().whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final out = StringBuffer()
    ..writeln("// GENERATED — do not edit. Run 'just gen-manifests' to regenerate.")
    ..writeln("// Source: common/lib/src/services/dashboard/bundled/manifests/")
    ..writeln()
    ..writeln("part of 'embedded_manifests.dart';")
    ..writeln();

  final names = <String>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last.replaceAll('.json', '');
    names.add(name);
    final content = f.readAsStringSync();
    out
      ..writeln("const String _${name}Json = r'''")
      ..write(content)
      ..writeln("''';")
      ..writeln();
  }

  out
    ..writeln('const Map<String, String> _allManifests = {')
    ..writeAll(names.map((n) => "  '$n': _${n}Json,"), '\n')
    ..writeln()
    ..writeln('};');

  File('common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart')
      .writeAsStringSync(out.toString());
  stdout.writeln('Wrote embedded_manifests.g.dart with ${files.length} manifests');
}
```

- [ ] **Step 3: Write `embedded_manifests.dart` (the `part of` host)**

```dart
// common/lib/src/services/dashboard/bundled/embedded_manifests.dart
library;

part 'embedded_manifests.g.dart';

class EmbeddedManifests {
  /// All manifests as raw JSON strings, keyed by manifest name (filename
  /// without extension).
  static Map<String, String> getAll() => Map.unmodifiable(_allManifests);
}
```

- [ ] **Step 4: Add justfile recipe**

```make
# Regenerate embedded dashboard manifests from bundled/manifests/
gen-manifests:
  dart run scripts/gen_dashboard_manifests.dart
```

- [ ] **Step 5: Run the generator**

```bash
just gen-manifests
```

Expected: writes `common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart` with four `_<name>Json` constants and a `_allManifests` map.

- [ ] **Step 6: Write `registry.dart`**

```dart
// common/lib/src/services/dashboard/bundled/registry.dart
import 'package:common/src/services/dashboard/bundled/embedded_manifests.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';

/// Manifests bundled in the TUI binary. In Phase 4 this list is
/// extended at startup to include manifests shipped by installed
/// plugins; the renderer doesn't care about the source.
List<TileManifest> get bundledManifests {
  final raw = EmbeddedManifests.getAll();
  // Stable order: alphabetical by id. Matches existing tile order in
  // dashboard_view.dart: bitcoin, hardware, lightning, system.
  final list = raw.values.map(TileManifest.fromJsonString).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(list);
}
```

- [ ] **Step 7: Write `registry_test.dart`**

```dart
// common/test/services/dashboard/bundled/registry_test.dart
import 'package:common/src/services/dashboard/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledManifests', () {
    test('contains four core tiles in stable order', () {
      final ids = bundledManifests.map((m) => m.id).toList();
      expect(ids, ['bitcoin', 'hardware', 'lightning', 'system']);
    });
  });
}
```

- [ ] **Step 8: Run tests + trio + commit**

```bash
cd common && dart test test/services/dashboard/bundled/registry_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): codegen + registry for bundled tile manifests

scripts/gen_dashboard_manifests.dart embeds the four bundled manifest
JSON files into a generated .g.dart, mirroring the EmbeddedTemplates
pattern. registry.dart parses them at TUI startup and exposes a
sorted bundledManifests list. just gen-manifests recipe regenerates
on manifest edits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: TileRenderer widget

**Files:**
- Create: `tui/lib/src/ui/views/dashboard/tile_renderer.dart`
- Test: `tui/test/ui/views/dashboard/tile_renderer_test.dart`

**Spec reference:** the entire DSL section + "Architecture" diagram (per-tile renderer).

This is the largest task by line count. Structure as a sequence of TDD cycles:
one per primitive, then footer / status states. Run the trio + commit after
all cycles, not per cycle.

- [ ] **Step 1: Write a minimal failing test (skeleton + Row primitive)**

```dart
// tui/test/ui/views/dashboard/tile_renderer_test.dart
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/dashboard/tile_renderer.dart';

void main() {
  group('TileRenderer.text', () {
    test('Row renders "label: value"', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"Row":{"label":"Peers","value":{"$data":"peers"}}}]}
      ''');
      final snap = const TileSnapshot().copyWith(
        data: {'peers': 8}, lastEventTs: DateTime.utc(2026, 5, 5),
      );
      final out = renderTileToText(m, snap);
      expect(out, contains('Peers: 8'));
    });

    test('ProgressBar renders bar with percent', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"ProgressBar":{"label":"Sync","value":{"$data":"p"},"format":"percent"}}]}
      ''');
      final snap = const TileSnapshot().copyWith(
        data: {'p': 0.5}, lastEventTs: DateTime.utc(2026, 5, 5),
      );
      final out = renderTileToText(m, snap, width: 30);
      expect(out, contains('Sync'));
      expect(out, contains('50%'));
      expect(out, contains('█'));   // bar character
    });

    test('Section indents children + shows title', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[{"Section":{"title":"Wallet","children":[{"Row":{"label":"Bal","value":"0"}}]}}]}
      ''');
      final out = renderTileToText(m, const TileSnapshot());
      expect(out, contains('Wallet'));
      expect(out, contains('  Bal: 0'));   // two-space indent
    });

    test('Footer line shows synced status', () {
      final m = TileManifest.fromJsonString(r'''
        {"id":"x","title":"X","layout":[],
         "footer":{"$status":{"$on":"s","ok":{"Footer":{"text":"synced","color":"ok"}}}}}
      ''');
      final snap = const TileSnapshot().copyWith(data: {'s': 'ok'});
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

    test('empty data → "no data" placeholder footer', () {
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
      // StreamerCrashLoopError must be importable in the test; the
      // renderer matches by toString containing "crash-looping".
      final snap = const TileSnapshot().copyWith(lastError: Exception(
        'streamer crash-looping (4 restarts) — see log',
      ));
      final out = renderTileToText(m, snap);
      expect(out, contains('crash-looping'));
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail (file doesn't exist)**

- [ ] **Step 3: Implement `tile_renderer.dart`**

The widget version uses nocterm primitives (`Container`, `Column`, `Text`, etc.). For testability, also expose a `renderTileToText` helper that produces a plain-text buffer — used in tests, not in production. The widget implementation calls into the same primitive walker but emits nocterm widgets.

```dart
// tui/lib/src/ui/views/dashboard/tile_renderer.dart
import 'package:common/src/services/dashboard/colors.dart';
import 'package:common/src/services/dashboard/dsl/binding_resolver.dart';
import 'package:common/src/services/dashboard/dsl/primitives.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:nocterm/nocterm.dart';
import 'package:tui/src/ui/widgets/tile.dart';   // existing tile chrome

/// Widget version: builds a Tile() filled with nocterm widgets matching
/// the manifest. Used by dashboard_view.dart.
class TileRenderer extends StatelessComponent {
  final TileManifest manifest;
  final TileSnapshot snapshot;
  const TileRenderer({required this.manifest, required this.snapshot, super.key});

  @override
  Component build(BuildContext context) {
    final accent = manifest.accentColor != null
        ? (parseHex(manifest.accentColor!) ?? const Color.fromARGB(255, 0xee, 0xee, 0xee))
        : const Color.fromARGB(255, 0xee, 0xee, 0xee);

    final children = <Component>[];
    for (final p in manifest.layout) {
      children.add(_buildPrimitive(p, snapshot.data, accent));
    }
    return Tile(
      title: manifest.title,
      accentColor: accent,
      footer: _resolveFooter(manifest, snapshot, accent),
      footerColor: _resolveFooterColor(manifest, snapshot, accent),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

Component _buildPrimitive(Primitive p, Map<String, dynamic> data, Color accent) {
  switch (p) {
    case Row r:
      final v = resolveValue(r.value, data)?.toString() ?? '—';
      return Text('${r.label}: $v',
          style: TextStyle(color: resolveTileColor(r.valueColor, accent: accent)));
    case StatusRow r:
      final v = resolveValue(r.value, data)?.toString() ?? '—';
      final c = resolveValue(r.color, data)?.toString();
      return Text('${r.label}: $v',
          style: TextStyle(color: resolveTileColor(c, accent: accent)));
    case ProgressBar pb:
      return _renderProgressBar(pb, data, accent);
    case Section s:
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (s.title != null) Text(s.title!, style: TextStyle(color: resolveTileColor('muted', accent: accent))),
        for (final child in s.children)
          Padding(padding: const EdgeInsets.only(left: 2), child: _buildPrimitive(child, data, accent)),
      ]);
    case Spacer sp:
      return SizedBox(height: sp.height);
    case Footer _:
      // Footer in layout would have been rejected at parse time; but
      // be defensive.
      return Text('');
  }
}

Component _renderProgressBar(ProgressBar pb, Map<String, dynamic> data, Color accent) {
  final raw = resolveValue(pb.value, data);
  final value = (raw is num) ? raw.toDouble() : 0.0;
  final pct = pb.max > 0 ? (value / pb.max).clamp(0.0, 1.0) : 0.0;
  final label = pb.label ?? '';
  final pctText = (pct * 100).toStringAsFixed(0);
  // Bar character row: 20-cell bar, filled by pct.
  final filled = (pct * 20).round();
  final bar = '█' * filled + '·' * (20 - filled);
  return Text('$label  $bar  $pctText%',
      style: TextStyle(color: resolveTileColor(pb.color, accent: accent)));
}

String? _resolveFooter(TileManifest m, TileSnapshot snap, Color accent) {
  if (snap.lastError != null) {
    final s = snap.lastError.toString();
    if (s.contains('crash-looping')) return 'crash-looping — see log';
    return s;
  }
  if (snap.isEmpty) return 'no data';
  if (m.footer is Footer) return (m.footer as Footer).text?.toString();
  if (m.footer is Map) {
    final resolved = resolveValue(m.footer, snap.data);
    if (resolved is Map && resolved.containsKey('Footer')) {
      final f = (resolved['Footer'] as Map).cast<String, dynamic>();
      return f['text']?.toString();
    }
  }
  return null;
}

Color _resolveFooterColor(TileManifest m, TileSnapshot snap, Color accent) {
  if (snap.lastError != null) return resolveTileColor('error', accent: accent);
  if (snap.isEmpty) return resolveTileColor('muted', accent: accent);
  if (m.footer is Footer) {
    final c = (m.footer as Footer).color;
    return resolveTileColor(c is String ? c : null, accent: accent);
  }
  if (m.footer is Map) {
    final resolved = resolveValue(m.footer, snap.data);
    if (resolved is Map && resolved.containsKey('Footer')) {
      final f = (resolved['Footer'] as Map).cast<String, dynamic>();
      final c = f['color'];
      return resolveTileColor(c is String ? c : null, accent: accent);
    }
  }
  return resolveTileColor('default', accent: accent);
}

/// Test helper: produces a plain-text rendering for golden-style tests.
String renderTileToText(TileManifest m, TileSnapshot snap, {int width = 40}) {
  final out = StringBuffer();
  out.writeln('=== ${m.title} ===');
  for (final p in m.layout) {
    _renderToText(p, snap.data, out, indent: 0);
  }
  final footer = _resolveFooter(m, snap, const Color.fromARGB(255, 0, 0, 0));
  if (footer != null) out.writeln('— $footer');
  return out.toString();
}

void _renderToText(Primitive p, Map<String, dynamic> data, StringBuffer out, {int indent = 0}) {
  final pad = '  ' * indent;
  switch (p) {
    case Row r:
      final v = resolveValue(r.value, data)?.toString() ?? '—';
      out.writeln('$pad${r.label}: $v');
    case StatusRow r:
      final v = resolveValue(r.value, data)?.toString() ?? '—';
      out.writeln('$pad${r.label}: $v');
    case ProgressBar pb:
      final raw = resolveValue(pb.value, data);
      final value = (raw is num) ? raw.toDouble() : 0.0;
      final pct = pb.max > 0 ? (value / pb.max).clamp(0.0, 1.0) : 0.0;
      final filled = (pct * 20).round();
      final bar = '█' * filled + '·' * (20 - filled);
      out.writeln('$pad${pb.label ?? ''}  $bar  ${(pct * 100).toStringAsFixed(0)}%');
    case Section s:
      if (s.title != null) out.writeln('$pad${s.title}');
      for (final c in s.children) {
        _renderToText(c, data, out, indent: indent + 1);
      }
    case Spacer _:
      out.writeln('');
    case Footer _:
      // ignored in layout
      break;
  }
}
```

- [ ] **Step 4: Run tests — confirm pass + trio + commit**

```bash
cd tui && dart test test/ui/views/dashboard/tile_renderer_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): generic TileRenderer

One widget that paints any TileManifest given a TileSnapshot. Walks
the primitive tree, resolves binding directives at render time, picks
the footer from the manifest's footer block or from the snapshot's
error / empty state. renderTileToText is a test-only helper that
produces a plain-text rendering for golden-style assertions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Dashboard chrome widget

**Files:**
- Create: `tui/lib/src/ui/views/dashboard/dashboard_chrome.dart`
- Test: `tui/test/ui/views/dashboard/dashboard_chrome_test.dart`

**Spec reference:** "Dashboard chrome" section.

- [ ] **Step 1: Write failing tests**

```dart
// tui/test/ui/views/dashboard/dashboard_chrome_test.dart
import 'package:test/test.dart';
import 'package:tui/src/ui/views/dashboard/dashboard_chrome.dart';

void main() {
  group('renderChromeText', () {
    test('first line shows hostname · platform · network', () {
      final out = renderChromeText(
        hostname: 'nixblitz-pi5',
        platform: 'raspi5',
        network: 'mainnet',
        uptimeSec: null,
        appliedAgo: null,
      );
      expect(out, contains('nixblitz-pi5'));
      expect(out, contains('raspi5'));
      expect(out, contains('mainnet'));
    });

    test('second line shows uptime + applied when available', () {
      final out = renderChromeText(
        hostname: 'h', platform: 'p', network: 'main',
        uptimeSec: 3700,
        appliedAgo: const Duration(hours: 2),
      );
      expect(out, contains('uptime 1h 1m'));
      expect(out, contains('applied 2h ago'));
    });

    test('falls back gracefully when secondary info missing', () {
      final out = renderChromeText(
        hostname: 'h', platform: 'p', network: 'main',
        uptimeSec: null, appliedAgo: null,
      );
      // Second line should be present but light
      expect(out.split('\n').length, greaterThanOrEqualTo(2));
    });
  });
}
```

- [ ] **Step 2: Run tests — confirm fail**

- [ ] **Step 3: Implement `dashboard_chrome.dart`**

```dart
// tui/lib/src/ui/views/dashboard/dashboard_chrome.dart
import 'package:common/src/services/dashboard/dsl/binding_resolver.dart';
import 'package:nocterm/nocterm.dart';

class DashboardChrome extends StatelessComponent {
  final String hostname;
  final String platform;
  final String network;
  final int? uptimeSec;
  final Duration? appliedAgo;
  const DashboardChrome({
    required this.hostname,
    required this.platform,
    required this.network,
    this.uptimeSec,
    this.appliedAgo,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final l1 = '$hostname  ·  $platform  ·  $network';
    final parts = <String>[];
    if (uptimeSec != null) parts.add('uptime ${formatDuration(uptimeSec!)}');
    if (appliedAgo != null) parts.add('applied ${_appliedAgoLabel(appliedAgo!)} ago');
    final l2 = parts.join('  ·  ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l1),
      if (l2.isNotEmpty) Text(l2, style: const TextStyle()),
    ]);
  }
}

String _appliedAgoLabel(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d';
  if (d.inHours > 0) return '${d.inHours}h';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '<1m';
}

/// Test helper.
String renderChromeText({
  required String hostname,
  required String platform,
  required String network,
  required int? uptimeSec,
  required Duration? appliedAgo,
}) {
  final l1 = '$hostname  ·  $platform  ·  $network';
  final parts = <String>[];
  if (uptimeSec != null) parts.add('uptime ${formatDuration(uptimeSec)}');
  if (appliedAgo != null) parts.add('applied ${_appliedAgoLabel(appliedAgo)} ago');
  final l2 = parts.join('  ·  ');
  return '$l1\n$l2';
}
```

- [ ] **Step 4: Run tests + trio + commit**

```bash
cd tui && dart test test/ui/views/dashboard/dashboard_chrome_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(dashboard): identity chrome header

Two-line header above the tile area: hostname · platform · network on
line 1 (config-derived, always available); uptime + last-applied on
line 2 (best-effort from cache + git_provider).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: New Riverpod providers

**Files:**
- Modify: `common/lib/src/providers/dashboard_provider.dart` — full rewrite of file contents

**Spec reference:** "Riverpod wiring" section.

- [ ] **Step 1: Replace the file's contents**

```dart
// common/lib/src/providers/dashboard_provider.dart
import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/dashboard/bundled/registry.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/sources/blitz_api_bridge_source.dart';
import 'package:common/src/services/dashboard/sources/streamer_subprocess_source.dart';
import 'package:common/src/services/dashboard/tile_data_cache.dart';
import 'package:common/src/services/dashboard/tile_event_source_registry.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';

final tileSourceRegistryProvider = Provider<TileEventSourceRegistry>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final reg = TileEventSourceRegistry();

  // system-stats: always on. Reads procfs/sysfs; no blitz-api dep.
  // Pull --units from system.json's streamer_args once we look it up
  // from bundledManifests; for Phase 1, hardcode the Phase-1 unit set
  // here — same units as the existing system tile shows.
  reg.register(StreamerSubprocessSource(
    id: 'system-stats',
    providedTileIds: const {'hardware', 'system'},
    command: Platform.resolvedExecutable,
    args: const ['streamer', 'system-stats',
        '--units', 'blitz-api,blitz-web,nginx,redis'],
  ));

  // blitz-api-bridge: gated on config (Phase 4 swaps this for plugin presence).
  if (config != null && config.blitzApi.enabled) {
    reg.register(BlitzApiBridgeSource());
  }

  unawaited(reg.startAll());
  ref.onDispose(reg.disposeAll);
  return reg;
});

final tileDataCacheProvider = Provider<TileDataCache>((ref) {
  final reg = ref.watch(tileSourceRegistryProvider);
  final cache = TileDataCache();
  final subs = <StreamSubscription>[];
  for (final src in reg.sources) {
    subs.add(src.events.listen(
      cache.apply,
      onError: (e, st) {
        for (final tid in src.providedTileIds) cache.applyError(tid, e);
      },
    ));
  }
  ref.onDispose(() async {
    for (final s in subs) await s.cancel();
    await cache.dispose();
  });
  return cache;
});

final tileManifestsProvider = Provider<List<TileManifest>>((ref) => bundledManifests);

final tileSnapshotProvider = StreamProvider.family<TileSnapshot, String>((ref, tileId) {
  final cache = ref.watch(tileDataCacheProvider);
  // Seed with current snapshot so a late subscriber sees the last
  // value immediately, then follow the live stream.
  return Stream<TileSnapshot>.multi((controller) async {
    controller.add(cache.snapshotFor(tileId));
    final sub = cache.streamFor(tileId).listen(controller.add,
        onError: controller.addError, onDone: controller.close);
    controller.onCancel = sub.cancel;
  });
});
```

- [ ] **Step 2: Add the missing import for `Platform`**

```dart
import 'dart:io' show Platform;
```

(Add to top of file.)

- [ ] **Step 3: Trio**

```bash
just analyze
```

Expected: zero issues. Existing tests for the deleted providers will fail; that's fine — they're addressed in Task 17 (delete old code) and Task 16 (smoke).

- [ ] **Step 4: Commit (no trio yet — old code paths still reference deleted providers; Task 16+17 cleans up)**

```bash
jj commit -m "$(cat <<'EOF'
feat(dashboard): rewire Riverpod providers for the tile pipeline

Replaces dashboardDataSourceProvider + four snapshot providers with
the new tileSourceRegistryProvider / tileDataCacheProvider /
tileManifestsProvider / tileSnapshotProvider.family. system-stats
streamer is registered unconditionally; blitz-api-bridge stays
gated on config.blitzApi.enabled (Phase 4 will swap to plugin presence).

Trio not yet green — old tile widgets still reference the deleted
providers. Tasks 16/17 finish the swap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Update dashboard_view.dart

**Files:**
- Modify: `tui/lib/src/ui/views/dashboard_view.dart`

**Spec reference:** "Architecture" + "Dashboard chrome" + "Riverpod wiring" sections.

- [ ] **Step 1: Read the existing file to understand its structure**

```bash
cat tui/lib/src/ui/views/dashboard_view.dart
```

Identify: layout block that renders the four hardcoded tiles. Replace with chrome + map of TileRenderer per manifest.

- [ ] **Step 2: Replace the dashboard body**

The new body has two parts: chrome + a column of `TileRenderer(manifest, snapshot)` per `tileManifestsProvider` entry. Keep the existing key-handler / footer / outer scaffolding — only the body changes.

```dart
// Inside DashboardView's build method, replace the four-tiles
// children list with:

final manifests = context.watch(tileManifestsProvider);
final config = context.watch(configProvider).value;

final tiles = <Component>[];
for (final m in manifests) {
  final snap = context.watch(tileSnapshotProvider(m.id)).value
      ?? const TileSnapshot();
  tiles.add(TileRenderer(manifest: m, snapshot: snap));
}

return Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    DashboardChrome(
      hostname:  config?.system.hostname ?? '?',
      platform:  config?.system.platform ?? '?',
      network:   config?.bitcoind.network ?? 'unknown',
      uptimeSec: _readUptimeSec(context),    // helper: read system tile's data['uptime_sec']
      appliedAgo: _readAppliedAgo(context),  // existing git_provider-based helper
    ),
    const SizedBox(height: 1),
    ...tiles,
  ],
);
```

Where `_readUptimeSec` and `_readAppliedAgo` are small helpers in the same file:

```dart
int? _readUptimeSec(BuildContext context) {
  final cache = context.read(tileDataCacheProvider);
  final v = cache.snapshotFor('system').data['uptime_sec'];
  return v is num ? v.toInt() : null;
}

Duration? _readAppliedAgo(BuildContext context) {
  // Wire to whatever git_provider exposes today. If unavailable,
  // return null — chrome will simply omit the field.
  return null; // placeholder until git_provider exposes it cleanly.
}
```

- [ ] **Step 3: Update imports**

Add at top of file:

```dart
import 'package:common/src/providers/dashboard_provider.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:tui/src/ui/views/dashboard/dashboard_chrome.dart';
import 'package:tui/src/ui/views/dashboard/tile_renderer.dart';
```

Remove imports of the four deleted tile widgets (bitcoin_tile.dart, etc.) — Task 17 deletes the files.

- [ ] **Step 4: Trio (analyzer will still flag the deleted tile widget files until Task 17)**

```bash
just analyze
```

Expected: errors about missing tile widgets (until Task 17). Acceptable mid-stream.

- [ ] **Step 5: Commit**

```bash
jj commit -m "$(cat <<'EOF'
refactor(dashboard): swap hand-coded tiles for manifest-driven renderer

dashboard_view now renders the chrome header followed by one
TileRenderer per bundled manifest, fed by tileSnapshotProvider.family.
The old four hardcoded tile widget calls are removed; Task 17 deletes
the widget files themselves.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Delete obsolete code

**Files:**
- Delete: `tui/lib/src/ui/views/dashboard/bitcoin_tile.dart`
- Delete: `tui/lib/src/ui/views/dashboard/lightning_tile.dart`
- Delete: `tui/lib/src/ui/views/dashboard/hardware_tile.dart`
- Delete: `tui/lib/src/ui/views/dashboard/system_tile.dart`
- Delete: `common/lib/src/services/dashboard/dashboard_data_source.dart`
- Delete: `common/lib/src/services/dashboard/api_dashboard_source.dart`
- Delete: `common/lib/src/models/dashboard/snapshots.dart`
- Delete any tests for the above that no longer apply (e.g., `common/test/services/dashboard/api_dashboard_source_test.dart` if present).

**Spec reference:** "Deleted files" subsection of "File-level changes".

- [ ] **Step 1: Confirm no callers remain**

```bash
grep -rn 'BitcoinTile\|LightningTile\|HardwareTile\|SystemTile\|DashboardDataSource\|ApiDashboardSource\|NullDashboardSource\|BtcSnapshot\|LnSnapshot\|HardwareSnapshot\|SystemSnapshot' \
  common/lib tui/lib tui/bin 2>&1 | grep -v '.g.dart'
```

Expected: empty. If anything remains, fix before deleting.

- [ ] **Step 2: Delete the files**

```bash
rm tui/lib/src/ui/views/dashboard/bitcoin_tile.dart
rm tui/lib/src/ui/views/dashboard/lightning_tile.dart
rm tui/lib/src/ui/views/dashboard/hardware_tile.dart
rm tui/lib/src/ui/views/dashboard/system_tile.dart
rm common/lib/src/services/dashboard/dashboard_data_source.dart
rm common/lib/src/services/dashboard/api_dashboard_source.dart
rm common/lib/src/models/dashboard/snapshots.dart

# Remove the empty parent dir if it's empty:
rmdir common/lib/src/models/dashboard 2>/dev/null || true
```

- [ ] **Step 3: Delete obsolete tests**

```bash
# If they exist:
rm -f common/test/services/dashboard/api_dashboard_source_test.dart
rm -f tui/test/ui/views/dashboard/{bitcoin,lightning,hardware,system}_tile_test.dart
```

- [ ] **Step 4: Update common.dart re-exports**

If `common/lib/common.dart` exports any deleted symbols (snapshots, ApiDashboardSource, DashboardDataSource), remove those exports.

```bash
grep -n 'snapshots.dart\|api_dashboard_source.dart\|dashboard_data_source.dart' common/lib/common.dart
```

If any line is found, edit it out.

- [ ] **Step 5: Trio — must be fully green now**

```bash
just test && just analyze && just format
```

Expected: all green. Any failure here means a missed reference; chase and fix.

- [ ] **Step 6: Commit**

```bash
jj commit -m "$(cat <<'EOF'
refactor(dashboard): delete obsolete tile widgets, snapshot classes, ApiDashboardSource

Bitcoin/Lightning/Hardware/System tile widgets, BtcSnapshot/LnSnapshot/
HardwareSnapshot/SystemSnapshot model classes, ApiDashboardSource and
DashboardDataSource interface — all replaced by the generic tile
pipeline. Trio passes; pipeline is end-to-end.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Manual smoke + final trio

**Files:** none (verification only)

**Spec reference:** "Manual smoke" subsection of "Testing strategy".

- [ ] **Step 1: Final trio**

```bash
just test
just analyze
just format
```

Expected: all green; no diff on format.

- [ ] **Step 2: Run TUI in a VM with blitzApi.enabled = true**

```bash
just vm-boot
# In VM: ssh in, run nixblitz, verify dashboard:
# - chrome header shows hostname/platform/network
# - hardware tile populates within ~2s
# - system tile populates within ~5s with uptime + service rows
# - bitcoin + lightning tiles populate within ~10s once SSE primes
# - tile order: bitcoin, hardware, lightning, system (alphabetical by id)
```

- [ ] **Step 3: Verify behaviour with blitzApi.enabled = false**

```bash
# In VM: edit ~/nixblitz/config.json to set "blitz_api": {"enabled": false}
# Apply, restart TUI.
# Expect:
# - hardware + system tiles populate as before (system-stats is unaffected)
# - bitcoin + lightning tiles render footer "no data — blitz-api-bridge not running"
#   in muted colour
```

- [ ] **Step 4: Verify crash-loop UX**

```bash
# In VM: pkill -f 'streamer system-stats' repeatedly within 60s.
# Expect:
# - First few kills: hardware/system tiles brief "stale" then recover
# - After 3+ kills within 60s: tiles footer reads "crash-looping — see log" in red
# - ~/nixblitz.log contains warn-level entries with the crash details
```

- [ ] **Step 5: Capture before/after screenshots**

```bash
# Save a TTY snapshot of the dashboard for the spec's record:
# Use asciinema or a screenshot tool. Drop the file into:
# docs/superpowers/specs/2026-05-05-dashboard-pluggability-design/after.cast
# (Optional but recommended — close the loop on visual parity.)
```

- [ ] **Step 6: No commit needed (verification task)**

If Step 5 was performed, commit the asciinema file separately:

```bash
jj commit -m "$(cat <<'EOF'
docs(dashboard): asciinema snapshot post-refactor

Visual parity check: dashboard renders identity chrome + four tiles
through the new generic pipeline.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

**Spec coverage:**

| Spec section | Implementing task(s) |
|---|---|
| Tile manifest schema | Task 4 |
| Primitive registry (six primitives) | Task 3 |
| Data binding language (seven directives) | Task 5 |
| Colors (semantic + hex) | Task 2 |
| `TileEvent` / `TileSnapshot` | Task 1 |
| `TileEventSource` contract | Task 6 |
| `TileEventSourceRegistry` | Task 6 |
| `TileDataCache` | Task 6 |
| `InProcessAdapterSource` | Task 6 |
| `StreamerSubprocessSource` | Task 7 |
| `BlitzApiBridgeSource` | Task 8 |
| `system-stats` streamer | Task 9 |
| `nixblitz streamer <name>` argv dispatch | Task 10 |
| Bundled tile manifests (4 JSONs) | Task 11 |
| Manifest embedding (codegen) | Task 12 |
| `TileRenderer` widget | Task 13 |
| Dashboard chrome | Task 14 |
| Riverpod wiring | Task 15 |
| dashboard_view.dart update | Task 16 |
| Deletion of obsolete code | Task 17 |
| Manual smoke + verification | Task 18 |
| Crash-loop diagnostic UX | Task 7 (impl) + Task 13 (footer rendering) + Task 18 (verify) |
| "no data" footer for unregistered sources | Task 13 (impl) + Task 18 (verify) |
| Trio gate per task | every task |

All spec sections covered. No gaps.

**Type consistency check:** `TileEvent`, `TileSnapshot`, `Primitive`, `TileManifest`, `TileEventSource`, `TileEventSourceRegistry`, `TileDataCache`, `InProcessAdapterSource`, `StreamerSubprocessSource`, `BlitzApiBridgeSource`, `TileRenderer`, `DashboardChrome` are introduced in Task N and used consistently in Task N+. Method signatures (`apply`, `applyError`, `start`, `dispose`, `register`, `streamFor`, `snapshotFor`, `events`, `providedTileIds`, `id`) match across tests and implementations.

**Placeholder scan:** every code step shows complete code. No "TBD", no "implement later", no "similar to Task N." `_readAppliedAgo` is a known stub in Task 16 with explicit acknowledgement that git_provider doesn't expose this cleanly today — it's documented as a placeholder returning null, not a hidden gap.

---

## Plan complete

Saved to: `docs/superpowers/plans/2026-05-05-dashboard-pluggability.md`
