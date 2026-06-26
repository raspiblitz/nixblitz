# Plugin Disable → Full Halt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Setting a plugin's `enabled = false` and applying fully halts it — daemon stopped (gated on config), network state torn down first, dashboard tile hidden, actions hidden — on every rebuild path.

**Architecture:** Make the existing `app_configs.<id>.enabled` toggle authoritative. Plugins gate `services.X.enable` on `pluginCfg.enabled`. A common `PluginTeardownRunner` orchestrator detects the removed-from-`plugins.list` (uninstall) ∪ `enabled` true→false (disable) edges, resolves each plugin's teardown from the committed git tree, and runs it before the rebuild; both the TUI Apply path and the CLI `update` path call it. The dashboard tile builder and the actions menu gate on `isAppEnabled`, and the tile poller stops for disabled plugins.

**Tech Stack:** Dart (`common` + `tui`), Riverpod, nocterm; Nix (plugin modules in the separate `nixblitz_official_plugins` repo).

## Global Constraints

- **Two repos.** Tasks 1–6 are in the main repo (`/home/f44/dev/blitz/nixblitz`). Task 7 is in the nested separate repo `examples_redesign/nixblitz_official_plugins/`.
- **Commits are the user's.** Do NOT run `jj`/`git commit`. Each task ends by running the verification gate and presenting a ready-to-paste commit message (subject + why-focused body + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`). This work squashes into the unpushed teardown-hook commit; present messages accordingly.
- **Main-repo verification gate:** after each main-repo task run `just test`, `just analyze`, `just format` (in that order); all green before presenting the message. Pre-existing `implementation_imports` infos in `tile_renderer.dart`/`dashboard_view.dart` are not yours unless your change adds new ones.
- **Architecture split:** detection/orchestration logic lives in `common`; `tui` orchestrates + renders; `common` is the only package that calls `Process`.
- **Best-effort teardown:** any teardown failure logs + emits a line and continues; it must never block a rebuild.
- **`isAppEnabled` semantics:** `config.isAppEnabled(id)` = `appOption<bool>(id,'enabled') ?? false` (already exists in `nixblitz_config.dart:220`). A null/absent config is treated as "not enabled".

---

### Task 1: `disabledPluginIds` detector (`common`)

**Files:**

- Modify: `common/lib/src/services/plugin/plugin_teardown.dart`
- Test: `common/test/services/plugin/plugin_teardown_test.dart`

**Interfaces:**

- Consumes: `NixblitzConfig` (`isAppEnabled(String)`, `appConfigs` is `Map<String, Map<String,dynamic>>`).
- Produces: `Set<String> disabledPluginIds({required NixblitzConfig? committed, required NixblitzConfig? current})` — ids enabled in `committed` but not in `current`.

- [ ] **Step 1: Write the failing tests**

Add this group to `common/test/services/plugin/plugin_teardown_test.dart` (add `import 'package:common/src/models/nixblitz_config.dart';` at the top if absent):

```dart
group('disabledPluginIds', () {
  NixblitzConfig cfgWith(Map<String, bool> enabledById) => NixblitzConfig.fromJson({
    'schema_version': 18,
    'system': {'hostname': 'n', 'timezone': 'UTC', 'platform': 'x86', 'disk_device': '/dev/vda', 'shell': 'bash'},
    'app_configs': {
      for (final e in enabledById.entries) e.key: {'enabled': e.value},
    },
  });

  test('detects an enabled→disabled plugin', () {
    expect(
      disabledPluginIds(committed: cfgWith({'tailscale': true}), current: cfgWith({'tailscale': false})),
      {'tailscale'},
    );
  });

  test('ignores a still-enabled plugin', () {
    expect(
      disabledPluginIds(committed: cfgWith({'tailscale': true}), current: cfgWith({'tailscale': true})),
      isEmpty,
    );
  });

  test('ignores a newly-enabled plugin', () {
    expect(
      disabledPluginIds(committed: cfgWith({'tailscale': false}), current: cfgWith({'tailscale': true})),
      isEmpty,
    );
  });

  test('treats a plugin dropped from current config as disabled', () {
    expect(
      disabledPluginIds(committed: cfgWith({'tailscale': true}), current: cfgWith({})),
      {'tailscale'},
    );
  });

  test('null committed or current yields empty', () {
    expect(disabledPluginIds(committed: null, current: cfgWith({'tailscale': false})), isEmpty);
    expect(disabledPluginIds(committed: cfgWith({'tailscale': true}), current: null), isEmpty);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/plugin/plugin_teardown_test.dart -n disabledPluginIds`
Expected: FAIL — `disabledPluginIds` undefined (compile error).

- [ ] **Step 3: Implement the detector**

Add to `common/lib/src/services/plugin/plugin_teardown.dart` (add `import 'package:common/src/models/nixblitz_config.dart';` if absent), next to `removedPluginIds`:

```dart
/// Ids `enabled` in the committed config but not in the current one — the
/// operator's per-plugin disable edge (the Configure `enabled` toggle going
/// true→false). Null-safe: either config null → empty (fail safe, no spurious
/// teardowns). Pairs with [removedPluginIds] (the uninstall edge); the
/// pre-rebuild step tears down the union.
Set<String> disabledPluginIds({
  required NixblitzConfig? committed,
  required NixblitzConfig? current,
}) {
  if (committed == null || current == null) return {};
  final out = <String>{};
  for (final id in committed.appConfigs.keys) {
    if (committed.isAppEnabled(id) && !current.isAppEnabled(id)) {
      out.add(id);
    }
  }
  return out;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd common && dart test test/services/plugin/plugin_teardown_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Verification gate + commit message**

Run: `just test && just analyze && just format`. Present a message; suggested subject:
`feat(plugin): detect the enabled→disabled edge for teardown`

---

### Task 2: `PluginTeardownRunner` orchestrator (`common`)

**Files:**

- Create: `common/lib/src/services/plugin/plugin_teardown_runner.dart`
- Modify: `common/lib/common.dart` (add export)
- Test: `common/test/services/plugin/plugin_teardown_runner_test.dart`

**Interfaces:**

- Consumes: `removedPluginIds`, `disabledPluginIds`, `parsePluginsList`, `resolveTeardowns`, `PluginTeardown`, `PluginAction`, `NixblitzConfig`.
- Produces:
  - `typedef ActionRun = ({Stream<String> output, Future<int> exitCode}) Function(PluginAction action);`
  - `class PluginTeardownRunner` with ctor `({required ActionRun runAction, required Future<String?> Function(String relPath) readCommitted, required String? Function(String relPath) readCurrent})`, and:
    - `Future<List<PluginTeardown>> resolvePending()`
    - `Future<void> run(List<PluginTeardown> teardowns, void Function(String line) emit)`
    - `Future<void> runPending(void Function(String line) emit)` (= resolve + run)

- [ ] **Step 1: Write the failing tests**

Create `common/test/services/plugin/plugin_teardown_runner_test.dart`:

```dart
import 'dart:async';

import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/plugin/plugin_teardown_runner.dart';

void main() {
  const tailscaleManifest = '''
    {
      "manifest": {"schema_version": 4, "min_tui_version": 1, "name": "Tailscale"},
      "actions": {"down": {"label": "Disconnect", "unit": "tailscale-down.service"}},
      "permissions": {"privileged_units": ["tailscale-down.service"]},
      "teardown": "down"
    }
  ''';

  String cfg(Map<String, bool> enabledById) =>
      '{"schema_version":18,"system":{"hostname":"n","timezone":"UTC","platform":"x86","disk_device":"/dev/vda","shell":"bash"},'
      '"app_configs":{${enabledById.entries.map((e) => '"${e.key}":{"enabled":${e.value}}').join(",")}}}';

  PluginTeardownRunner build({
    required Map<String, String?> committed,
    required Map<String, String?> current,
    required List<PluginAction> ran,
    int exitCode = 0,
  }) {
    return PluginTeardownRunner(
      runAction: (action) {
        ran.add(action);
        return (output: Stream<String>.value('ok'), exitCode: Future.value(exitCode));
      },
      readCommitted: (p) async => committed[p],
      readCurrent: (p) => current[p],
    );
  }

  test('resolves the disable edge (enabled true→false)', () async {
    final ran = <PluginAction>[];
    final r = build(
      committed: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': true}), 'plugins/tailscale/plugin.json': tailscaleManifest},
      current: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': false})},
      ran: ran,
    );
    final pending = await r.resolvePending();
    expect(pending.map((t) => t.pluginId), ['tailscale']);
    expect(pending.first.action.unit, 'tailscale-down.service');
  });

  test('resolves the uninstall edge (dropped from plugins.list)', () async {
    final ran = <PluginAction>[];
    final r = build(
      committed: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': true}), 'plugins/tailscale/plugin.json': tailscaleManifest},
      current: {'plugins.list': '', 'config.json': cfg({'tailscale': true})},
      ran: ran,
    );
    expect((await r.resolvePending()).map((t) => t.pluginId), ['tailscale']);
  });

  test('union dedupes a plugin both uninstalled and disabled', () async {
    final r = build(
      committed: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': true}), 'plugins/tailscale/plugin.json': tailscaleManifest},
      current: {'plugins.list': '', 'config.json': cfg({'tailscale': false})},
      ran: [],
    );
    expect((await r.resolvePending()).length, 1);
  });

  test('no edge → nothing pending', () async {
    final r = build(
      committed: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': true})},
      current: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': true})},
      ran: [],
    );
    expect(await r.resolvePending(), isEmpty);
  });

  test('runPending runs each action and emits lines', () async {
    final ran = <PluginAction>[];
    final lines = <String>[];
    final r = build(
      committed: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': true}), 'plugins/tailscale/plugin.json': tailscaleManifest},
      current: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': false})},
      ran: ran,
    );
    await r.runPending(lines.add);
    expect(ran.single.unit, 'tailscale-down.service');
    expect(lines.any((l) => l.contains('tearing down tailscale')), isTrue);
  });

  test('a failing action is non-fatal and still emits', () async {
    final lines = <String>[];
    final r = build(
      committed: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': true}), 'plugins/tailscale/plugin.json': tailscaleManifest},
      current: {'plugins.list': 'tailscale\n', 'config.json': cfg({'tailscale': false})},
      ran: [],
      exitCode: 1,
    );
    await r.runPending(lines.add); // must not throw
    expect(lines.any((l) => l.contains('exited 1')), isTrue);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/plugin/plugin_teardown_runner_test.dart`
Expected: FAIL — `plugin_teardown_runner.dart` / `PluginTeardownRunner` undefined.

- [ ] **Step 3: Implement the orchestrator**

Create `common/lib/src/services/plugin/plugin_teardown_runner.dart`:

```dart
import 'dart:convert';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_teardown.dart';

/// Runs one plugin action and returns its output stream + exit code. The
/// real binding is `PluginActionRunner.run`; tests pass a fake.
typedef ActionRun =
    ({Stream<String> output, Future<int> exitCode}) Function(PluginAction action);

/// Detects the plugins being halted by the rebuild this Apply/CLI run will
/// perform — removed from `plugins.list` (uninstall) ∪ `enabled` true→false
/// (disable) — resolves each one's teardown from the committed manifest, and
/// runs it on the live system. Path-agnostic: both the TUI Apply flow and the
/// CLI `update` rebuild construct one and call [runPending] before
/// `nixos-rebuild`. Best-effort throughout: nothing here throws to the caller.
class PluginTeardownRunner {
  PluginTeardownRunner({
    required this.runAction,
    required this.readCommitted,
    required this.readCurrent,
  });

  /// Runs a resolved teardown action (→ `PluginActionRunner.run`).
  final ActionRun runAction;

  /// Reads a repo-relative path from the committed tree (git HEAD). Returns
  /// null when the path isn't committed. (→ `GitService.readCommittedFile`.)
  final Future<String?> Function(String relPath) readCommitted;

  /// Reads a repo-relative path from the working tree. Returns null when
  /// absent.
  final String? Function(String relPath) readCurrent;

  /// Resolve the teardowns pending for this rebuild. Reads HEAD vs the working
  /// tree, so call BEFORE any commit that would collapse the diff.
  Future<List<PluginTeardown>> resolvePending() async {
    try {
      final removed = removedPluginIds(
        committed: parsePluginsList(await readCommitted('plugins.list')),
        current: parsePluginsList(readCurrent('plugins.list')),
      );
      final disabled = disabledPluginIds(
        committed: _config(await readCommitted('config.json')),
        current: _config(readCurrent('config.json')),
      );
      final ids = {...removed, ...disabled};
      return resolveTeardowns(
        removedIds: ids,
        readManifest: (id) => readCommitted('plugins/$id/plugin.json'),
      );
    } catch (e, st) {
      LogService.error('teardown: resolving pending teardowns failed', e, st);
      return const [];
    }
  }

  /// Run the given teardowns, streaming progress to [emit]. Non-fatal.
  Future<void> run(
    List<PluginTeardown> teardowns,
    void Function(String line) emit,
  ) async {
    for (final t in teardowns) {
      emit('');
      emit('> tearing down ${t.pluginId}: ${t.action.label}');
      try {
        final (:output, :exitCode) = runAction(t.action);
        await output.forEach((line) {
          LogService.info('[teardown ${t.pluginId}] $line');
          emit(line);
        });
        final code = await exitCode;
        if (code != 0) {
          LogService.warn('teardown ${t.pluginId} exited $code');
          emit('  ! teardown ${t.pluginId} exited $code — continuing');
        }
      } catch (e, st) {
        LogService.error('teardown ${t.pluginId} failed', e, st);
        emit('  ! teardown ${t.pluginId} failed: $e — continuing');
      }
    }
  }

  /// Convenience: [resolvePending] then [run].
  Future<void> runPending(void Function(String line) emit) async =>
      run(await resolvePending(), emit);

  NixblitzConfig? _config(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return NixblitzConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      LogService.warn('teardown: config parse failed: $e');
      return null;
    }
  }
}
```

- [ ] **Step 4: Export from the barrel**

In `common/lib/common.dart`, next to the `plugin_teardown.dart` export:

```dart
export 'src/services/plugin/plugin_teardown_runner.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd common && dart test test/services/plugin/plugin_teardown_runner_test.dart`
Expected: PASS.

- [ ] **Step 6: Verification gate + commit message**

Run: `just test && just analyze && just format`. Suggested subject:
`feat(plugin): PluginTeardownRunner unifying the uninstall + disable edges`

---

### Task 3: Apply uses the orchestrator (`tui`)

**Files:**

- Modify: `tui/lib/src/ui/views/apply_view.dart` (`_continueApply`, lines ~273–356)

**Interfaces:**

- Consumes: `PluginTeardownRunner`, `pluginActionRunnerProvider` (both via `package:common/common.dart`, already imported), `GitService`, `File` (`dart:io`, imported).

No automated test (nocterm UI); verified by Task 2's unit tests + the manual check in Task 7.

- [ ] **Step 1: Replace the inline capture + run with one orchestrator call before the commit**

In `apply_view.dart`, the block currently at lines 280–302 (the `List<PluginTeardown> pendingTeardowns = const [];` capture) and the block at lines 321–356 (the `// Tear down plugins …` for-loop after the commit) implement the old Apply-only teardown. Replace BOTH as follows.

Delete the capture block (lines 280–302) and in its place put:

```dart
            // Tear down plugins being removed (uninstall) or disabled
            // (enabled→false) by this Apply, on the still-live old system,
            // before the commit + network-heavy steps so a VPN plugin drops
            // its DNS/route takeover and the rebuild's fetches don't stall.
            // Reads HEAD, so must run before commitAll. Best-effort.
            await PluginTeardownRunner(
              runAction: context.read(pluginActionRunnerProvider).run,
              readCommitted: git.readCommittedFile,
              readCurrent: (p) {
                final f = File('$baseDirPath/$p');
                return f.existsSync() ? f.readAsStringSync() : null;
              },
            ).runPending(_append);
```

Then delete the post-commit teardown block (the `final runner = context.read(pluginActionRunnerProvider);` line through the end of its `for` loop, lines 321–356), leaving the commit callback as:

```dart
            git
                .commitAll('Apply pending changes')
                .then((committed) async {
                  _append(
                    committed
                        ? 'Committed.'
                        : 'Nothing staged (no changes to commit).',
                  );
                  // Pick the rebuild attribute from the just-applied
                  // platform; …  (existing code continues unchanged)
```

(The `.then((committed) async {` stays `async` — harmless even though the awaited teardown moved out.) Remove the now-unused `PluginTeardown` import if `package:common/common.dart` was the only source — it's a barrel, so leave the import.

- [ ] **Step 2: Analyze + format**

Run: `just analyze` — no NEW issues in `apply_view.dart`.
Run: `just format`.

- [ ] **Step 3: Full test suite**

Run: `just test`
Expected: all pass (no regressions; teardown logic now covered by Task 2).

- [ ] **Step 4: Control-flow self-check (record in commit message context)**

Confirm by reading the result: the `runPending` call sits inside the outer `.then((_) async {` and BEFORE `git.commitAll(...)`; the post-commit teardown loop is gone; `> nix flake lock` still follows the commit callback.

- [ ] **Step 5: Commit message**

Suggested subject: `refactor(apply): run teardowns via PluginTeardownRunner before commit`

---

### Task 4: CLI `update` rebuilds also tear down (`tui`)

**Files:**

- Modify: `tui/lib/src/cli/update_cli.dart` (`_runRebuild`, lines ~122–135)

**Interfaces:**

- Consumes: `PluginTeardownRunner`, `PluginActionRunner`, `SudoSession`, `GitService` (all via `package:common/common.dart`, already imported), `File`/`Process` (`dart:io`, imported).

No automated test (process/sudo I/O); verified by Task 2's unit tests + the manual check in Task 7.

- [ ] **Step 1: Run pending teardowns before the rebuild**

In `update_cli.dart`, replace `_runRebuild` (currently lines 122–135) with:

```dart
Future<int> _runRebuild(String baseDir) async {
  // Halt any plugins this rebuild removes/disables BEFORE nixos-rebuild, on
  // the still-live old system — mirrors the TUI Apply path. The CLI has no
  // ProviderContainer, so the services are built directly. Best-effort.
  final teardown = PluginTeardownRunner(
    runAction: PluginActionRunner(sudoSession: SudoSession()).run,
    readCommitted: GitService(repoDir: baseDir).readCommittedFile,
    readCurrent: (p) {
      final f = File('$baseDir/$p');
      return f.existsSync() ? f.readAsStringSync() : null;
    },
  );
  final pending = await teardown.resolvePending();
  if (pending.isNotEmpty) {
    // The teardown units run via `sudo systemctl start --wait`; prime sudo
    // interactively once (the rebuild below would prompt anyway) so the
    // SudoSession's `-n` calls succeed instead of silently skipping.
    final prime = await Process.start('sudo', [
      '-v',
    ], mode: ProcessStartMode.inheritStdio);
    await prime.exitCode;
    await teardown.run(pending, stdout.writeln);
  }

  final platform = _readPlatform(baseDir);
  final attr = rebuildAttributeFor(platform);
  stdout.writeln('');
  stdout.writeln('> sudo nixos-rebuild switch --flake $baseDir#$attr');
  stdout.writeln('');
  final rebuild = await Process.start('sudo', [
    'nixos-rebuild',
    'switch',
    '--flake',
    '$baseDir#$attr',
  ], mode: ProcessStartMode.inheritStdio);
  return rebuild.exitCode;
}
```

- [ ] **Step 2: Analyze + format**

Run: `just analyze` (no new issues in `update_cli.dart`) then `just format`.
If `GitService` / `SudoSession` / `PluginActionRunner` / `PluginTeardownRunner` aren't resolved, confirm `package:common/common.dart` exports them (the barrel does; `SudoSession`/`GitService`/`PluginActionRunner` are existing exports).

- [ ] **Step 3: Full test suite**

Run: `just test`
Expected: all pass.

- [ ] **Step 4: Commit message**

Suggested subject: `feat(cli): tear down removed/disabled plugins before update rebuilds`

---

### Task 5: Tile poller stops for disabled plugins (`common`)

**Files:**

- Modify: `common/lib/src/services/plugin_dashboard_service.dart` (`_reconcile`, constructor)
- Test: `common/test/services/plugin_dashboard_service_test.dart`

**Interfaces:**

- Consumes: `configProvider` (`common/src/providers/config_provider.dart`), `NixblitzConfig.isAppEnabled`.

- [ ] **Step 1: Write the failing test**

Open `common/test/services/plugin_dashboard_service_test.dart`. Add a test that an installed plugin with `enabled=false` never registers a poller (i.e. its id never appears in the service's seed). Mirror the existing test setup in that file for constructing the service with a `ProviderContainer`; the new assertion:

```dart
test('does not poll a plugin whose config enabled is false', () async {
  // Arrange: install a plugin with a dashboard block + a marker, and a
  // config where its `enabled` is false. (Reuse this file's existing helpers
  // for writing a plugin dir + marker + overriding baseDirProvider; override
  // configProvider with a NixblitzConfig whose app_configs.<id>.enabled=false.)
  // Act: construct PluginDashboardService(container.read) and pump a tick.
  // Assert:
  expect(service.seed.containsKey(pluginId), isFalse);
});
```

Use the file's existing fixture helpers; if it builds the service via a container, override `configProvider` to a config with `app_configs.<id>.enabled = false`. (If the file lacks a config override pattern, add `configProvider.overrideWith((ref) => ...)` returning an `AsyncData<NixblitzConfig>` with the disabled plugin.)

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/services/plugin_dashboard_service_test.dart -n "config enabled is false"`
Expected: FAIL — the poller currently registers regardless of config (seed contains the id).

- [ ] **Step 3: Gate `_reconcile` on config enabled + re-reconcile on config change**

In `plugin_dashboard_service.dart`:

Add the import (with the other providers):

```dart
import 'package:common/src/providers/config_provider.dart';
```

In the constructor, after the existing `installedPluginsProvider` listen, also re-reconcile when config changes:

```dart
    _ref.listen(
      configProvider,
      (_, _) => _reconcile(),
    );
```

In `_reconcile()`, read the current config and skip disabled plugins. Change the marker loop:

```dart
    final config = _ref.read(configProvider).value;
    final desired = <String, PluginTileSpec>{};
    for (final m in markers) {
      if (m.disabled) continue;
      // Operator's per-plugin enabled toggle — a disabled plugin's daemon is
      // off, so polling it would just churn errors. Mirrors the dashboard
      // streamer gate. Config not loaded yet → skip (re-reconciles on load).
      if (config == null || !config.isAppEnabled(m.id)) continue;
      try {
        final manifest = _pluginService.readManifest(m.id);
        final spec = manifest.dashboard;
        if (spec == null) continue;
        desired[m.id] = spec;
      } catch (e, st) {
        LogService.warn(
          'PluginDashboardService: failed to read manifest for '
          '${m.id}: $e',
        );
        LogService.error('manifest read', e, st);
      }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd common && dart test test/services/plugin_dashboard_service_test.dart`
Expected: PASS (new + existing tests; existing tests that expect a poller must have their plugin's config enabled — if a fixture omits config, the gate would now skip it, so set `enabled=true` in those fixtures’ config override. Update any fixture that regresses.)

- [ ] **Step 5: Verification gate + commit message**

Run: `just test && just analyze && just format`. Suggested subject:
`feat(dashboard): stop polling a plugin once its config is disabled`

---

### Task 6: Hide the tile + actions when disabled (`tui`)

**Files:**

- Modify: `tui/lib/src/ui/views/dashboard_view.dart` (`_pluginTiles`, ~lines 38–66)
- Modify: `tui/lib/src/ui/views/configure_view.dart` (`_actionsFor`, ~lines 1024–1031)
- Test: `tui/test/ui/views/configure/configure_view_test.dart` (actions gate)

**Interfaces:**

- Consumes: `configProvider`, `NixblitzConfig.isAppEnabled` (both available; `configProvider` already used in both views).

- [ ] **Step 1: Write the failing test for the actions gate**

`_actionsFor` is a private method, so test the observable rule via a small pure helper. Add this helper next to `_actionsFor` in `configure_view.dart`:

```dart
/// Visible actions for [appId]: the plugin's declared actions in stable
/// order, or empty when the plugin is missing OR disabled (a halted plugin
/// offers no Connect/Down/etc.).
List<PluginAction> visiblePluginActions({
  required PluginManifest? plugin,
  required bool enabled,
}) {
  if (plugin == null || !enabled) return const [];
  final entries = plugin.actions.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((e) => e.value).toList(growable: false);
}
```

Add to `tui/test/ui/views/configure/configure_view_test.dart`:

```dart
group('visiblePluginActions', () {
  PluginManifest manifestWithDown() => PluginManifest.fromJson({
    'manifest': {'schema_version': 4, 'min_tui_version': 1, 'name': 'Tailscale'},
    'actions': {'down': {'label': 'Disconnect', 'unit': 'tailscale-down.service'}},
    'permissions': {'privileged_units': ['tailscale-down.service']},
  });

  test('returns actions when enabled', () {
    expect(visiblePluginActions(plugin: manifestWithDown(), enabled: true), hasLength(1));
  });
  test('empty when disabled', () {
    expect(visiblePluginActions(plugin: manifestWithDown(), enabled: false), isEmpty);
  });
  test('empty when plugin missing', () {
    expect(visiblePluginActions(plugin: null, enabled: true), isEmpty);
  });
});
```

(Ensure the test file imports `package:common/common.dart` for `PluginManifest`/`PluginAction`, and the function under test.)

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tui && dart test test/ui/views/configure/configure_view_test.dart -n visiblePluginActions`
Expected: FAIL — `visiblePluginActions` undefined.

- [ ] **Step 3: Implement the helper and route `_actionsFor` through it**

With the helper added (Step 1), change `_actionsFor` to delegate:

```dart
  List<PluginAction> _actionsFor(BuildContext ctx, String appId) {
    final installed = ctx.read(installedPluginsProvider);
    final plugin = installed.where((p) => p.id == appId).firstOrNull;
    final enabled =
        ctx.read(configProvider).value?.isAppEnabled(appId) ?? false;
    return visiblePluginActions(plugin: plugin, enabled: enabled);
  }
```

- [ ] **Step 4: Hide the dashboard tile for disabled plugins**

In `dashboard_view.dart` `_pluginTiles`, read config and skip disabled plugins. Change the entry-building loop:

```dart
  List<SizedTile> _pluginTiles(BuildContext context) {
    final manifests = context.watch(installedPluginsProvider);
    final config = context.watch(configProvider).value;
    final snapshots = context
        .watch(pluginTileSnapshotsProvider)
        .maybeWhen(data: (m) => m, orElse: () => null);
    final entries = <({String id, String title, String accent})>[];
    for (final m in manifests) {
      final spec = m.dashboard;
      if (spec == null) continue;
      // Hide a disabled plugin's tile entirely (not just stop its poller).
      // Gate here, NOT in installedPluginsProvider — Configure still needs the
      // plugin listed so it can be re-enabled.
      if (config == null || !config.isAppEnabled(m.id)) continue;
      entries.add((id: m.id, title: spec.title, accent: spec.accentColorHex));
    }
    // …existing sort + return unchanged…
```

- [ ] **Step 5: Run tests + gate**

Run: `cd tui && dart test test/ui/views/configure/configure_view_test.dart`
Expected: PASS.
Then: `just test && just analyze && just format` (all green; no new analyzer issues).

- [ ] **Step 6: Commit message**

Suggested subject: `feat(ui): hide a disabled plugin's tile and actions`

---

### Task 7: Gate the service on `enabled` (`nixblitz_official_plugins`)

**Files:**

- Modify: `examples_redesign/nixblitz_official_plugins/tailscale/plugin.nix`
- Modify: `examples_redesign/nixblitz_official_plugins/netbird/plugin.nix`
- Modify: `examples_redesign/nixblitz_official_plugins/tailscale/README.md`
- Modify: `examples_redesign/nixblitz_official_plugins/netbird/README.md`

**Interfaces:**

- Produces: `services.X.enable` now follows `pluginCfg.enabled`. Consumed by Tasks 1–6 (the disable edge).

- [ ] **Step 1: Gate Tailscale's service on `enabled`**

In `tailscale/plugin.nix`, the `in {` block currently has:

```nix
  services.tailscale = {
    enable = true;
```

Change to:

```nix
  services.tailscale = {
    enable = pluginCfg.enabled or false;
```

Leave `useRoutingFeatures` and all units/scripts unchanged.

- [ ] **Step 2: Gate NetBird's service on `enabled`**

In `netbird/plugin.nix`, change:

```nix
  services.netbird.enable = true;
```

to:

```nix
  services.netbird.enable = pluginCfg.enabled or false;
```

- [ ] **Step 3: Eval both plugins for enabled=true and enabled=false**

Run from `/home/f44/dev/blitz/nixblitz` (checks `services.X.enable` follows `pluginCfg.enabled`):

```bash
for p in tailscale netbird; do
  for en in true false; do
    echo "== $p enabled=$en =="
    nix --extra-experimental-features 'nix-command flakes' eval --impure --expr '
      let
        flake = builtins.getFlake (toString ./.);
        svc = if "'$p'" == "tailscale" then "tailscale" else "netbird";
        sys = flake.inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ({ ... }: { boot.loader.grub.devices = [ "/dev/sda" ]; fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; }; system.stateVersion = "25.11"; })
            ((import ./examples_redesign/nixblitz_official_plugins/'$p'/plugin.nix) { pluginCfg = { enabled = '$en'; }; })
          ];
        };
      in sys.config.services.${svc}.enable
    '
  done
done
```

Expected: prints `true` for `enabled=true`, `false` for `enabled=false`, for each plugin.

- [ ] **Step 4: Note the opt-in behavior in both READMEs**

In `tailscale/README.md` and `netbird/README.md`, under the Configuration section's `enabled` row (or add a short note), state: enabling now _activates_ the daemon — a freshly-installed plugin stays **off until you set `enabled = true`** and apply; disabling it (toggle off + apply) fully halts the daemon and runs the Disconnect teardown first. Mirror the wording between the two files.

- [ ] **Step 5: Commit message (plugins repo)**

Suggested subject: `feat(tailscale,netbird): gate the service on the enabled toggle`
Body: note `enabled` is now authoritative (opt-in: installed = off until enabled); disabling halts the daemon, with the `down` teardown running first via the TUI.

---

## Self-Review

**Spec coverage:**

- Gate `services.X.enable` on `pluginCfg.enabled` (tailscale, netbird) → Task 7. ✓
- `disabledPluginIds` enabled-edge detection → Task 1. ✓
- Shared pre-rebuild orchestrator across Apply + CLI → Task 2 (orchestrator) + Task 3 (Apply) + Task 4 (CLI). ✓
- Tile hidden (`_pluginTiles` filter, not `installedPluginsProvider`) + poller stopped → Task 6 (tile) + Task 5 (poller). ✓
- Actions hidden when disabled → Task 6. ✓
- Error handling (best-effort, non-fatal; null config → no spurious teardown) → Task 2 (`resolvePending` try/catch, `_config` null-safe) + Task 1 (null → empty). ✓
- Testing: detector + orchestrator unit tests (Tasks 1–2), poller gate test (Task 5), actions-gate test (Task 6), plugin eval both states (Task 7), manual disable→apply (Task 7 Step references). ✓
- Repos-touched split → Global Constraints + per-task headers. ✓

**Placeholder scan:** Task 5's test references "this file's existing fixture helpers" rather than inlining a full container setup — this is deliberate (the helper shape is file-specific and must be read), and the assertion + override requirement are concrete. All other steps carry complete code.

**Type consistency:** `disabledPluginIds({committed, current}) → Set<String>` (Task 1) is consumed in Task 2's `resolvePending`. `ActionRun` / `PluginTeardownRunner({runAction, readCommitted, readCurrent})` with `resolvePending`/`run`/`runPending` (Task 2) are consumed verbatim in Tasks 3–4. `visiblePluginActions({plugin, enabled})` (Task 6) is used by `_actionsFor`. `isAppEnabled` and `config.appConfigs` match `nixblitz_config.dart`. `services.X.enable = pluginCfg.enabled or false` (Task 7) is the edge Task 1 detects.
