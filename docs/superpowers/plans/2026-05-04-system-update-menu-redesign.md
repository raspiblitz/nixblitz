# System Update menu redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the System Update menu around cache-driven gating, expose lightweight + heavy checks from the TUI, drop routine refresh-plugins / refresh-templates actions from the menu, and surface plugin drift via the lightweight check.

**Architecture:** Two stacked panels in `_buildSelectMode` — **Status** (cache snapshot + manual triggers) and **Actions** (gated rebuild paths). New `pluginsAhead` field on `LightCheck` populated by extending `runLightweight()` to walk active non-pinned plugins. Template auto-rewrite is fired implicitly at the end of every successful Update flow. The "Update entire system" path no longer auto-refreshes plugins; that workflow lives in the plugins menu.

**Tech Stack:** Dart (TUI: `nocterm` + `nocterm_riverpod`; common: pure Dart, `package:http`), `package:test`, `riverpod`, `just` task runner. `jj` for VCS (don't run commits — print messages, the user commits themselves).

**Spec:** `docs/superpowers/specs/2026-05-04-system-update-menu-redesign-design.md`

**Working conventions for this plan:**

- The user handles commits themselves. Each task ends with a "print commit message" step — do **not** run `jj commit`, `jj describe`, or `git commit`.
- After every task, run the trio: `just test`, `just analyze`, `just format` (in that order). Fix any regressions before moving on.
- TDD: tests first, watch them fail, then implement, watch them pass.
- The TUI codebase has hard-won pitfalls — see `CLAUDE.md` ("Nocterm Pitfalls"). Especially: never set a `StateProvider` inside an `onKeyEvent` handler followed by other work; use sync I/O in key handlers; wrap full handler bodies in try/catch.

---

## File Structure

**Modify:**

- `common/lib/src/models/update_status.dart` — add `PluginAhead`, extend `LightCheck`.
- `common/lib/src/services/update_check_service.dart` — extend `runLightweight()` to walk plugins; add a static helper that converts `PluginEntry` → `LockedInput`-shaped probe payload.
- `tui/lib/src/ui/views/update_view.dart` — major rewrite of `_buildSelectMode`; add `_UpdateMode.runningCheck`; new `_buildStatusPanel`; new `_buildHeavyConfirm`; gating helpers; `[c]`/`[C]`/`[p]` keybinds; template auto-rewrite hook; drop `Refresh plugins only` and `Refresh Nix templates`.
- `tui/lib/src/ui/views/dashboard_view.dart` — no functional change; verify drift banner still works after auto-rewrite is in place.

**Create:**

- `tui/lib/src/ui/views/update/action_gating.dart` — pure function `computeUpdateActionStates(UpdateStatus, {String? tuiInputName})` returning `{tuiOnly, entireSystem}` action states (`enabled`, `subtitle`). Pure-Dart, no nocterm imports — testable without a TUI harness.
- `tui/test/ui/views/update/action_gating_test.dart` — unit tests for action_gating.dart.

**Tests modified:**

- `common/test/services/update_check_service_test.dart` — add cases for plugin walking.
- `common/test/models/update_status_test.dart` (create if missing) — JSON round-trip for `PluginAhead` + backward compat (no `plugins_ahead` field).

---

## Task 1: Add `PluginAhead` model + `LightCheck.pluginsAhead` field

**Files:**

- Modify: `common/lib/src/models/update_status.dart`
- Test: `common/test/models/update_status_test.dart` (create if missing)

- [ ] **Step 1: Write the failing test**

If `common/test/models/update_status_test.dart` doesn't exist, create it. Append:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('PluginAhead', () {
    test('round-trips through JSON', () {
      final original = PluginAhead(
        dirName: 'mempool',
        currentRev: 'a' * 40,
        upstreamRev: 'b' * 40,
        url: 'https://github.com/example/mempool',
      );
      final reparsed = PluginAhead.fromJson(original.toJson());
      expect(reparsed.dirName, original.dirName);
      expect(reparsed.currentRev, original.currentRev);
      expect(reparsed.upstreamRev, original.upstreamRev);
      expect(reparsed.url, original.url);
    });
  });

  group('LightCheck', () {
    test('parses plugins_ahead when present', () {
      final json = {
        'checked_at': '2026-05-04T10:00:00.000Z',
        'ok': true,
        'inputs_ahead': [],
        'plugins_ahead': [
          {
            'dir_name': 'electrs',
            'current_rev': 'a' * 40,
            'upstream_rev': 'b' * 40,
            'url': 'https://example/electrs',
          },
        ],
      };
      final lc = LightCheck.fromJson(json);
      expect(lc.pluginsAhead.length, 1);
      expect(lc.pluginsAhead.single.dirName, 'electrs');
    });

    test('treats missing plugins_ahead as empty (backward compat)', () {
      final json = {
        'checked_at': '2026-05-04T10:00:00.000Z',
        'ok': true,
        'inputs_ahead': [],
      };
      final lc = LightCheck.fromJson(json);
      expect(lc.pluginsAhead, isEmpty);
    });

    test('serialises plugins_ahead', () {
      final lc = LightCheck(
        checkedAt: DateTime.utc(2026, 5, 4),
        ok: true,
        pluginsAhead: [
          PluginAhead(
            dirName: 'mempool',
            currentRev: 'a' * 40,
            upstreamRev: 'b' * 40,
            url: 'https://example',
          ),
        ],
      );
      final j = lc.toJson();
      expect((j['plugins_ahead'] as List).length, 1);
    });
  });
}
```

- [ ] **Step 2: Run the test, expect failure**

```
cd common && dart test test/models/update_status_test.dart
```

Expected: compile error (`PluginAhead` unknown, `pluginsAhead` getter missing).

- [ ] **Step 3: Add `PluginAhead` class to `update_status.dart`**

Insert above the existing `class HeavyCheck`:

```dart
/// Like [InputAhead] but for an installed plugin. The lightweight
/// check probes each `auto_update=true && pinnedRev != null` plugin's
/// upstream HEAD against the rev recorded in `config.json` and emits
/// one of these per plugin that has moved.
///
/// Pinned plugins (`auto_update == false`) are intentionally skipped
/// — the operator opted out of automatic refreshes for them.
class PluginAhead {
  const PluginAhead({
    required this.dirName,
    required this.currentRev,
    required this.upstreamRev,
    required this.url,
  });

  /// Matches `PluginEntry.dirName` — the on-disk directory under
  /// `~/nixblitz/plugins/`, also the join key the plugins menu uses.
  final String dirName;

  /// Full SHA we have locked in `config.json`.
  final String currentRev;

  /// Full SHA the upstream branch is at now.
  final String upstreamRev;

  /// Source URL (clone URL); useful for surfacing where an update came
  /// from in the plugins menu.
  final String url;

  factory PluginAhead.fromJson(Map<String, dynamic> j) => PluginAhead(
    dirName: j['dir_name'] as String,
    currentRev: j['current_rev'] as String,
    upstreamRev: j['upstream_rev'] as String,
    url: j['url'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'dir_name': dirName,
    'current_rev': currentRev,
    'upstream_rev': upstreamRev,
    'url': url,
  };
}
```

- [ ] **Step 4: Extend `LightCheck`**

In the existing `LightCheck` class:

- Add field `final List<PluginAhead> pluginsAhead;`
- Add to constructor: `this.pluginsAhead = const [],`
- Update `fromJson` to read `plugins_ahead`:
  ```dart
  pluginsAhead: ((j['plugins_ahead'] as List?) ?? const [])
      .map((e) => PluginAhead.fromJson(e as Map<String, dynamic>))
      .toList(),
  ```
- Update `toJson` to write it:

  ```dart
  'plugins_ahead': pluginsAhead.map((e) => e.toJson()).toList(),
  ```

- [ ] **Step 5: Re-export from `common.dart` if needed**

Check `common/lib/common.dart` for the existing `update_status.dart` export. `PluginAhead` is exported automatically via the same `export 'src/models/update_status.dart';` line — no change needed unless the export uses an explicit `show` list (it doesn't, per current state).

- [ ] **Step 6: Run trio**

```
just test
just analyze
just format
```

Expected: tests added in step 1 now pass; analyze clean; format may rewrap a couple of lines.

- [ ] **Step 7: Print commit message**

Print this draft for the user to paste:

```
feat(common): add PluginAhead + LightCheck.pluginsAhead

Cache schema extension so the lightweight update check can record
plugins whose upstream HEAD has moved past the locked rev. Mirrors
the existing InputAhead shape for flake inputs. Backward-compat:
missing plugins_ahead in older status files parses as empty list.

Wiring into runLightweight() and the TUI menu lands in subsequent
commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 2: Plugin → upstream-probe helper

Convert a `PluginEntry` (with its `url` + `branch` + `pinnedRev`) into the same shape `_queryUpstreamRev` consumes, so the existing GitHub / Forgejo HTTP machinery works for plugins without duplication.

**Files:**

- Modify: `common/lib/src/services/update_check_service.dart`
- Test: `common/test/services/update_check_service_test.dart`

- [ ] **Step 1: Write the failing test**

Append to `update_check_service_test.dart`:

```dart
group('lockedInputForPlugin', () {
  test('parses github: scheme', () {
    final p = _pluginEntry(
      url: 'github:example/foo',
      branch: 'main',
      pinnedRev: 'a' * 40,
    );
    final li = UpdateCheckService.lockedInputForPlugin(p);
    expect(li, isNotNull);
    expect(li!.type, 'github');
    expect(li.owner, 'example');
    expect(li.repo, 'foo');
    expect(li.ref, 'main');
    expect(li.lockedRev, 'a' * 40);
  });

  test('parses forgejo: scheme', () {
    final p = _pluginEntry(
      url: 'forgejo:forge.example/owner/repo',
      branch: 'main',
      pinnedRev: 'b' * 40,
    );
    final li = UpdateCheckService.lockedInputForPlugin(p);
    expect(li!.type, 'git');
    expect(li.host, 'forge.example');
    expect(li.owner, 'owner');
    expect(li.repo, 'repo');
  });

  test('returns null for unsupported transport (file://)', () {
    final p = _pluginEntry(
      url: 'file:///tmp/local-plugin',
      branch: 'main',
      pinnedRev: 'c' * 40,
    );
    expect(UpdateCheckService.lockedInputForPlugin(p), isNull);
  });
});
```

Add at the bottom of the file:

```dart
PluginEntry _pluginEntry({
  required String url,
  required String branch,
  required String pinnedRev,
}) => PluginEntry(
  id: url,
  url: url,
  branch: branch,
  pinnedRev: pinnedRev,
  dirName: 'fixture',
  installedAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);
```

Imports needed at the top of the test file (add if absent):

```dart
import 'package:common/common.dart';
```

- [ ] **Step 2: Run the test, expect failure**

```
cd common && dart test test/services/update_check_service_test.dart
```

Expected: `lockedInputForPlugin` undefined.

- [ ] **Step 3: Implement `lockedInputForPlugin`**

In `update_check_service.dart`, inside `class UpdateCheckService`, after `parseRootInputs`:

```dart
/// Translates a plugin entry's url/branch/pinnedRev into the same
/// shape [_queryUpstreamRev] expects. Returns `null` when the plugin
/// uses a transport we can't probe (file://, https:// without a
/// recognised forge host, etc.) — caller skips those silently.
///
/// Supported schemes: `github:owner/repo`, `forgejo:host/owner/repo`,
/// `gitea:host/owner/repo`. The `https://` scheme is *not* supported
/// here because the plain URL doesn't tell us which forge API to
/// call; if a plugin uses https://forge.example/owner/repo and we
/// want to probe it, the operator should switch the URL to the
/// `forgejo:` form first.
static LockedInput? lockedInputForPlugin(PluginEntry entry) {
  final raw = entry.url;
  final ref = entry.branch;
  final lockedRev = entry.pinnedRev;

  if (raw.startsWith('github:')) {
    final body = raw.substring('github:'.length);
    // Strip ?dir=... canonical-subdir suffix if present.
    final qIdx = body.indexOf('?dir=');
    final core = qIdx >= 0 ? body.substring(0, qIdx) : body;
    final parts = core.split('/');
    if (parts.length < 2) return null;
    final owner = parts[0];
    final repo = parts[1];
    if (owner.isEmpty || repo.isEmpty) return null;
    return LockedInput(
      name: entry.dirName,
      type: 'github',
      owner: owner,
      repo: repo,
      host: null,
      ref: ref,
      lockedRev: lockedRev,
      urlForDisplay: raw,
    );
  }

  if (raw.startsWith('forgejo:') || raw.startsWith('gitea:')) {
    final scheme = raw.startsWith('forgejo:') ? 'forgejo:' : 'gitea:';
    final body = raw.substring(scheme.length);
    final qIdx = body.indexOf('?dir=');
    final core = qIdx >= 0 ? body.substring(0, qIdx) : body;
    final parts = core.split('/');
    if (parts.length < 3) return null;
    final host = parts[0];
    final owner = parts[1];
    final repo = parts[2];
    if (host.isEmpty || owner.isEmpty || repo.isEmpty) return null;
    return LockedInput(
      name: entry.dirName,
      type: 'git',
      owner: owner,
      repo: repo,
      host: host,
      ref: ref,
      lockedRev: lockedRev,
      urlForDisplay: raw,
    );
  }

  return null;
}
```

- [ ] **Step 4: Run trio**

Tests pass; analyzer clean; format may adjust whitespace.

- [ ] **Step 5: Print commit message**

```
feat(common): UpdateCheckService.lockedInputForPlugin

Static helper that translates a PluginEntry's source URL + branch +
pinned rev into the LockedInput shape _queryUpstreamRev consumes.
Same parsing rules as the existing flake-input parsing path
(github: / forgejo: / gitea:); unsupported transports return null
so the caller can skip silently. Sets the stage for runLightweight()
to walk plugins in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 3: Extend `runLightweight()` to walk plugins

**Files:**

- Modify: `common/lib/src/services/update_check_service.dart`
- Test: `common/test/services/update_check_service_test.dart`

- [ ] **Step 1: Write the failing tests**

Add to `update_check_service_test.dart` — these need a way to inject a config + an HTTP client. Inspect the existing test fixtures first to find the established stub-HTTP pattern (look for `MockClient` / `http.Client` injection in the file). Use the same pattern.

Add these test cases (sketch — flesh out using whatever fixtures exist):

```dart
test('runLightweight walks active auto-update plugins', () async {
  // Fixture: one plugin behind upstream by one commit.
  final svc = UpdateCheckService(
    flakePath: tempFlakeDir,        // existing fixture from other tests
    statusPath: tempStatusFile,
    httpClient: stubHttpReturning({  // existing helper
      'https://api.github.com/repos/example/foo/commits/main':
          {'sha': 'b' * 40},
    }),
    configReader: () async => _configWith([
      _pluginEntryFor(
        url: 'github:example/foo',
        pinnedRev: 'a' * 40,
        autoUpdate: true,
        enabled: true,
      ),
    ]),
  );
  await svc.runLightweight();
  final status = svc.readStatus();
  expect(status.lightweight!.pluginsAhead.length, 1);
  expect(status.lightweight!.pluginsAhead.single.upstreamRev, 'b' * 40);
});

test('runLightweight skips pinned (autoUpdate=false) plugins', () async {
  // ...
  // Expected: pluginsAhead is empty, no HTTP call made.
});

test('runLightweight skips uninstalled (tombstone) plugins', () async { ... });
test('runLightweight skips disabled plugins', () async { ... });

test('runLightweight per-plugin error does not abort run', () async {
  // Fixture: one plugin returns 500, another is fine.
  // Expected: ok=true, inputsAhead populated for the good one,
  //           error string mentions the bad plugin's dirName.
});
```

If the existing test file doesn't already inject a `configReader`, you'll need to add that ctor parameter (next step).

- [ ] **Step 2: Run tests, expect failure**

```
cd common && dart test test/services/update_check_service_test.dart -n "runLightweight walks active"
```

Expected: failures (config wiring not present, plugin walk not implemented).

- [ ] **Step 3: Add `configReader` ctor parameter to `UpdateCheckService`**

In `update_check_service.dart`:

```dart
UpdateCheckService({
  required this.flakePath,
  required this.statusPath,
  http.Client? httpClient,
  Future<NixblitzConfig?> Function()? configReader,
}) : _http = httpClient ?? http.Client(),
     _configReader = configReader ?? _defaultConfigReader;

final Future<NixblitzConfig?> Function() _configReader;

static Future<NixblitzConfig?> _defaultConfigReader() async {
  // Read config.json from flakePath. Adjust path to whatever the
  // existing dashboard read path uses (likely
  // `${flakePath}/config.json` — verify by grepping for
  // configProvider's underlying read).
  // TODO at impl time: import the same loader the dashboard uses
  // (e.g., ConfigService.read(...)) so we don't duplicate parsing
  // logic. If ConfigService isn't easy to call from here without
  // pulling in too much, write a small standalone JSON load.
  return null; // placeholder — replace with real read
}
```

**Implementation note:** prefer reusing whatever `configProvider` is built on. Grep `common/lib/src/providers/` and `common/lib/src/services/` for the canonical "read config.json from flakePath" call. If it's a method on `ConfigService` (likely), wire it through; if it's free-standing, factor a top-level helper.

- [ ] **Step 4: Walk plugins in `runLightweight()`**

After the existing `for (final entry in inputs) { ... }` loop, add:

```dart
final List<PluginAhead> pluginsAhead = [];
try {
  final config = await _configReader();
  if (config != null) {
    for (final p in config.plugins) {
      if (!p.enabled) continue;
      if (p.uninstalledAt != null) continue;
      if (!p.autoUpdate) continue;
      final li = lockedInputForPlugin(p);
      if (li == null) continue;
      try {
        final upstream = await _queryUpstreamRev(li);
        if (upstream == null) {
          errors.add('plugin ${p.dirName}: upstream not queryable');
          continue;
        }
        if (upstream != p.pinnedRev) {
          pluginsAhead.add(
            PluginAhead(
              dirName: p.dirName,
              currentRev: p.pinnedRev,
              upstreamRev: upstream,
              url: p.url,
            ),
          );
        }
      } catch (e, st) {
        LogService.error(
          'UpdateCheckService: plugin ${p.dirName} threw',
          e,
          st,
        );
        errors.add('plugin ${p.dirName}: $e');
      }
    }
  }
} catch (e, st) {
  LogService.error('UpdateCheckService: plugin walk failed', e, st);
  errors.add('plugin walk: $e');
}
```

Then update the `_merge(LightCheck(...))` call to include `pluginsAhead: pluginsAhead`.

Also update the final log line to include the plugin count:

```dart
LogService.info(
  'UpdateCheckService.runLightweight: ${ahead.length} inputs ahead, '
  '${pluginsAhead.length} plugins ahead, '
  '${errors.length} errors',
);
```

- [ ] **Step 5: Run trio**

If the `_defaultConfigReader` placeholder is still `return null`, the production path becomes a no-op (skips plugins). Replace that with the real reader from step 3 before considering the task complete.

- [ ] **Step 6: Sanity-check on a real install**

Run `nixblitz check light` once on a host with at least one installed plugin. Verify `update-status.json` now has a `plugins_ahead` array (possibly empty if everything is up to date). If it's missing entirely, the field-write isn't running — debug.

- [ ] **Step 7: Print commit message**

```
feat(common): runLightweight() walks active plugins

UpdateCheckService.runLightweight() now also probes the upstream
HEAD of every active, non-pinned plugin in config.json and writes
PluginAhead entries into LightCheck.pluginsAhead. Pinned, disabled,
and tombstoned plugins are skipped — pinned plugins are operator-
controlled, the others aren't part of the active config.

Errors per plugin accumulate into the existing LightCheck.error
string (same scheme as flake-input errors); a misbehaving plugin
doesn't abort the run.

The TUI menu surfaces these in the follow-up commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 4: Action-gating pure function

**Files:**

- Create: `tui/lib/src/ui/views/update/action_gating.dart`
- Create: `tui/test/ui/views/update/action_gating_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `tui/test/ui/views/update/action_gating_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/update/action_gating.dart';

const _tuiInputName = 'nixblitz';

void main() {
  group('computeUpdateActionStates', () {
    test('no status file → both actions enabled with "no full check yet"', () {
      final states = computeUpdateActionStates(
        UpdateStatus.empty(),
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.tuiOnly.enabled, isTrue);
      expect(states.entireSystem.enabled, isTrue);
      expect(states.entireSystem.subtitle, contains('no full check yet'));
    });

    test('heavy.noChanges true → entireSystem disabled', () {
      final status = UpdateStatus(
        heavy: HeavyCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          noChanges: true,
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.entireSystem.enabled, isFalse);
      expect(states.entireSystem.subtitle, contains('no changes'));
    });

    test('heavy fresh + diff non-empty → entireSystem enabled with count', () {
      final status = UpdateStatus(
        heavy: HeavyCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          diffText: '[U.] foo 1.0 -> 1.1\n[A.] bar 1.0\n',
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.entireSystem.enabled, isTrue);
      expect(states.entireSystem.subtitle, contains('2 changes'));
    });

    test('heavy stale + light has hits → entireSystem enabled with stale hint', () {
      final status = UpdateStatus(
        lightweight: LightCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          inputsAhead: [
            InputAhead(name: 'nixpkgs', currentRev: 'a' * 40,
                upstreamRev: 'b' * 40, url: ''),
          ],
        ),
        heavy: HeavyCheck(
          checkedAt: DateTime.utc(2026, 4, 1), // ~30 days old
          ok: true,
          noChanges: true,
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.entireSystem.enabled, isTrue);
      expect(states.entireSystem.subtitle, contains('heavy check stale'));
    });

    test('TUI input ahead → tuiOnly enabled', () {
      final status = UpdateStatus(
        lightweight: LightCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          inputsAhead: [
            InputAhead(name: 'nixblitz', currentRev: 'a' * 40,
                upstreamRev: 'b' * 40, url: ''),
          ],
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.tuiOnly.enabled, isTrue);
      expect(states.tuiOnly.subtitle, contains('ahead'));
    });

    test('TUI input not ahead → tuiOnly disabled', () {
      final status = UpdateStatus(
        lightweight: LightCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          inputsAhead: [
            InputAhead(name: 'nixpkgs', currentRev: 'a' * 40,
                upstreamRev: 'b' * 40, url: ''),
          ],
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.tuiOnly.enabled, isFalse);
      expect(states.tuiOnly.subtitle, contains('up to date'));
    });
  });
}
```

- [ ] **Step 2: Run the tests, expect failure**

```
cd tui && dart test test/ui/views/update/action_gating_test.dart
```

Expected: file doesn't exist; tests fail to compile.

- [ ] **Step 3: Implement `action_gating.dart`**

Create `tui/lib/src/ui/views/update/action_gating.dart`:

```dart
import 'package:common/common.dart';

/// Per-action gating result for the System Update menu.
class ActionState {
  const ActionState({required this.enabled, required this.subtitle});
  final bool enabled;
  final String subtitle;
}

/// Computed state for the two gated actions in `_buildSelectMode`.
class UpdateActionStates {
  const UpdateActionStates({
    required this.tuiOnly,
    required this.entireSystem,
  });
  final ActionState tuiOnly;
  final ActionState entireSystem;
}

/// Pure function — no I/O, no providers — derives the action panel's
/// gating from a snapshot of `update-status.json`.
///
/// [tuiInputName] is the name of the flake input that pins the TUI
/// binary (`nixblitz` for the default install). Filtering it out of
/// the "flake inputs" status row and into the "TUI binary" row is
/// done in the renderer; this function only consumes [LightCheck].
///
/// [now] is injected for testability.
UpdateActionStates computeUpdateActionStates(
  UpdateStatus status, {
  required String tuiInputName,
  DateTime? now,
}) {
  final wallClock = now ?? DateTime.now().toUtc();

  // ── tuiOnly ────────────────────────────────────────────────
  final light = status.lightweight;
  final tuiAhead = light != null && light.ok
      ? light.inputsAhead
            .where((i) => i.name == tuiInputName)
            .toList()
      : const <InputAhead>[];

  final ActionState tuiOnly = tuiAhead.isNotEmpty
      ? const ActionState(
          enabled: true,
          subtitle: 'TUI repo is ahead — rebuild advances it',
        )
      : ActionState(
          enabled: false,
          subtitle: light == null
              ? 'no light check yet'
              : 'up to date',
        );

  // ── entireSystem ────────────────────────────────────────────
  final heavy = status.heavy;
  late final ActionState entire;
  if (heavy == null) {
    entire = const ActionState(
      enabled: true,
      subtitle: 'no full check yet — press [C] to run one',
    );
  } else if (!heavy.ok) {
    entire = ActionState(
      enabled: true,
      subtitle: 'last full check failed: ${heavy.error ?? "unknown"}',
    );
  } else if (heavy.noChanges) {
    final heavyStale = wallClock.difference(heavy.checkedAt) >
        const Duration(days: 14);
    final lightHasOtherHits = (light != null && light.ok &&
        light.inputsAhead.where((i) => i.name != tuiInputName).isNotEmpty);
    if (heavyStale && lightHasOtherHits) {
      entire = const ActionState(
        enabled: true,
        subtitle: 'may have changes — heavy check stale (>14d)',
      );
    } else {
      entire = const ActionState(
        enabled: false,
        subtitle: 'no changes pending',
      );
    }
  } else {
    final n = _countDiffChanges(heavy.diffText);
    entire = ActionState(
      enabled: true,
      subtitle: n == 1 ? '1 change pending' : '$n changes pending',
    );
  }

  return UpdateActionStates(tuiOnly: tuiOnly, entireSystem: entire);
}

/// Counts `[U./A./R.]` lines — same heuristic as the inline diff
/// renderer in `update_view.dart`. Kept inline (not imported) so
/// `action_gating.dart` has no nocterm dependency.
int _countDiffChanges(String diffText) {
  var n = 0;
  for (final line in diffText.split('\n')) {
    if (line.startsWith('[U.') ||
        line.startsWith('[U]') ||
        line.startsWith('[A.') ||
        line.startsWith('[A]') ||
        line.startsWith('[R.') ||
        line.startsWith('[R]')) {
      n++;
    }
  }
  return n;
}
```

- [ ] **Step 4: Run trio**

Tests should pass; analyzer clean.

- [ ] **Step 5: Print commit message**

```
feat(tui): action_gating pure function for System Update menu

Extracts the cache-→-action-state derivation into a side-effect-free
function so it's testable without the nocterm harness. Returns
(enabled, subtitle) for the two gated actions:

  - "Update NixBlitz TUI only"  — gated on the TUI flake input being
                                   ahead.
  - "Update entire system"      — gated on heavy.diffText having
                                   real changes; "may have changes"
                                   override when heavy is stale
                                   (>14d) and light has other hits.

Pure Dart, no nocterm imports — lives under src/ui/views/update/
to keep it next to the only consumer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 5: Status panel rendering

**Files:**

- Modify: `tui/lib/src/ui/views/update_view.dart`

This task only adds the panel; the action panel rewrite + gating wire-up happens in Task 6. After this task lands, the menu will render the new Status panel above the existing (unchanged) action list.

- [ ] **Step 1: Add `_buildStatusPanel` helper**

Inside `_UpdateViewState` in `update_view.dart`, add a new method (place near `_buildPendingRows` / `_buildSelectMode`):

```dart
/// Renders the Status panel — top of the System Update menu.
/// Reads `readUpdateStatus()` synchronously each rebuild (cheap
/// file read; same pattern the dashboard banner uses).
List<Component> _buildStatusPanel(BuildContext context) {
  const tuiInputName = 'nixblitz';
  final status = readUpdateStatus();
  final children = <Component>[
    Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: const [
        Text(
          'Status',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
        Text(
          '[c] check now   [C] full check',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      ],
    ),
    const SizedBox(height: 1),
  ];

  final hasLight = status.lightweight != null && status.lightweight!.ok;
  final hasHeavy = status.heavy != null && status.heavy!.ok;

  if (!hasLight && !hasHeavy) {
    children.add(
      const Text(
        '  no cached check yet — runs daily',
        style: TextStyle(color: Color.fromRGB(150, 150, 180)),
      ),
    );
    return children;
  }

  if (hasLight) {
    final light = status.lightweight!;
    final stillAhead = UpdateCheckService.filterStillAhead(
      light.inputsAhead,
      flakePath: context.read(baseDirProvider),
    );

    // flake inputs row — exclude the TUI input.
    final nonTui = stillAhead.where((e) => e.name != tuiInputName).toList();
    final lightAge = _humanizeAge(light.checkedAt);
    final lightStale = DateTime.now().toUtc().difference(light.checkedAt) >
        const Duration(days: 2);
    final flakeValue = nonTui.isEmpty
        ? 'up to date'
        : nonTui.map((e) => e.name).take(3).join(', ') +
              (nonTui.length > 3 ? ' (+${nonTui.length - 3} more)' : '');
    children.add(
      _statusRow(
        label: 'flake inputs',
        value: flakeValue,
        age: lightAge,
        stale: lightStale,
      ),
    );

    // TUI binary row — only the TUI input.
    final tuiAhead = stillAhead.where((e) => e.name == tuiInputName).toList();
    final tuiValue = tuiAhead.isEmpty
        ? 'up to date'
        : 'ahead — pull and rebuild';
    children.add(
      _statusRow(
        label: 'TUI binary',
        value: tuiValue,
        age: lightAge,
        stale: lightStale,
      ),
    );

    // Plugin pointer row — only when pluginsAhead non-empty.
    if (light.pluginsAhead.isNotEmpty) {
      final n = light.pluginsAhead.length;
      children.add(const SizedBox(height: 1));
      children.add(
        Text(
          '  ! $n plugin update${n == 1 ? "" : "s"} available — '
          'open [p] plugins menu',
          style: const TextStyle(color: Color.fromRGB(247, 147, 26)),
        ),
      );
    }
  }

  if (hasHeavy) {
    final heavy = status.heavy!;
    final heavyAge = _humanizeAge(heavy.checkedAt);
    final heavyStale = DateTime.now().toUtc().difference(heavy.checkedAt) >
        const Duration(days: 14);
    final String heavyValue;
    if (heavy.noChanges) {
      heavyValue = 'no system changes';
    } else if (heavy.diffText.trim().isEmpty) {
      heavyValue = 'no system changes';
    } else {
      heavyValue = '${_countDiffChanges(heavy.diffText)} changes pending';
    }
    children.add(
      _statusRow(
        label: 'system closure',
        value: heavyValue,
        age: heavyAge,
        stale: heavyStale,
      ),
    );
  } else {
    children.add(
      _statusRow(
        label: 'system closure',
        value: 'no full check yet',
        age: '—',
        stale: false,
      ),
    );
  }

  return children;
}

Component _statusRow({
  required String label,
  required String value,
  required String age,
  required bool stale,
}) {
  // Match the existing _pendingRow padding (14-char label).
  final padded = label.padRight(14);
  final prefix = stale ? '! ' : '  ';
  final color = stale
      ? const Color.fromRGB(220, 180, 100) // warn yellow
      : const Color.fromRGB(200, 200, 200);
  return Text(
    '$prefix$padded$value  ($age)',
    style: TextStyle(color: color),
  );
}
```

- [ ] **Step 2: Wire `_buildStatusPanel` into `_buildSelectMode`**

Replace the current "Pending" section (the `Text('Pending', ...)` + `...pendingRows` + spacer block) with:

```dart
...
// Replaces the previous _buildPendingRows block.
...(_buildStatusPanel(context)),
const SizedBox(height: 1),
...
```

The action list and hint stay where they are for now; Task 6 rewrites them.

- [ ] **Step 3: Delete the now-unused `_buildPendingRows` and `_pendingRow`**

The Status panel supersedes them. Search for callers; only `_buildSelectMode` should reference them.

- [ ] **Step 4: Run trio**

The visual change is non-trivial — also do a manual sanity pass:

```
just run                        # boot the TUI in this checkout
```

Open the System Update menu and visually confirm:

- "Status" header with `[c] check now   [C] full check` on the right.
- Three rows under it (flake inputs / TUI binary / system closure).
- Plugin pointer row appears only when `pluginsAhead` is non-empty (use `nixblitz check light` on a host with a plugin behind upstream to seed it, or hand-edit `update-status.json` for a quick visual test).
- Stale rows render in yellow with leading `!`.

- [ ] **Step 5: Print commit message**

```
feat(tui): Status panel for System Update menu

Replaces the previous "Pending" section in the System Update menu
with a richer Status panel: three rows (flake inputs / TUI binary /
system closure) plus a plugin-pointer row that only shows when
LightCheck.pluginsAhead is non-empty. The TUI binary row is the
"nixblitz" flake input filtered out of the flake-inputs row, so the
two rows don't double-count.

Stale rows (light >2d, heavy >14d) render in warn-yellow with a
leading `!` so the operator can tell when the cache is old.

Action list unchanged in this commit — gating + soft-disabled lands
in the next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 6: Action panel rewrite — gating + soft-disabled

**Files:**

- Modify: `tui/lib/src/ui/views/update_view.dart`

- [ ] **Step 1: Add transient override-confirmation state**

Inside `_UpdateViewState`, near the existing instance fields:

```dart
/// Index of the action row whose "press Enter again to override"
/// prompt is currently armed. Reset to null when the user changes
/// selection or runs the action. Plain instance variable (NOT a
/// StateProvider) per nocterm rules — see CLAUDE.md.
int? _overrideArmedFor;
```

- [ ] **Step 2: Rewrite the action list rendering and key handler in `_buildSelectMode`**

Replace the action-list `List.generate` block + the trailing hint switch with:

```dart
// Compute gating from cache (pure function from action_gating.dart).
final actionStates = computeUpdateActionStates(
  readUpdateStatus(),
  tuiInputName: 'nixblitz',
);

// Action option metadata, paired with its computed state.
final options = <_Option>[
  _Option(
    label: 'Update NixBlitz TUI only',
    state: actionStates.tuiOnly,
    runAction: () => _startUpdate(true),
  ),
  _Option(
    label: 'Update entire system',
    state: actionStates.entireSystem,
    runAction: () => _startUpdate(false),
  ),
  _Option(
    label: 'Cancel',
    state: const ActionState(enabled: true, subtitle: ''),
    runAction: () {
      context.read(currentViewProvider.notifier).state = AppView.dashboard;
    },
  ),
];

...

// Render each row.
...List.generate(options.length, (i) {
  final opt = options[i];
  final selected = i == selection;
  final isOverrideArmed = _overrideArmedFor == i;
  final prefix = selected ? '> ' : '  ';
  final mainColor = !opt.state.enabled
      ? const Color.fromRGB(120, 120, 120)
      : selected
          ? const Color.fromRGB(247, 147, 26)
          : const Color.fromRGB(200, 200, 200);
  final subtitle = isOverrideArmed
      ? 'no changes — press Enter again to rebuild anyway'
      : opt.state.subtitle;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$prefix${opt.label}',
        style: TextStyle(color: mainColor),
      ),
      if (subtitle.isNotEmpty)
        Text(
          '    $subtitle',
          style: TextStyle(
            color: isOverrideArmed
                ? const Color.fromRGB(220, 180, 100)
                : const Color.fromRGB(150, 150, 180),
          ),
        ),
    ],
  );
}),
```

- [ ] **Step 3: Update the key handler**

Replace the existing `LogicalKey.enter` arm in `_buildSelectMode`'s key handler with:

```dart
if (event.logicalKey == LogicalKey.enter) {
  final opt = options[selection];
  if (opt.state.enabled || _overrideArmedFor == selection) {
    _overrideArmedFor = null;
    opt.runAction();
  } else {
    // Soft-disabled — first Enter arms, second runs.
    _overrideArmedFor = selection;
  }
  return true;
}
```

Update the j/k navigation to clear the override flag on selection change:

```dart
if (event.logicalKey == LogicalKey.keyJ ||
    event.logicalKey == LogicalKey.arrowDown) {
  if (selection < options.length - 1) {
    _overrideArmedFor = null;
    context.read(_updateSelectionProvider.notifier).state = selection + 1;
  }
  return true;
}
// ...same for arrowUp / keyK
```

- [ ] **Step 4: Add the local `_Option` class**

Outside `_UpdateViewState` (file scope, top-level private):

```dart
class _Option {
  const _Option({
    required this.label,
    required this.state,
    required this.runAction,
  });
  final String label;
  final ActionState state;
  final void Function() runAction;
}
```

- [ ] **Step 5: Drop the "Refresh plugins only" + "Refresh templates" entries**

The `options` list above already has them removed; just confirm `_refreshPluginsOnly` and `_refreshTemplates` are no longer reachable from `_buildSelectMode`. Their bodies stay (the templates body becomes the helper extracted in Task 10; the plugin-only entry can be marked deprecated and removed in a follow-up if it's not reused — for this pass, leave the function but make sure no UI code references it).

- [ ] **Step 6: Run trio + manual smoke**

Trio passes; visually verify in `just run`:

- Hit Enter on `Update entire system` while heavy.noChanges: row stays put, subtitle changes to "no changes — press Enter again to rebuild anyway".
- Press j to move down: subtitle reverts to "no changes pending"; pressing Enter again does NOT trigger the action (override was disarmed).
- With heavy.diffText non-empty, action is enabled, Enter runs it directly.

- [ ] **Step 7: Print commit message**

```
feat(tui): cache-driven action gating in System Update menu

The five-item action list is reduced to three: Update NixBlitz TUI
only, Update entire system, Cancel. The "refresh plugins" and
"refresh templates" routine actions are gone — plugins live in
their own menu, templates auto-rewrite at the end of every Update
flow.

Each non-cancel action's enabled state is now driven by the cache:
TUI-only follows the nixblitz flake input, entire-system follows
heavy.diffText / heavy.noChanges. Disabled rows render in dim grey
with a "no changes pending" subtitle.

Soft-disabled override: first Enter on a disabled row arms a
"press Enter again to rebuild anyway" prompt; second confirms,
moving selection (j/k) disarms. Plain instance variable, not a
StateProvider — setting StateProvider mid-handler nukes the rest
of the handler (CLAUDE.md, Nocterm Pitfalls #1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 7: Manual lightweight check `[c]`

**Files:**

- Modify: `tui/lib/src/ui/views/update_view.dart`

- [ ] **Step 1: Add a "running light check" transient flag**

Inside `_UpdateViewState`:

```dart
/// True while a `[c]` lightweight check is in flight. Drives an
/// inline spinner above the Status panel; nothing dispatches on
/// completion beyond a setState-equivalent forceRefresh — the panel
/// re-reads update-status.json on every rebuild.
bool _lightCheckRunning = false;
```

- [ ] **Step 2: Wire `[c]` keybind in `_buildSelectMode`**

Add to the key handler (after `[C]` if present, before `[v]`):

```dart
if (event.logicalKey == LogicalKey.keyC) {
  // Both [c] and [C] map to keyC in nocterm — disambiguate by
  // checking the modifier. Lowercase 'c' is no-shift; uppercase
  // 'C' is shift. (KeyboardEvent has a .character or .shift
  // accessor — verify in implementation.)
  if (event.shift) {
    _onHeavyCheckRequested();
  } else {
    _onLightCheckRequested();
  }
  return true;
}
```

**Implementation note:** check the `KeyboardEvent` class in the nocterm source for the exact API for shift detection. If shift isn't directly available, key off the character (`event.character == 'C'` vs `'c'`). Look at how other views handle case-sensitive bindings — `dashboard_view.dart`'s `[r]` (refresh) vs `[R]` (if any) is a good reference.

- [ ] **Step 3: Implement `_onLightCheckRequested`**

```dart
Future<void> _onLightCheckRequested() async {
  if (_lightCheckRunning) return; // re-entrancy guard
  _lightCheckRunning = true;
  // Trigger a rebuild so the spinner appears. We deliberately use
  // a private "ticker" provider rather than directly mutating
  // selection/mode state.
  context.read(_updateTickerProvider.notifier).state++;

  try {
    final svc = UpdateCheckService(
      flakePath: context.read(baseDirProvider),
      statusPath: updateStatusPath,
    );
    try {
      await svc.runLightweight();
    } finally {
      svc.close();
    }
  } catch (e, st) {
    LogService.error('manual light check failed', e, st);
  } finally {
    _lightCheckRunning = false;
    // Bump the ticker again so the panel re-reads the new status.
    context.read(_updateTickerProvider.notifier).state++;
  }
}
```

- [ ] **Step 4: Add the ticker provider**

Near the other private providers at the top of `update_view.dart`:

```dart
/// Increments to force `_buildSelectMode` to re-read the status file
/// after a manual `[c]` / `[C]` check completes. Cheap repaint.
final _updateTickerProvider = StateProvider<int>((ref) => 0);
```

In `_buildSelectMode`, watch it so the panel rebuilds:

```dart
context.watch(_updateTickerProvider);
```

- [ ] **Step 5: Render an inline spinner during a light check**

In `_buildStatusPanel`, prepend a one-line spinner row when `_lightCheckRunning` is true:

```dart
if (_lightCheckRunning) {
  children.insert(
    0,
    Spinner(label: 'Checking for updates…'),
  );
  children.insert(1, const SizedBox(height: 1));
}
```

(Hoist `_lightCheckRunning` into a parameter or read it inside `_buildStatusPanel` — the helper is on `_UpdateViewState` already, so it can read the field directly.)

- [ ] **Step 6: Run trio + manual smoke**

In `just run`, open System Update, press `c`. Verify:

- Spinner appears.
- After ~3-5s the spinner disappears and the Status panel shows fresh `(light just now)` ages on the rows.

- [ ] **Step 7: Print commit message**

```
feat(tui): [c] runs lightweight update check from menu

A new keybind in the System Update menu's selectMode runs
UpdateCheckService.runLightweight() in-process — same code the
systemd timer's `nixblitz check light` command runs, just fired
on demand. The TUI runs as `admin` per the standard install (see
templates/modules/system/operator.nix), and update-status.json is
admin-owned, so the in-process write works without escalation.

Inline spinner above the Status panel during the run; the panel
auto-repaints with fresh `(just now)` ages on completion. A
re-entrancy guard prevents stacking checks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 8: Manual heavy check `[C]` — confirmation + new running mode

**Files:**

- Modify: `tui/lib/src/ui/views/update_view.dart`

- [ ] **Step 1: Add `_UpdateMode.runningCheck` and `_UpdateMode.heavyConfirm`**

Extend the enum at the top of the file:

```dart
enum _UpdateMode {
  selectMode,
  heavyConfirm,           // NEW — yes/no prompt before runHeavy
  runningCheck,           // NEW — spinner + scrolling journal output
  viewingCachedDiff,
  running,
  previewing,
  applying,
  done,
}
```

- [ ] **Step 2: Wire the dispatch in `build()`**

Add cases in the `switch (mode)`:

```dart
_UpdateMode.heavyConfirm => _buildHeavyConfirm(),
_UpdateMode.runningCheck => _buildRunningCheck(),
```

- [ ] **Step 3: Implement `_buildHeavyConfirm`**

```dart
Component _buildHeavyConfirm() {
  return Focusable(
    focused: true,
    onKeyEvent: (event) {
      try {
        if (event.logicalKey == LogicalKey.keyY) {
          _startHeavyCheck();
          return true;
        }
        if (event.logicalKey == LogicalKey.keyN ||
            event.logicalKey == LogicalKey.escape) {
          context.read(_updateModeProvider.notifier).state =
              _UpdateMode.selectMode;
          return true;
        }
        return false;
      } catch (e, st) {
        LogService.error('Heavy confirm key handler failed', e, st);
        return true;
      }
    },
    child: Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Run full check?',
            style: TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 1),
          Text(
            'Takes 1–10 minutes. Downloads ~125 MB to /tmp.',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
          SizedBox(height: 1),
          Text(
            '[y] Yes   [n / Esc] No',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 4: Implement `_startHeavyCheck`**

```dart
void _startHeavyCheck() {
  context.read(_updateOutputProvider.notifier).state = [];
  context.read(_updateModeProvider.notifier).state =
      _UpdateMode.runningCheck;

  // Shell out to systemd so the check runs as admin under the same
  // env the scheduled timer uses — see spec section "Manual check
  // triggers" / verification item 3.
  final p = Process.start(
    'systemctl',
    const ['start', '--wait', 'nixblitz-check-heavy.service'],
    runInShell: false,
  );

  p.then((proc) {
    final stdoutSub = proc.stdout
        .transform(systemEncoding.decoder)
        .transform(const LineSplitter())
        .listen(_appendUpdateLine);
    final stderrSub = proc.stderr
        .transform(systemEncoding.decoder)
        .transform(const LineSplitter())
        .listen(_appendUpdateLine);
    proc.exitCode.then((code) async {
      await stdoutSub.cancel();
      await stderrSub.cancel();
      _appendUpdateLine('');
      _appendUpdateLine('— heavy check finished (exit $code) —');
      // Bump the ticker so the Status panel re-reads the file.
      context.read(_updateTickerProvider.notifier).state++;
      // Don't auto-leave runningCheck — let the operator read the
      // tail. They press Esc to return.
    });
  }).catchError((e, st) {
    LogService.error('failed to start nixblitz-check-heavy', e, st);
    _appendUpdateLine('error: $e');
  });
}
```

Required imports at the top:

```dart
import 'dart:convert' show LineSplitter, systemEncoding;
```

- [ ] **Step 5: Implement `_buildRunningCheck`**

```dart
Component _buildRunningCheck() {
  final outputLines = context.watch(_updateOutputProvider);
  return Focusable(
    focused: true,
    onKeyEvent: (event) {
      try {
        if (event.logicalKey == LogicalKey.escape) {
          context.read(_updateModeProvider.notifier).state =
              _UpdateMode.selectMode;
          return true;
        }
        return false;
      } catch (e, st) {
        LogService.error('runningCheck key handler failed', e, st);
        return true;
      }
    },
    child: Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Spinner(label: 'Running full update check…'),
          const SizedBox(height: 1),
          const Text(
            'Heavy check evaluates a full system rebuild in /tmp '
            'and runs `nvd diff` against /run/current-system. Takes '
            '1–10 minutes; can be left running while you do other '
            'things.',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
          const SizedBox(height: 1),
          Expanded(child: ScrollableLog(lines: outputLines, focused: true)),
          const SizedBox(height: 1),
          const Text(
            '[Esc] back to menu',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 6: Wire the `[C]` arm in `_buildSelectMode`**

In the key handler:

```dart
if (event.logicalKey == LogicalKey.keyC && event.shift) {
  context.read(_updateModeProvider.notifier).state = _UpdateMode.heavyConfirm;
  return true;
}
```

(Place this above the `[c]` handler arm so the shifted variant takes precedence.)

- [ ] **Step 7: Run trio + manual smoke**

In `just run`:

- Press `Shift+C` from System Update → confirm prompt.
- Press `n` → returns to menu.
- Press `Shift+C` again → press `y` → switches to runningCheck mode, spinner + log output.
- Watch journal output stream in. (Tail-test from another terminal: `journalctl -u nixblitz-check-heavy -f`.)
- After completion, press Esc → back to menu, Status panel shows fresh `(heavy just now)`.

- [ ] **Step 8: Print commit message**

```
feat(tui): [C] runs heavy update check from menu

A `[C]` (Shift+C) keybind in the System Update menu opens a
confirm prompt ("Takes 1–10 min, downloads ~125 MB to /tmp."), and
on yes shells out to `systemctl start --wait
nixblitz-check-heavy.service`. Same User=admin env as the weekly
timer, no in-process eval / sudo dance.

Output streams into a new _UpdateMode.runningCheck — spinner +
ScrollableLog (reuses the same widget the running-Update flow
uses). On completion the Status panel auto-repaints; the operator
presses Esc when they're done reading the tail.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 9: `[p]` chord to plugins menu

**Files:**

- Modify: `tui/lib/src/ui/views/update_view.dart`

- [ ] **Step 1: Find the plugins-menu AppView**

Grep for `AppView.` in `tui/lib/src/providers/ui_state_provider.dart` to confirm the enum value name (likely `AppView.plugins`).

```
grep -n "AppView\." tui/lib/src/providers/ui_state_provider.dart
```

- [ ] **Step 2: Wire `[p]` in `_buildSelectMode`'s key handler**

Add (above the `[Esc]` arm):

```dart
if (event.logicalKey == LogicalKey.keyP) {
  context.read(currentViewProvider.notifier).state = AppView.plugins;
  return true;
}
```

- [ ] **Step 3: Run trio + manual smoke**

In `just run`: System Update menu, press `p`. Should land on the plugins menu. From the plugins menu, the existing back-key (likely Esc) returns to the dashboard, not back to System Update — that's fine, matches the chord-not-modal model.

- [ ] **Step 4: Print commit message**

```
feat(tui): [p] from System Update opens plugins menu

The plugin pointer row in the Status panel mentions "[p] plugins
menu"; this commit makes the keybind real. Plain navigation —
swaps currentViewProvider to AppView.plugins. From the plugins
menu the operator returns to the dashboard via the existing back
flow, not back to System Update; that mirrors how every other
view-to-view chord works in this TUI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 10: Template auto-rewrite at end of Update flow

**Files:**

- Modify: `tui/lib/src/ui/views/update_view.dart`

- [ ] **Step 1: Locate the post-success hook**

Grep for `_completeWithSuccess`, `_UpdateMode.done`, and the function that transitions an Update flow to the `done` state:

```
grep -n "_completeWithSuccess\|_UpdateMode.done" tui/lib/src/ui/views/update_view.dart
```

Find the path through `_runRebuild` (or similar) that runs `nixos-rebuild switch` and on success transitions to `_UpdateMode.done`. This is where we hook the auto-rewrite.

- [ ] **Step 2: Extract `_refreshTemplates` body into a reusable helper**

Find the existing `_refreshTemplates` method. Its body currently writes embedded templates over disk and commits. Refactor:

```dart
Future<bool> _maybeAutoRewriteTemplates() async {
  // Only fires when the dashboard's drift detector says we have
  // templates that differ between the embedded copies and disk.
  // In steady state this is no-op — drift-banner-on-dashboard
  // catches the edge cases manually.
  final drift = context.read(templatesDriftProvider);
  if (!drift.hasDrift) return false;

  try {
    final baseDirPath = context.read(baseDirProvider);
    // ... move the writeAll + scoped commit logic from
    // _refreshTemplates into here.
    return true;
  } catch (e, st) {
    LogService.error('auto-rewrite templates failed', e, st);
    return false;
  }
}
```

`_refreshTemplates` (the old top-level entry that used to be called from selectMode) is no longer reachable from the menu (we removed it in Task 6). Either delete it or keep it as a thin wrapper that calls `_maybeAutoRewriteTemplates` for the case where someone wires up a recovery keybind in the future. **Recommended:** delete it; recovery is via the dashboard `[r]` chord, which has its own path.

- [ ] **Step 3: Call the helper from the post-success hook**

In whichever function transitions to `_UpdateMode.done` after a successful rebuild — the function found in step 1 — add a call to `_maybeAutoRewriteTemplates()` before the mode transition. Append a line to the output stream so the operator sees what happened:

```dart
final autorewrote = await _maybeAutoRewriteTemplates();
if (autorewrote) {
  _appendUpdateLine('');
  _appendUpdateLine('Auto-rewrote drifted templates.');
}
context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
```

- [ ] **Step 4: Run trio + manual smoke**

Manual: bump a template file in the binary (e.g., add a comment to a `templates/modules/system/...` file), `just run`, run "Update entire system". After rebuild completes, check the output log for "Auto-rewrote drifted templates." Verify the dashboard drift banner is gone after returning.

- [ ] **Step 5: Print commit message**

```
feat(tui): auto-rewrite drifted templates after Update

The "Refresh Nix templates" routine action is gone from the System
Update menu (Task 6). Replace its workflow with an implicit hook:
at the end of every successful Update flow (TUI-only or entire
system), if templatesDriftProvider reports drift, the same
write-templates-over-disk + scoped-commit code runs implicitly —
no operator interaction.

The dashboard drift banner stays as a fail-safe. In steady state
it should never fire; if it does, that's a bug to chase.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 11: Drop plugin auto-refresh from "Update entire system"

**Files:**

- Modify: `tui/lib/src/ui/views/update_view.dart`

The current "Update entire system" path calls `_refreshPluginsThenPreview` first — refresh all auto-update plugins, commit the scoped diff, then preview. Per spec, plugin updates are out of the System Update flow entirely. The only path that should run for entire-system is `_previewSystemUpdate(nixblitzOnly: false)`.

- [ ] **Step 1: Simplify `_startUpdate`**

Replace the body:

```dart
sudo.ensureFresh().then((ok) {
  if (!ok) {
    _appendUpdateLine('Authorization cancelled — aborting update.');
    _failToDone(1);
    return;
  }
  if (nixblitzOnly) {
    _previewSystemUpdate(baseDirPath, nixblitzOnly: true);
  } else {
    _refreshPluginsThenPreview(baseDirPath);  // <-- remove this branch
  }
});
```

…with:

```dart
sudo.ensureFresh().then((ok) {
  if (!ok) {
    _appendUpdateLine('Authorization cancelled — aborting update.');
    _failToDone(1);
    return;
  }
  _previewSystemUpdate(baseDirPath, nixblitzOnly: nixblitzOnly);
});
```

- [ ] **Step 2: Delete `_refreshPluginsThenPreview` and `_runPluginRefreshOnly`**

Both are now unreachable. Delete the methods. Look for any remaining references in tests or documentation; update if found.

- [ ] **Step 3: Run trio + manual smoke**

Manual: `just run`, install a plugin (or skip if no plugin work-flow at hand), run "Update entire system". Verify the output log no longer contains the `> nixblitz plugin refresh ...` lines that used to precede the flake update.

- [ ] **Step 4: Print commit message**

```
refactor(tui): drop plugin auto-refresh from "Update entire system"

System Update is now strictly about flake-input updates + system
rebuild. Plugin updates live in the plugins menu — refresh there,
hit Apply from there. The Status panel's plugin pointer row links
to the plugins menu via [p] for discovery (Task 9).

Removes _refreshPluginsThenPreview and _runPluginRefreshOnly. The
old "Refresh plugins only" menu action was already removed in
Task 6; this commit also cleans up the function bodies.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 12: Final verification + plan-completion sweep

**Files:** none (verification + cleanup only).

- [ ] **Step 1: Run the trio one more time**

```
just test
just analyze
just format
```

- [ ] **Step 2: Verify spec coverage**

Re-read the spec. Walk through each section and tick off:

- [ ] Status panel rows render: flake inputs / TUI binary / system closure / (plugin pointer when applicable).
- [ ] Stale rows render in yellow with `!`.
- [ ] Status file missing → "no cached check yet" line shown.
- [ ] Action panel: TUI-only gated on TUI flake input; entire-system gated on heavy.diffText / heavy.noChanges; stale heavy + light hits → "may have changes — heavy check stale".
- [ ] Soft-disabled override: first Enter arms, second runs, j/k disarms.
- [ ] `[c]` runs lightweight in-process; `[C]` shells out to systemctl with confirm prompt.
- [ ] `[p]` chord opens plugins menu.
- [ ] Template auto-rewrite fires at end of every successful Update.
- [ ] Plugin auto-refresh dropped from "Update entire system".
- [ ] `LightCheck.pluginsAhead` populated by `runLightweight()`.
- [ ] Backward-compat: status files without `plugins_ahead` still parse.

- [ ] **Step 3: Double-check the dashboard drift banner**

`just run`, manually drift a template (edit `~/nixblitz/modules/.../foo.nix`), return to dashboard. Banner should still fire — Task 10's auto-rewrite hooks the post-Update path, NOT startup, so manual disk drift is still surfaced.

- [ ] **Step 4: Print final commit message**

If you've batched any leftover formatter / cleanup churn from across all tasks into a final commit:

```
chore: format pass + tidy comments after update-menu redesign

(Cleanup commit covering whatever the formatter rewrote across the
various touched files during the redesign.)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

If no leftover churn, skip step 4.

- [ ] **Step 5: Plan complete — hand back to the user**

Summarise to the user:

- What shipped (12-bullet recap of the task list).
- Anything that diverged from the spec (rare, but call out if a verification item resolved differently than the spec assumed).
- Outstanding follow-ups (e.g., should "Refresh templates" become a recovery-only entry under the debug menu? Out of scope here, but worth a note.)

---

## Self-review notes

(See spec self-review at the bottom of `2026-05-04-system-update-menu-redesign-design.md` for the spec-side rigor pass.)

The plan above assumes:

1. The `KeyboardEvent` class in nocterm exposes a `.shift` accessor for distinguishing `[c]` from `[C]`. If it doesn't, fall back to `event.character == 'C'` — same outcome.
2. The TUI's `runtime user` is `admin` — verified in `templates/modules/system/operator.nix`. If a future install lets the operator override that, `[c]`'s in-process write may need to fall back to `systemctl start nixblitz-check-light.service`, mirroring `[C]`. Not required for this pass.
3. `templatesDriftProvider` is reactive and re-evaluates after the auto-rewrite touches files — verify by checking it in `tui/lib/src/providers/`. If it caches and doesn't invalidate on disk changes, the post-Update branch needs a `ref.invalidate(templatesDriftProvider)` after the rewrite.
