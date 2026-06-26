# Plugin Teardown Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a plugin-declared teardown action on the live system, before the rebuild that removes the plugin, so disabling/uninstalling a network plugin (Tailscale, NetBird) cleans up DNS/routes instead of leaving the node dirty and hanging the rebuild.

**Architecture:** A new optional `teardown` manifest field names one of the plugin's own actions. The Apply flow diffs the committed `plugins.list` against the current one to find plugins being removed this rebuild, resolves each one's teardown action, and runs it via the existing `PluginActionRunner` after the git commit but before `nix flake lock` / `nixos-rebuild`. Detection/resolution logic lives in `common` (unit-tested); the Apply flow orchestrates and streams output.

**Tech Stack:** Dart (`common` + `tui` packages), Riverpod, nocterm; Nix (plugin modules in the separate `nixblitz_official_plugins` repo).

## Global Constraints

- **Two repos.** Tasks 1–3 are in the main repo (`/home/f44/dev/blitz/nixblitz`). Tasks 4–5 are in the nested separate repo `examples_redesign/nixblitz_official_plugins/` (remote `forge.f44.fyi/f44/nixblitz_official_plugins`).
- **Commits are the user's.** Do NOT run `jj`/`git commit`. Each task ends by running the verification gate and presenting a ready-to-paste commit message (subject + why-focused body + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`). The user squashes/commits manually.
- **Main-repo verification gate** (CLAUDE.md): after each main-repo task, run `just test`, `just analyze`, `just format` (in that order); all green before presenting the message.
- **Architecture split:** business logic (detection/resolution + `Process` work) lives in `common`; `tui` only orchestrates + renders. `common` is the only package that calls `Process`.
- **Teardown is best-effort:** a missing/failed/timed-out teardown logs a warning and continues to the rebuild. It must never block Apply.
- **nocterm:** the teardown loop runs inside an existing `async` `.then()` continuation in `apply_view.dart` (not a raw `onKeyEvent`), so `await` is allowed there. Stream output via the existing `_append`.

---

### Task 1: Manifest `teardown` field + validation (`common`)

**Files:**

- Modify: `common/lib/src/models/plugin/plugin_manifest.dart`
- Test: `common/test/models/plugin_manifest_test.dart`

**Interfaces:**

- Consumes: existing `PluginManifest`, `PluginAction` (`action.inputs` is `List<PluginActionInput>`).
- Produces: `PluginManifest.teardown` (`String?`) — the id of an action in the same manifest to auto-run on removal. Guaranteed by parse-time validation to reference an existing input-free action when non-null.

- [ ] **Step 1: Write the failing tests**

Append these tests inside the existing `group('PluginManifest.fromJson', () {` block in `common/test/models/plugin_manifest_test.dart`:

```dart
test('parses a teardown referencing an input-free unit action', () {
  final m = PluginManifest.fromJson({
    'manifest': {'schema_version': 4, 'min_tui_version': 1, 'name': 'p'},
    'actions': {
      'down': {'label': 'Disconnect', 'unit': 'p-down.service'},
    },
    'permissions': {
      'privileged_units': ['p-down.service'],
    },
    'teardown': 'down',
  });
  expect(m.teardown, 'down');
});

test('absent teardown parses as null', () {
  final m = PluginManifest.fromJson({
    'manifest': {'schema_version': 4, 'min_tui_version': 1, 'name': 'p'},
  });
  expect(m.teardown, isNull);
});

test('teardown referencing an unknown action throws', () {
  expect(
    () => PluginManifest.fromJson({
      'manifest': {'schema_version': 4, 'min_tui_version': 1, 'name': 'p'},
      'teardown': 'nope',
    }),
    throwsA(isA<FormatException>()),
  );
});

test('teardown action with inputs throws', () {
  expect(
    () => PluginManifest.fromJson({
      'manifest': {'schema_version': 4, 'min_tui_version': 1, 'name': 'p'},
      'actions': {
        'connect': {
          'label': 'Connect',
          'unit': 'p-connect.service',
          'inputs': [
            {'name': 'key', 'label': 'Key', 'type': 'secret'},
          ],
        },
      },
      'permissions': {
        'privileged_units': ['p-connect.service'],
      },
      'teardown': 'connect',
    }),
    throwsA(isA<FormatException>()),
  );
});

test('teardown round-trips through toJson', () {
  final m = PluginManifest.fromJson({
    'manifest': {'schema_version': 4, 'min_tui_version': 1, 'name': 'p'},
    'actions': {
      'down': {'label': 'Disconnect', 'unit': 'p-down.service'},
    },
    'permissions': {
      'privileged_units': ['p-down.service'],
    },
    'teardown': 'down',
  });
  expect(m.toJson()['teardown'], 'down');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/models/plugin_manifest_test.dart -n teardown`
Expected: FAIL — `m.teardown` getter doesn't exist (compile error) / unknown field.

- [ ] **Step 3: Add the field, constructor param, parse+validate, and toJson**

In `plugin_manifest.dart`, add the field after `branches` (around line 168):

```dart
  /// Optional id of an action (in this manifest's [actions]) to run
  /// automatically on the live system when the plugin is being
  /// removed (disabled or uninstalled), before the rebuild drops its
  /// module. Null when the plugin declares no teardown. Validated at
  /// parse time: when set it references an existing action with no
  /// inputs (teardown runs non-interactively and cannot prompt).
  final String? teardown;
```

Add the constructor parameter (after `this.branches,`):

```dart
    this.teardown,
```

In `fromJson`, after the `branches` block (around line 399, before `return PluginManifest(`), add:

```dart
    final rawTeardown = json['teardown'];
    String? teardown;
    if (rawTeardown != null) {
      if (rawTeardown is! String || rawTeardown.isEmpty) {
        throw const FormatException(
          'manifest.teardown must be a non-empty action id when present',
        );
      }
      final action = actionMap[rawTeardown];
      if (action == null) {
        throw FormatException(
          'manifest.teardown references unknown action `$rawTeardown`',
        );
      }
      if (action.inputs.isNotEmpty) {
        throw FormatException(
          'manifest.teardown action `$rawTeardown` declares inputs; '
          'teardown runs non-interactively and cannot prompt',
        );
      }
      teardown = rawTeardown;
    }
```

Add `teardown: teardown,` to the `return PluginManifest(...)` call (after `branches: branches,`).

In `toJson()`, add before the closing `};` (after the `branches` line):

```dart
    if (teardown != null) 'teardown': teardown,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd common && dart test test/models/plugin_manifest_test.dart`
Expected: PASS (all, including the new teardown tests).

- [ ] **Step 5: Verification gate + commit message**

Run: `just test && just analyze && just format`
Then present a commit message (do not commit). Suggested subject:
`feat(plugin): manifest teardown field naming an on-removal action`

---

### Task 2: Teardown detection + resolution (`common`)

**Files:**

- Create: `common/lib/src/services/plugin/plugin_teardown.dart`
- Modify: `common/lib/common.dart` (add export)
- Test: `common/test/services/plugin/plugin_teardown_test.dart`

**Interfaces:**

- Consumes: `PluginManifest.fromJsonString`, `PluginManifest.teardown`, `PluginManifest.actions`, `PluginAction`.
- Produces:
  - `class PluginTeardown { final String pluginId; final PluginAction action; }`
  - `List<String> parsePluginsList(String? raw)` — split, trim, drop blanks.
  - `Set<String> removedPluginIds({required List<String> committed, required List<String> current})` — ids in `committed` not in `current`.
  - `List<PluginTeardown> resolveTeardowns({required Set<String> removedIds, required String pluginsDir})` — reads `<pluginsDir>/<id>/plugin.json`, returns the teardown for each removed plugin that declares one; skips (logs) missing files / unresolvable actions.

- [ ] **Step 1: Write the failing tests**

Create `common/test/services/plugin/plugin_teardown_test.dart`:

```dart
import 'dart:io';

import 'package:test/test.dart';
import 'package:common/src/services/plugin/plugin_teardown.dart';

void main() {
  group('parsePluginsList', () {
    test('splits, trims, drops blanks', () {
      expect(parsePluginsList('a\nb\n\n c \n'), ['a', 'b', 'c']);
    });
    test('null is empty', () {
      expect(parsePluginsList(null), isEmpty);
    });
  });

  group('removedPluginIds', () {
    test('returns ids in committed but not current', () {
      expect(
        removedPluginIds(committed: ['a', 'tailscale', 'b'], current: ['a', 'b']),
        {'tailscale'},
      );
    });
    test('no removals yields empty', () {
      expect(
        removedPluginIds(committed: ['a', 'b'], current: ['a', 'b', 'c']),
        isEmpty,
      );
    });
  });

  group('resolveTeardowns', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('teardown_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void writePlugin(String id, String json) {
      final dir = Directory('${tmp.path}/$id')..createSync(recursive: true);
      File('${dir.path}/plugin.json').writeAsStringSync(json);
    }

    test('resolves the declared teardown action', () {
      writePlugin('tailscale', '''
        {
          "manifest": {"schema_version": 4, "min_tui_version": 1, "name": "Tailscale"},
          "actions": {"down": {"label": "Disconnect", "unit": "tailscale-down.service"}},
          "permissions": {"privileged_units": ["tailscale-down.service"]},
          "teardown": "down"
        }
      ''');
      final result = resolveTeardowns(
        removedIds: {'tailscale'},
        pluginsDir: tmp.path,
      );
      expect(result, hasLength(1));
      expect(result.first.pluginId, 'tailscale');
      expect(result.first.action.unit, 'tailscale-down.service');
    });

    test('skips a removed plugin with no teardown declared', () {
      writePlugin('plain', '''
        {"manifest": {"schema_version": 4, "min_tui_version": 1, "name": "Plain"}}
      ''');
      expect(
        resolveTeardowns(removedIds: {'plain'}, pluginsDir: tmp.path),
        isEmpty,
      );
    });

    test('skips a removed plugin whose files are gone', () {
      expect(
        resolveTeardowns(removedIds: {'ghost'}, pluginsDir: tmp.path),
        isEmpty,
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/plugin/plugin_teardown_test.dart`
Expected: FAIL — `plugin_teardown.dart` / its functions don't exist (compile error).

- [ ] **Step 3: Implement the helper**

Create `common/lib/src/services/plugin/plugin_teardown.dart`:

```dart
import 'dart:io';

import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/log_service.dart';

/// A teardown to run on the live system before a rebuild removes a
/// plugin: the plugin's id plus the resolved action it declared via
/// `manifest.teardown`.
class PluginTeardown {
  final String pluginId;
  final PluginAction action;

  const PluginTeardown({required this.pluginId, required this.action});
}

/// Parse a `plugins.list` file body into ids: one per line, trimmed,
/// blanks dropped. Tolerates null (file absent / not in HEAD).
List<String> parsePluginsList(String? raw) => (raw ?? '')
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .toList();

/// Ids present in [committed] (HEAD's `plugins.list`) but absent from
/// [current] (the on-disk one) — i.e. plugins being removed by the
/// rebuild this Apply will run. Covers both disable and uninstall.
Set<String> removedPluginIds({
  required List<String> committed,
  required List<String> current,
}) {
  final cur = current.toSet();
  return committed.where((id) => !cur.contains(id)).toSet();
}

/// For each removed id, read `<pluginsDir>/<id>/plugin.json` and, if it
/// declares a `teardown`, resolve the named action. Best-effort: a
/// removed plugin whose files are gone, whose manifest fails to parse,
/// or that declares no teardown is skipped (logged), not raised. The
/// returned list is ordered by id for deterministic execution.
List<PluginTeardown> resolveTeardowns({
  required Set<String> removedIds,
  required String pluginsDir,
}) {
  final out = <PluginTeardown>[];
  for (final id in removedIds.toList()..sort()) {
    final manifestFile = File('$pluginsDir/$id/plugin.json');
    if (!manifestFile.existsSync()) {
      LogService.warn(
        'teardown: no plugin.json for removed plugin `$id` — skipped',
      );
      continue;
    }
    try {
      final manifest = PluginManifest.fromJsonString(
        manifestFile.readAsStringSync(),
      );
      final teardownId = manifest.teardown;
      if (teardownId == null) continue;
      final action = manifest.actions[teardownId];
      if (action == null) {
        LogService.warn(
          'teardown: `$id` names teardown `$teardownId` with no '
          'matching action — skipped',
        );
        continue;
      }
      out.add(PluginTeardown(pluginId: id, action: action));
    } catch (e, st) {
      LogService.error('teardown: resolving `$id` failed', e, st);
    }
  }
  return out;
}
```

- [ ] **Step 4: Export from the barrel**

In `common/lib/common.dart`, add next to the other plugin service exports (keep the file's ordering):

```dart
export 'src/services/plugin/plugin_teardown.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd common && dart test test/services/plugin/plugin_teardown_test.dart`
Expected: PASS (all groups).

- [ ] **Step 6: Verification gate + commit message**

Run: `just test && just analyze && just format`
Then present a commit message. Suggested subject:
`feat(plugin): resolve removed-plugin teardowns from plugins.list diff`

---

### Task 3: Run teardowns in the Apply flow (`tui`)

**Files:**

- Modify: `tui/lib/src/ui/views/apply_view.dart` (the `_continueApply` method, ~lines 262–348)

**Interfaces:**

- Consumes: `removedPluginIds`, `parsePluginsList`, `resolveTeardowns`, `PluginTeardown`, `pluginActionRunnerProvider` (all from `package:common/common.dart`, already imported at line 7); `GitService.readCommittedFile`; the existing `_append`, `context`.
- Produces: no new public API — wires teardown execution between the git commit and `nix flake lock`.

No automated test (nocterm UI flow); verification is the `common` unit tests from Tasks 1–2 plus the manual check below.

- [ ] **Step 1: Capture pending teardowns before the commit**

In `_continueApply`, inside the `.then((_) async {` block (starts ~line 274), at the very top of that block — before the `final staged = ...` line — insert:

```dart
            // Determine which plugins this Apply removes (present in the
            // committed plugins.list but not the current on-disk one),
            // BEFORE commitAll makes HEAD == on-disk. Their teardown
            // actions run on the still-live old system before any
            // network step. Best-effort.
            List<PluginTeardown> pendingTeardowns = const [];
            try {
              final committedRaw = await git.readCommittedFile('plugins.list');
              final listFile = File('$baseDirPath/plugins.list');
              final currentRaw = listFile.existsSync()
                  ? listFile.readAsStringSync()
                  : '';
              final removed = removedPluginIds(
                committed: parsePluginsList(committedRaw),
                current: parsePluginsList(currentRaw),
              );
              pendingTeardowns = resolveTeardowns(
                removedIds: removed,
                pluginsDir: '$baseDirPath/plugins',
              );
            } catch (e, st) {
              LogService.error('apply: computing pending teardowns failed', e, st);
            }
```

(`File` is available — `dart:io` is imported at line 2.)

- [ ] **Step 2: Make the commit callback async and run teardowns before the flake lock**

Change the commit callback signature from:

```dart
                .then((committed) {
```

to:

```dart
                .then((committed) async {
```

Then, immediately after the `_append(committed ? 'Committed.' : 'Nothing staged (no changes to commit).');` call and before the `final platform = ...` line, insert:

```dart
                  // Tear down plugins being removed this Apply, on the
                  // still-live old system, before the network-heavy
                  // flake-lock + rebuild steps. This is what lets a
                  // disabled VPN plugin (e.g. tailscale) drop its DNS
                  // takeover so the rebuild's substituter/flake fetches
                  // don't stall. Non-fatal: log + continue on any error.
                  for (final t in pendingTeardowns) {
                    _append('');
                    _append('> tearing down ${t.pluginId}: ${t.action.label}');
                    try {
                      final runner = context.read(pluginActionRunnerProvider);
                      final (:output, :exitCode) = runner.run(t.action);
                      await output.forEach((line) {
                        LogService.info('[teardown ${t.pluginId}] $line');
                        _append(line);
                      });
                      final code = await exitCode;
                      if (code != 0) {
                        LogService.warn(
                          'apply: teardown ${t.pluginId} exited $code',
                        );
                        _append(
                          '  ! teardown ${t.pluginId} exited $code — continuing',
                        );
                      }
                    } catch (e, st) {
                      LogService.error(
                        'apply: teardown ${t.pluginId} failed',
                        e,
                        st,
                      );
                      _append(
                        '  ! teardown ${t.pluginId} failed: $e — continuing',
                      );
                    }
                  }
```

- [ ] **Step 3: Analyze + format**

Run: `just analyze`
Expected: no NEW issues in `apply_view.dart` (the pre-existing `implementation_imports` infos in other files are unrelated).
Run: `just format`
Expected: formats clean.

- [ ] **Step 4: Run the full test suite**

Run: `just test`
Expected: all pass (no regressions; the teardown logic is covered by Task 2's tests).

- [ ] **Step 5: Manual verification (record the result)**

On a node (or VM) with the Tailscale plugin installed + connected, after Tasks 4–5 are deployed to the forge:

1. Configure → disable Tailscale → Apply.
2. In the Apply log, confirm `> tearing down tailscale: Disconnect` appears **before** `> nix flake lock --update-input nixblitz`, and `tailscale down` runs.
3. Confirm the rebuild proceeds without the DNS-stall hang.

- [ ] **Step 6: Commit message**

Present a commit message. Suggested subject:
`feat(apply): run plugin teardowns before the rebuild removes them`

---

### Task 4: Tailscale plugin — `down` action + teardown (`nixblitz_official_plugins`)

**Files:**

- Modify: `examples_redesign/nixblitz_official_plugins/tailscale/plugin.nix`
- Modify: `examples_redesign/nixblitz_official_plugins/tailscale/plugin.json`

**Interfaces:**

- Produces: a `tailscale-down.service` oneshot (`tailscale down`), a `down` action bound to it, and `"teardown": "down"`. Consumed by Task 2's `resolveTeardowns` at runtime.

- [ ] **Step 1: Add the `tailscale-down.service` unit**

In `tailscale/plugin.nix`, after the `tailscale-leave` service block (before the `environment.systemPackages` line), add:

```nix
  # On-demand "Disconnect" oneshot — also the teardown the TUI runs
  # automatically before a rebuild that disables/removes the plugin
  # (plugin.json "teardown"). `tailscale down` disconnects and restores
  # DNS but keeps the node identity, so re-enabling reconnects without a
  # fresh key. (`tailscale logout` — the "Leave tailnet" action — is the
  # destructive verb that also forgets identity.)
  systemd.services.tailscale-down = {
    description = "Disconnect from the tailnet (keep node identity)";
    after = ["tailscaled.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    script = ''
      ${pkgs.tailscale}/bin/tailscale down
    '';
  };
```

- [ ] **Step 2: Add the `down` action, privileged unit, and teardown to the manifest**

In `tailscale/plugin.json`:

In `"actions"`, add a `down` entry (place it before `leave`):

```json
    "down": {
      "label": "Disconnect",
      "description": "Runs `tailscale down` — disconnects from the tailnet but keeps the node identity, so re-connecting needs no new key. Also runs automatically when the plugin is disabled or removed.",
      "unit": "tailscale-down.service",
      "confirm": false,
      "timeout_seconds": 30
    },
```

In `"permissions"."privileged_units"`, add `"tailscale-down.service"` to the list.

Add a top-level `"teardown": "down",` field (sibling of `"actions"`/`"permissions"`/`"dashboard"`).

- [ ] **Step 3: Validate JSON**

Run: `jq -e . examples_redesign/nixblitz_official_plugins/tailscale/plugin.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Eval the module to confirm the new unit builds**

Run (from `/home/f44/dev/blitz/nixblitz`):

```bash
nix --extra-experimental-features 'nix-command flakes' eval --impure --raw --expr '
let
  flake = builtins.getFlake (toString ./.);
  sys = flake.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ({ ... }: { boot.loader.grub.devices = [ "/dev/sda" ]; fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; }; system.stateVersion = "25.11"; })
      ((import ./examples_redesign/nixblitz_official_plugins/tailscale/plugin.nix) { pluginCfg = {}; })
    ];
  };
in sys.config.systemd.services.tailscale-down.script
'
```

Expected: prints a script ending in `tailscale down` (proves the unit evaluates).

- [ ] **Step 5: Commit message (plugins repo)**

Present a commit message for the `nixblitz_official_plugins` repo. Suggested subject:
`feat(tailscale): add Disconnect (tailscale down) + teardown on removal`
Body: note it's the non-destructive teardown the TUI auto-runs on disable/uninstall, distinct from the existing logout-based Leave action.

---

### Task 5: NetBird plugin — teardown (`nixblitz_official_plugins`)

**Files:**

- Modify: `examples_redesign/nixblitz_official_plugins/netbird/plugin.json`

**Interfaces:**

- Consumes: the existing `disconnect` action + `netbird-down.service` (already built).
- Produces: `"teardown": "disconnect"`.

- [ ] **Step 1: Add the teardown field**

In `netbird/plugin.json`, add a top-level `"teardown": "disconnect",` field (sibling of `"actions"`/`"permissions"`/`"dashboard"`). No new unit — `disconnect` → `netbird-down.service` already exists and is input-free.

- [ ] **Step 2: Validate JSON**

Run: `jq -e . examples_redesign/nixblitz_official_plugins/netbird/plugin.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Confirm the teardown reference is valid (parser check)**

The teardown must reference an existing input-free action. Verify by parsing the manifest through the same Dart model the TUI uses:

Run: `cd common && dart run -e "import 'package:common/common.dart'; import 'dart:io'; void main(){ final m = PluginManifest.fromJsonString(File('../examples_redesign/nixblitz_official_plugins/netbird/plugin.json').readAsStringSync()); print('teardown=\${m.teardown} action=\${m.actions[m.teardown]?.unit}'); }"`
Expected: `teardown=disconnect action=netbird-down.service` (no `FormatException`).

(If `dart run -e` is unavailable in this toolchain, instead confirm via `jq -e '.teardown as $t | .actions[$t] | .unit'` that `.actions.disconnect.unit == "netbird-down.service"` and `.actions.disconnect | has("inputs") | not`.)

- [ ] **Step 4: Commit message (plugins repo)**

Present a commit message. Suggested subject:
`feat(netbird): tear down (netbird down) on disable/removal`

---

## Self-Review

**Spec coverage:**

- Manifest schema (`teardown` field + validation: ref exists, no inputs) → Task 1. ✓
- Removal detection (committed-minus-current `plugins.list`, covers disable + uninstall) → Task 2. ✓
- Apply wiring (after commit, before flake-lock; non-fatal; live system) → Task 3. ✓
- Tailscale `down` action + unit + teardown; keep `leave` as manual logout → Task 4. ✓
- NetBird `teardown: disconnect` reusing the existing unit → Task 5. ✓
- Testing: manifest parse cases + removal diff (Tasks 1–2 unit tests); plugin eval (Task 4); manual disable→Apply (Task 3 Step 5). ✓
- Repos-touched split → Global Constraints + per-task file headers. ✓

**Placeholder scan:** none — every code/step block is concrete.

**Type consistency:** `PluginTeardown{pluginId, action}`, `parsePluginsList`, `removedPluginIds({committed, current})`, `resolveTeardowns({removedIds, pluginsDir})` are defined in Task 2 and used with identical signatures in Task 3. `PluginManifest.teardown` (`String?`) defined in Task 1, read in Task 2. `pluginActionRunnerProvider` / `PluginActionRunner.run(action) → ({output, exitCode})` match the real provider and runner signatures.
