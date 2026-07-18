# WASM Plugin Dashboard Tile + Forbidden-Action Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the `node-summary` example plugin a sandboxed dashboard tile (polled through the WASM runtime) and a forbidden-function action that shows the host boundary refusing a non-allowlisted call. Per `docs/superpowers/specs/2026-07-18-wasm-plugin-tile-and-forbidden-action-design.md`.

**Architecture:** A `wasm` variant is added to the plugin `dashboard` tile spec; `PluginDashboardService`'s existing poll loop runs it through the same `WasmActionRunner` + `HostCallHandler` as the plugin's actions, feeding the flat key-value tile the dashboard already renders. A shared `runPluginWasm` helper does the handler wiring for both the action view and the tile poller. The Rust guest gains two exports: `tile` (flat tile JSON) and `check_sandbox` (attempts a non-allowlisted method and reports the refusal).

**Tech Stack:** Dart 3.11 (common + tui), `wasmtime_dart` (this branch), Rust → `wasm32-wasip1` (guest), just, Jujutsu (jj).

## Global Constraints

- VCS is **jj**. Main-repo commits: `jj commit -m "<msg>"` from repo root, then `jj bookmark set wasm-plugins -r @-`. Commit authorization is granted.
- The **plugins repo** at `examples_redesign/nixblitz_official_plugins/` is a SEPARATE jj-colocated repo — Tasks 4-5 commit there (`jj commit` from inside that dir), NOT on the main stack; do not touch the main repo's `wasm-plugins` bookmark from there.
- Every commit message ends with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (blank line before it). WHY-focused.
- Tests needing the wasm runtime export first: `export WASMTIME_DART_LIB=$(nix-build --no-out-link -E '(import <nixpkgs> {}).callPackage /home/f44/dev/blitz/nixblitz/nix/wasmtime.nix {}')/lib/libwasmtime.so`.
- The tile is the **flat key-value poll tile** (`PluginTileSnapshot.fromCommandOutput`): the poll emits a flat JSON object, each key → a tile row; reserved keys `_status_label`, `_status_color`, `_footer`, `_footer_color`. NOT the `tile_manifests` + `$data` layout DSL (that is streamer-fed, out of scope). node-summary needs NO `tile-*.json` and NO `tile_manifests` entry.
- node-summary stays **logic-only**: a `dashboard` block and a second wasm action do not change `isLogicOnly` (module null, no streamers, all actions wasm). Keep it that way.
- The tile poll runs through the SAME sandbox allowlist as the actions — the `tile` export can only reach the three allowlisted read methods.
- Post-task (main repo, common/tui touched): `cd <pkg> && dart test && dart analyze && dart format .`. Repo trio: `just test; just analyze; just format`.
- Never edit `wasmtime_dart/lib/src/generated/bindings.g.dart`.

## File map

| File                                                                                      | Responsibility                                                                               |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `common/lib/src/models/plugin/plugin_tile.dart` (modify)                                  | `PluginTileSpec` gains `WasmTileSource wasm` (module + export), two-way command/wasm parse   |
| `common/lib/src/services/wasm/wasm_action_runner.dart` (modify)                           | `run(..., bool quiet)` — skip the `> wasm action:` header line for programmatic capture      |
| `common/lib/src/services/wasm/plugin_wasm_run.dart` (create)                              | `runPluginWasm(...)` — build the `HostCallHandler` + run a plugin wasm export via the runner |
| `tui/lib/src/ui/views/plugin_action_view.dart` (modify)                                   | `_startWasmAction` refactored to call `runPluginWasm` (behaviour-preserving)                 |
| `common/lib/src/services/plugin_dashboard_service.dart` (modify)                          | poller wasm branch: `runPluginWasm` → drain → `_interpret`                                   |
| `common/lib/src/providers/plugin_dashboard_provider.dart` (modify, if needed)             | pass the wasm runner / plugin-dir resolver into the service                                  |
| `common/lib/common.dart` (modify)                                                         | export `plugin_wasm_run.dart`                                                                |
| `examples_redesign/nixblitz_official_plugins/node-summary/src/lib.rs` (modify)            | add `tile` + `check_sandbox` guest exports                                                   |
| `examples_redesign/nixblitz_official_plugins/node-summary/actions/summary.wasm` (rebuild) | committed artifact with 3 exports                                                            |
| `examples_redesign/nixblitz_official_plugins/node-summary/plugin.json` (modify)           | `dashboard` wasm block + `check_sandbox` action                                              |
| `examples_redesign/nixblitz_official_plugins/node-summary/README.md` (modify)             | document the tile + self-check                                                               |

## Task sequencing

Tasks 1-3 (models + runtime, main repo) → 4-5 (guest + manifest, plugins repo) → 6 (manual E2E). Each of 1-3 is independently testable; 4-5 are in the separate plugins repo; 6 is manual on the regtest VM.

---

### Task 1: `PluginTileSpec` wasm variant

**Files:**

- Modify: `common/lib/src/models/plugin/plugin_tile.dart`
- Test: `common/test/models/plugin/plugin_tile_test.dart` (add cases; create if absent)

**Interfaces:**

- Produces: `WasmTileSource({required String module, String export})` (export default `"tile"`) with `fromJson`/`toJson`; `PluginTileSpec.wasm` (`WasmTileSource?`); `bool get isWasm => wasm != null`. Exactly one of `command`/`wasm`; `command` becomes nullable (`String? command`). `title`, `accentColorHex`, `pollInterval`, `timeout` unchanged.

- [ ] **Step 1: Write the failing test**

Add to `common/test/models/plugin/plugin_tile_test.dart` (create with this content if absent):

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  test('parses a bash command tile (unchanged)', () {
    final s = PluginTileSpec.fromJson({'title': 'T', 'command': 'echo {}'});
    expect(s.command, 'echo {}');
    expect(s.isWasm, isFalse);
  });

  test('parses a wasm tile', () {
    final s = PluginTileSpec.fromJson({
      'title': 'Node Summary',
      'wasm': {'module': 'actions/summary.wasm', 'export': 'tile'},
      'poll_interval_seconds': 15,
    });
    expect(s.isWasm, isTrue);
    expect(s.wasm!.module, 'actions/summary.wasm');
    expect(s.wasm!.export, 'tile');
    expect(s.command, isNull);
    expect(s.pollInterval.inSeconds, 15);
  });

  test('wasm export defaults to tile', () {
    final s = PluginTileSpec.fromJson({
      'title': 'T',
      'wasm': {'module': 'a.wasm'},
    });
    expect(s.wasm!.export, 'tile');
  });

  test('rejects declaring both command and wasm', () {
    expect(
      () => PluginTileSpec.fromJson({
        'title': 'T',
        'command': 'echo {}',
        'wasm': {'module': 'a.wasm'},
      }),
      throwsFormatException,
    );
  });

  test('rejects declaring neither command nor wasm', () {
    expect(
      () => PluginTileSpec.fromJson({'title': 'T'}),
      throwsFormatException,
    );
  });

  test('rejects a wasm tile with empty module', () {
    expect(
      () => PluginTileSpec.fromJson({
        'title': 'T',
        'wasm': {'module': ''},
      }),
      throwsFormatException,
    );
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/models/plugin/plugin_tile_test.dart`
Expected: FAIL — `isWasm`/`wasm` undefined; the "neither" case currently throws the wrong message.

- [ ] **Step 3: Add WasmTileSource and make the source two-way**

In `plugin_tile.dart`, add the source class (top-level, above `PluginTileSpec`):

```dart
/// A `wasm` tile data source — the tile is polled by running a plugin
/// wasm module's export, whose stdout is a flat tile-state JSON object.
class WasmTileSource {
  const WasmTileSource({required this.module, this.export = 'tile'});

  /// Plugin-dir-relative path to the compiled `.wasm`.
  final String module;

  /// Exported guest function to invoke (no params, no results).
  final String export;

  factory WasmTileSource.fromJson(Map<String, dynamic> json) {
    final module = json['module'];
    if (module is! String || module.isEmpty) {
      throw const FormatException('dashboard.wasm.module is required');
    }
    final export = json['export'] as String? ?? 'tile';
    if (export.isEmpty) {
      throw const FormatException('dashboard.wasm.export must be non-empty');
    }
    return WasmTileSource(module: module, export: export);
  }

  Map<String, dynamic> toJson() => {
    'module': module,
    if (export != 'tile') 'export': export,
  };
}
```

Change `PluginTileSpec`: make `command` nullable, add `wasm`, add `isWasm`:

```dart
  /// Shell command polled at [pollInterval]. Mutually exclusive with
  /// [wasm]. Output is parsed as flat tile-state JSON.
  final String? command;

  /// Sandboxed wasm data source. Mutually exclusive with [command].
  final WasmTileSource? wasm;
```

Add `this.command`, `this.wasm` to the constructor (both optional now — remove `required` from `command`). Add the getter:

```dart
  /// True when this tile is polled via a sandboxed wasm module.
  bool get isWasm => wasm != null;
```

In `fromJson`, replace the `command`-required block with a two-way check (keep the `title`, `poll_interval_seconds`, `timeout`, `accent_color`, `run_as_root` handling exactly as-is):

```dart
    final command = json['command'] as String?;
    final wasmRaw = json['wasm'];
    final wasm = wasmRaw is Map<String, dynamic>
        ? WasmTileSource.fromJson(wasmRaw)
        : null;
    final sources = [command, wasm].where((v) => v != null).length;
    if (sources == 0) {
      throw const FormatException(
        'dashboard must declare either `command` or `wasm`',
      );
    }
    if (sources > 1) {
      throw const FormatException(
        'dashboard declares both `command` and `wasm`; pick one',
      );
    }
    if (command != null && command.isEmpty) {
      throw const FormatException('dashboard.command must be non-empty');
    }
```

Return with `command: command, wasm: wasm,`. In `toJson`, guard the command line (`if (command != null) 'command': command,`) and add `if (wasm != null) 'wasm': wasm!.toJson(),`.

- [ ] **Step 4: Run the tests**

Run: `cd common && dart test test/models/plugin/plugin_tile_test.dart`
Expected: 6 PASS. Also run `cd common && dart test test/models/` to confirm no existing tile/manifest test regressed.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ..
jj commit -m "feat(common): wasm data source for plugin dashboard tiles

A dashboard tile's data source becomes two-way: a bash \`command\` (as
before) or a sandboxed \`wasm\` module + export. This lets a logic-only
plugin drive a tile through the WASM runtime instead of unsandboxed
bash. Parsing rejects declaring both or neither; the flat key-value
tile rendering is unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 2: `runPluginWasm` helper + runner `quiet` mode

**Files:**

- Modify: `common/lib/src/services/wasm/wasm_action_runner.dart` (add `quiet` param)
- Create: `common/lib/src/services/wasm/plugin_wasm_run.dart`
- Modify: `common/lib/common.dart` (export), `tui/lib/src/ui/views/plugin_action_view.dart` (use the helper)
- Test: `common/test/services/wasm/plugin_wasm_run_test.dart`

**Interfaces:**

- Consumes: `WasmActionRunner`, `HostCallHandler`, `BudgetLedger`, `BitcoinCliExecutor`, `SandboxSpec`, `PluginManifest`.
- Produces: `WasmActionRunner.run({..., bool quiet = false})` — when `quiet`, the `> wasm action: <export>` header line is not emitted (the output stream carries only the guest's stdout on success, or the trap/error message on failure). `Future<({Stream<String> output, Future<int> exitCode})> runPluginWasm({required WasmActionRunner runner, required PluginManifest manifest, required String pluginDir, required String moduleRelPath, required String export, required String stateDir, bool quiet = false})`.

- [ ] **Step 1: Add the `quiet` param to the runner**

In `wasm_action_runner.dart`, add `bool quiet = false` to `run(...)`'s named params, and guard the header line:

```dart
        if (!quiet) controller.add('> wasm action: $export\n');
```

(Leave the guest-stdout emission and the trap/error `controller.add('$msg\n')` lines unchanged.)

- [ ] **Step 2: Write the failing test**

`common/test/services/wasm/plugin_wasm_run_test.dart` — uses a WAT fixture guest that emits a flat JSON object via WASI stdout, run through the real helper with a fake executor. Confirms (a) `quiet` strips the header so stdout is pure JSON, and (b) the handler is wired (executor sees the allowlisted call).

```dart
import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

// Guest: calls host_call(getblockchaininfo) then prints a flat tile
// JSON object to stdout. Hardcoded request bytes in a data segment;
// alloc returns a fixed scratch offset (host writes the response there).
const tileWat = r'''
(module
  (import "nixblitz" "host_call" (func $hc (param i32 i32) (result i64)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fdw (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0)
    "{\"v\":1,\"cap\":\"bitcoin_rpc\",\"method\":\"getblockchaininfo\",\"params\":[]}")
  (data (i32.const 200) "{\"Network\":\"regtest\"}")
  (func (export "alloc") (param i32) (result i32) (i32.const 4096))
  (func (export "tile")
    (drop (call $hc (i32.const 0) (i32.const 68)))
    ;; iov at 300: base=200 len=20
    (i32.store (i32.const 300) (i32.const 200))
    (i32.store (i32.const 304) (i32.const 20))
    (drop (call $fdw (i32.const 1) (i32.const 300) (i32.const 1) (i32.const 320)))))
''';

class FakeExecutor implements BitcoinRpcExecutor {
  final List<String> calls = [];
  @override
  RpcResult call(String method, List params) {
    calls.add(method);
    return RpcResult(ok: true, result: {'blocks': 5}, stderr: '');
  }
}

void main() {
  late Directory tmp;
  late WasmActionRunner runner;
  late FakeExecutor executor;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pwr_');
    runner = WasmActionRunner(
      library: WasmtimeLibrary.discover(),
      cacheDir: '${tmp.path}/cache',
    );
    executor = FakeExecutor();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const sandbox = SandboxSpec(
    bitcoinRpc: BitcoinRpcCapability(
        methods: ['getblockchaininfo'], spendSatsPerDay: 0),
  );
  PluginManifest mf() => PluginManifest.fromJson({
        'manifest': {'schema_version': 5, 'name': 'T'},
        'id': 'tplugin',
        'actions': {
          'a': {'label': 'a', 'wasm': {'module': 't.wasm'}},
        },
        'sandbox': {
          'bitcoin_rpc': {'methods': ['getblockchaininfo']},
        },
      });

  test('quiet run returns pure guest stdout + wires the handler', () async {
    // Compile the WAT to a .wasm on disk.
    final engine = Engine(WasmtimeLibrary.discover());
    final bytes = watToWasm(engine, tileWat);
    engine.dispose();
    File('${tmp.path}/t.wasm').writeAsBytesSync(bytes);

    final run = await runPluginWasm(
      runner: runner,
      manifest: mf(),
      pluginDir: tmp.path,
      moduleRelPath: 't.wasm',
      export: 'tile',
      stateDir: '${tmp.path}/state',
      quiet: true,
    );
    final out = await run.output.join();
    final code = await run.exitCode;
    expect(code, 0);
    expect(executor.calls, ['getblockchaininfo']);
    // No "> wasm action" header; stdout is the flat JSON the guest emitted.
    expect(out.trim(), '{"Network":"regtest"}');
  });
}
```

Note: this test constructs `runPluginWasm` with a fixed executor. Since `runPluginWasm` builds its own `BitcoinCliExecutor` internally, add an optional `BitcoinRpcExecutor? executor` param to `runPluginWasm` (defaulting to `BitcoinCliExecutor()`) so tests can inject the fake. Wire it through to the `HostCallHandler`.

- [ ] **Step 3: Run it to verify it fails**

Run: `export WASMTIME_DART_LIB=$(nix-build --no-out-link -E '(import <nixpkgs> {}).callPackage /home/f44/dev/blitz/nixblitz/nix/wasmtime.nix {}')/lib/libwasmtime.so; cd common && dart test test/services/wasm/plugin_wasm_run_test.dart`
Expected: FAIL — `runPluginWasm` undefined.

- [ ] **Step 4: Implement plugin_wasm_run.dart**

```dart
import 'dart:io';

import '../../models/plugin/plugin_manifest.dart';
import '../../models/plugin/sandbox_spec.dart';
import 'bitcoin_rpc_executor.dart';
import 'budget_ledger.dart';
import 'host_call.dart';
import 'wasm_action_runner.dart';

/// Builds the sandbox [HostCallHandler] for [manifest] and runs its wasm
/// [export] via [runner]. Returns the runner's (output, exitCode): the
/// action view streams `output` to its pane; the tile poller drains it.
///
/// [moduleRelPath] is the plugin-dir-relative `.wasm` path (from the
/// action's or tile's `wasm.module`). [stateDir] is the sandbox state
/// root (`$HOME/nixblitz/state/sandbox`); the per-plugin budget ledger
/// lives at `<stateDir>/budgets/<id>.json`. [executor] defaults to the
/// real bitcoin-cli executor; tests inject a fake.
Future<({Stream<String> output, Future<int> exitCode})> runPluginWasm({
  required WasmActionRunner runner,
  required PluginManifest manifest,
  required String pluginDir,
  required String moduleRelPath,
  required String export,
  required String stateDir,
  BitcoinRpcExecutor? executor,
  bool quiet = false,
}) {
  final sandbox = manifest.sandbox ?? const SandboxSpec();
  final handler = HostCallHandler(
    sandbox: sandbox,
    ledger: BudgetLedger('$stateDir/budgets/${manifest.id}.json'),
    executor: executor ?? BitcoinCliExecutor(),
    clock: DateTime.now,
  );
  return runner.run(
    wasmPath: '$pluginDir/$moduleRelPath',
    export: export,
    sandbox: sandbox,
    hostCall: handler,
    quiet: quiet,
  );
}
```

Export it from `common/lib/common.dart`: `export 'src/services/wasm/plugin_wasm_run.dart';`

- [ ] **Step 5: Run the helper test**

Run: `cd common && dart test test/services/wasm/plugin_wasm_run_test.dart` (with `WASMTIME_DART_LIB` exported)
Expected: 1 PASS.

- [ ] **Step 6: Refactor the action view to use the helper**

In `tui/lib/src/ui/views/plugin_action_view.dart`, `_startWasmAction` currently builds the `HostCallHandler` inline and calls `runner.run(...)`. Replace that construction with a `runPluginWasm` call (keeping `quiet: false` so the action pane still shows the `> wasm action:` header, and keeping the existing manifest/pluginDir lookup + the missing-manifest StateError). The stream/exit-code wiring into the phase machinery stays. Net effect: identical behaviour, the handler wiring now lives in the shared helper.

- [ ] **Step 7: gen-locks not needed (no dep change); analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ../tui && dart analyze && dart format . && cd ..
# full suite needs the lib:
export WASMTIME_DART_LIB=$(nix-build --no-out-link -E '(import <nixpkgs> {}).callPackage /home/f44/dev/blitz/nixblitz/nix/wasmtime.nix {}')/lib/libwasmtime.so
just test
jj commit -m "feat(common): shared runPluginWasm helper + runner quiet mode

Extract the 'build a HostCallHandler for a plugin + run its wasm export'
wiring the action view had inline into one helper, so the dashboard
tile poller can reuse the exact same sandbox path. The runner gains a
quiet flag that suppresses the decorative header line for programmatic
callers (the tile parses stdout as JSON; the action pane keeps the
header). The action view is refactored onto the helper, behaviour
unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 3: `PluginDashboardService` polls wasm tiles

**Files:**

- Modify: `common/lib/src/services/plugin_dashboard_service.dart`
- Test: `common/test/services/plugin_dashboard_tile_poll_test.dart`

**Interfaces:**

- Consumes: `runPluginWasm` (Task 2), `PluginTileSpec.isWasm`/`.wasm` (Task 1), `wasmActionRunnerProvider`.
- Produces: top-level `bool tilePollEnabled({required PluginManifest manifest, required bool Function(String id) isAppEnabled})` — a config_schema plugin polls only when enabled; a config-less (logic-only) plugin polls whenever installed. Internal: `_PluginPoller` gains a wasm branch.

**Why the enable-gate change:** `_reconcile` currently does `if (config == null || !config.isAppEnabled(m.id)) continue;`. A logic-only plugin (node-summary) has no config entry, so `isAppEnabled` is false and it is wrongly skipped — its tile would never poll. Same class of bug as the config-less actions gate. The fix mirrors it: gate on the config toggle only for plugins that have one (a `config_schema`).

- [ ] **Step 1: Write the failing test (pure helper)**

`common/test/services/plugin_dashboard_tile_poll_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

PluginManifest _mf(Map<String, dynamic> j) => PluginManifest.fromJson(j);

void main() {
  final logicOnly = _mf({
    'manifest': {'schema_version': 5, 'name': 'Node Summary'},
    'id': 'node-summary',
    'actions': {
      'a': {'label': 'a', 'wasm': {'module': 'a.wasm'}},
    },
    'sandbox': {
      'bitcoin_rpc': {'methods': ['getblockchaininfo']},
    },
    'dashboard': {
      'title': 'Node Summary',
      'wasm': {'module': 'a.wasm', 'export': 'tile'},
    },
  });

  final withConfig = _mf({
    'manifest': {'schema_version': 5, 'name': 'Cfg'},
    'id': 'cfg',
    'module': 'module.nix',
    'config_schema': {
      'id': 'cfg',
      'label': 'Cfg',
      'fields': [
        {'id': 'enable', 'label': 'Enable', 'type': 'bool', 'default': false},
      ],
    },
    'dashboard': {'title': 'Cfg', 'command': 'echo {}'},
  });

  test('logic-only plugin polls regardless of config-enable', () {
    expect(tilePollEnabled(manifest: logicOnly, isAppEnabled: (_) => false),
        isTrue);
  });

  test('config_schema plugin polls only when enabled', () {
    expect(tilePollEnabled(manifest: withConfig, isAppEnabled: (id) => true),
        isTrue);
    expect(tilePollEnabled(manifest: withConfig, isAppEnabled: (id) => false),
        isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/services/plugin_dashboard_tile_poll_test.dart`
Expected: FAIL — `tilePollEnabled` undefined.

- [ ] **Step 3: Implement `tilePollEnabled` + reorder `_reconcile`**

Add the top-level helper to `plugin_dashboard_service.dart` (above the class):

```dart
/// Whether a plugin's dashboard tile should poll. A plugin with a
/// `config_schema` has an enable toggle — poll only when enabled (its
/// daemon is off otherwise, so polling would churn errors). A config-less
/// (logic-only) plugin has no toggle and no daemon; poll it whenever it's
/// installed (the caller already excluded disabled markers).
bool tilePollEnabled({
  required PluginManifest manifest,
  required bool Function(String id) isAppEnabled,
}) {
  if (manifest.configSchema == null) return true;
  return isAppEnabled(manifest.id);
}
```

In `_reconcile`, read the manifest BEFORE the enable check and gate via the helper:

```dart
    for (final m in markers) {
      if (m.disabled) continue;
      try {
        final manifest = _pluginService.readManifest(m.id);
        final spec = manifest.dashboard;
        if (spec == null) continue;
        final cfg = config;
        final enabled = tilePollEnabled(
          manifest: manifest,
          isAppEnabled: (id) => cfg?.isAppEnabled(id) ?? false,
        );
        if (!enabled) continue;
        desired[m.id] = _DesiredTile(spec: spec, manifest: manifest);
      } catch (e, st) {
        LogService.warn(
          'PluginDashboardService: failed to read manifest for ${m.id}: $e',
        );
        LogService.error('manifest read', e, st);
      }
    }
```

Change `desired` to `Map<String, _DesiredTile>` where `_DesiredTile` bundles `spec` + `manifest` (the wasm poll needs the manifest for the sandbox). Add:

```dart
class _DesiredTile {
  const _DesiredTile({required this.spec, required this.manifest});
  final PluginTileSpec spec;
  final PluginManifest manifest;
}
```

Update the teardown/creation loops below to use `desired` values' `.spec`/`.manifest`.

- [ ] **Step 4: Add the wasm branch to `_PluginPoller`**

Give `_PluginPoller` optional wasm fields, set when `spec.isWasm`:

```dart
  final WasmActionRunner? wasmRunner;
  final PluginManifest? manifest;
  final String? pluginDir;
  final String? stateDir;
```

Add them to its constructor. Replace the existing `desired.entries` poller-creation loop with one that reads `_DesiredTile` and threads the wasm bits:

```dart
    for (final entry in desired.entries) {
      final id = entry.key;
      final tile = entry.value; // _DesiredTile
      final spec = tile.spec;
      final existing = _pollers[id];
      if (existing != null && existing.spec == spec) continue;
      existing?.dispose();
      _pollers[id] = _PluginPoller(
        pluginId: id,
        spec: spec,
        runner: _runner,
        wasmRunner:
            spec.isWasm ? _ref.read(wasmActionRunnerProvider) : null,
        manifest: spec.isWasm ? tile.manifest : null,
        pluginDir: spec.isWasm ? '$_pluginsDir/$id' : null,
        stateDir: spec.isWasm
            ? '${Platform.environment['HOME'] ?? '.'}/nixblitz/state/sandbox'
            : null,
        onSnapshot: (_) => _emit(),
      )..start();
    }
```

(`_ref.read(wasmActionRunnerProvider)` is read lazily here, only for wasm tiles, so a dashboard with no wasm tiles never loads libwasmtime.) Add the imports: `dart:io` (Platform), `wasmActionRunnerProvider`, `runPluginWasm`, `WasmActionRunner`. The teardown loop above (`_pollers.keys.where((k) => !desired.containsKey(k))`) is unchanged — `desired` is still keyed by id.

In `_PluginPoller._poll()`, branch before `_interpret`:

```dart
  Future<void> _poll() async {
    if (_disposed) return;
    try {
      final ({int exitCode, String stdout, String stderr}) result;
      if (spec.isWasm) {
        final run = await runPluginWasm(
          runner: wasmRunner!,
          manifest: manifest!,
          pluginDir: pluginDir!,
          moduleRelPath: spec.wasm!.module,
          export: spec.wasm!.export,
          stateDir: stateDir!,
          quiet: true,
        );
        final out = await run.output.join();
        final ec = await run.exitCode;
        result = (
          exitCode: ec,
          stdout: ec == 0 ? out : '',
          stderr: ec == 0 ? '' : out,
        );
      } else {
        result = await runner.runOneShot(
          command: spec.command!,
          timeout: spec.timeout,
        );
      }
      if (_disposed) return;
      _latest = _interpret(result);
    } catch (e, st) {
      LogService.error('plugin tile poll threw for $pluginId', e, st);
      if (_disposed) return;
      _latest = PluginTileSnapshot.failure(spec: spec, reason: 'poll error: $e');
    }
    onSnapshot(_latest);
  }
```

(`spec.command!` is safe on the bash branch: a non-wasm spec always has a command per Task 1's parse.)

- [ ] **Step 5: Run the tests + analyze/format**

```bash
cd common && dart test test/services/plugin_dashboard_tile_poll_test.dart
export WASMTIME_DART_LIB=$(nix-build --no-out-link -E '(import <nixpkgs> {}).callPackage /home/f44/dev/blitz/nixblitz/nix/wasmtime.nix {}')/lib/libwasmtime.so
cd common && dart test && dart analyze && dart format . && cd ..
```

Expected: helper tests PASS (2), full common suite green.

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat(common): poll wasm plugin dashboard tiles through the sandbox

PluginDashboardService's poll loop learns a wasm branch: a tile whose
dashboard block declares a wasm source is run through runPluginWasm
(same sandbox + allowlist as the plugin's actions), its stdout fed to
the same flat-JSON tile interpreter. The enable gate is fixed for
logic-only plugins the same way the actions gate was — a plugin with no
config_schema has no enable toggle, so it polls whenever installed
rather than being skipped as 'not enabled'.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 4: Rust guest — `tile` + `check_sandbox` exports

**Files (plugins repo `examples_redesign/nixblitz_official_plugins/node-summary/`):**

- Modify: `src/lib.rs`
- Rebuild: `actions/summary.wasm`
- (extend the end-to-end ABI check used in the original node-summary task)

**Interfaces:**

- The guest keeps `alloc`, `run`, the `nixblitz.host_call` import. Adds `tile` (no params/results) — calls the three allowlisted read methods, prints ONE flat JSON object of row-label→value plus `_footer`/`_footer_color`. Adds `check_sandbox` (no params/results) — calls `getpeerinfo` (not allowlisted), reads the `method_not_allowed` err envelope, prints the refusal.

- [ ] **Step 1: Add the two exports to src/lib.rs**

Reuse the existing `call(method) -> Result<Value, String>` helper (from the original guest). Add:

```rust
#[no_mangle]
pub extern "C" fn tile() {
    let out = std::io::stdout();
    let mut out = out.lock();
    let json = tile_json().unwrap_or_else(|e| {
        format!("{{\"_footer\":\"error: {}\",\"_footer_color\":\"error\"}}", e)
    });
    use std::io::Write;
    let _ = writeln!(out, "{json}");
}

fn tile_json() -> Result<String, String> {
    let chain = call("getblockchaininfo")?;
    let net = call("getnetworkinfo")?;
    let mem = call("getmempoolinfo")?;
    let verify = chain["verificationprogress"].as_f64().unwrap_or(0.0) * 100.0;
    Ok(format!(
        "{{\"Network\":\"{}\",\"Blocks\":\"{}\",\"Sync\":\"{:.1}%\",\
          \"Peers\":\"{}\",\"Mempool\":\"{} txs\",\
          \"_footer\":\"sandboxed read-only\",\"_footer_color\":\"ok\"}}",
        chain["chain"].as_str().unwrap_or("?"),
        chain["blocks"].as_i64().unwrap_or(-1),
        verify,
        net["connections"].as_i64().unwrap_or(-1),
        mem["size"].as_i64().unwrap_or(-1),
    ))
}

#[no_mangle]
pub extern "C" fn check_sandbox() {
    use std::io::Write;
    let out = std::io::stdout();
    let mut out = out.lock();
    let _ = writeln!(out, "Sandbox self-check");
    let _ = writeln!(out, "──────────────────");
    let _ = writeln!(out, "Attempting a NON-allowlisted call: getpeerinfo");
    match call("getpeerinfo") {
        Ok(_) => {
            let _ = writeln!(
                out,
                "UNEXPECTED: the call succeeded — the sandbox did NOT refuse it."
            );
        }
        Err(e) => {
            let _ = writeln!(out, "→ refused: {e}");
            let _ = writeln!(out);
            let _ = writeln!(
                out,
                "The sandbox blocked a method this plugin never declared."
            );
        }
    }
}
```

Both are reachable exports (the existing `crate-type = ["cdylib"]` + `#[no_mangle] pub extern "C"` keeps them). If the guest's `call()` builds the request with a hardcoded module attribute (`#[link(wasm_import_module = "nixblitz")]` on the extern), it's already correct — no import change.

- [ ] **Step 2: Rebuild the .wasm**

```bash
cd examples_redesign/nixblitz_official_plugins/node-summary
nix build && cmp result/summary.wasm actions/summary.wasm || cp result/summary.wasm actions/summary.wasm
# confirm the three exports + the import:
wasm-tools print actions/summary.wasm | grep -E '\(export|\(import' | grep -E 'run|tile|check_sandbox|alloc|memory|host_call'
```

Expected: exports `alloc`, `run`, `tile`, `check_sandbox`, `memory`; import `nixblitz` `host_call`.

- [ ] **Step 3: Extend the end-to-end ABI check**

Reuse the scratch Dart harness pattern from the original node-summary task (a `WasmActionRunner` + a fake `BitcoinRpcExecutor`, in the MAIN repo, not committed). Run the committed `summary.wasm` for:

- `export: 'tile'` with a fake returning `{blocks:5, chain:"regtest", ...}` / network / mempool — assert stdout is a single flat JSON object with `Network`/`Blocks`/`Sync`/`Peers`/`Mempool`/`_footer` keys and parses via `jsonDecode`.
- `export: 'check_sandbox'` with a fake whose `HostCallHandler` sandbox allowlist does NOT include `getpeerinfo` (so the real handler returns `method_not_allowed`) — assert stdout contains "refused" and "method_not_allowed". Export `WASMTIME_DART_LIB` first.

If either export's stdout is wrong, fix the GUEST to match (the host is frozen). Document any fix.

- [ ] **Step 4: Commit (plugins repo)**

```bash
cd examples_redesign/nixblitz_official_plugins
jj commit -m "feat(node-summary): tile + sandbox-self-check guest exports

The guest gains two exports on the same summary.wasm: \`tile\` emits a
flat tile-state JSON object (Network/Blocks/Sync/Peers/Mempool + a green
footer) for the dashboard poll, and \`check_sandbox\` deliberately calls
a non-allowlisted method (getpeerinfo) and prints the host boundary's
refusal — the interactive proof the sandbox denies what the manifest
never declared.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 5: node-summary manifest — dashboard block + self-check action

**Files (plugins repo):**

- Modify: `examples_redesign/nixblitz_official_plugins/node-summary/plugin.json`
- Modify: `examples_redesign/nixblitz_official_plugins/node-summary/README.md`

**Interfaces:**

- Consumes: the `tile`/`check_sandbox` exports (Task 4), `PluginTileSpec` wasm parse (Task 1).
- Produces: node-summary's `plugin.json` gains a `dashboard` wasm block and a `check_sandbox` action; NO `tile_manifests`, NO `tile-*.json`.

- [ ] **Step 1: Add the dashboard block + action to plugin.json**

Edit `node-summary/plugin.json` to add (alongside the existing `summary` action and `sandbox` block):

```json
"dashboard": {
  "title": "Node Summary",
  "accent_color": "#5bc0be",
  "wasm": { "module": "actions/summary.wasm", "export": "tile" },
  "poll_interval_seconds": 15
},
"actions": {
  "summary": {
    "label": "Node summary",
    "description": "Read-only bitcoind status via the sandbox",
    "confirm": false,
    "wasm": { "module": "actions/summary.wasm", "export": "run" },
    "timeout_seconds": 10
  },
  "check_sandbox": {
    "label": "Sandbox self-check",
    "description": "Attempt a non-allowlisted call; show it refused",
    "confirm": false,
    "wasm": { "module": "actions/summary.wasm", "export": "check_sandbox" },
    "timeout_seconds": 10
  }
}
```

The `sandbox.bitcoin_rpc.methods` allowlist stays exactly `["getblockchaininfo", "getnetworkinfo", "getmempoolinfo"]` — `getpeerinfo` is deliberately absent.

- [ ] **Step 2: Verify it parses as a logic-only v5 manifest with a wasm dashboard**

Throwaway snippet in the MAIN repo (common), deleted after:

```dart
import 'package:common/common.dart';
import 'dart:io';
void main() {
  final m = PluginManifest.fromJsonString(
    File('examples_redesign/nixblitz_official_plugins/node-summary/plugin.json')
        .readAsStringSync());
  print('isLogicOnly: ${m.isLogicOnly}');            // expect true
  print('dashboard.isWasm: ${m.dashboard?.isWasm}'); // expect true
  print('actions: ${m.actions.keys}');               // summary, check_sandbox
}
```

Run: `cd common && dart run /tmp/verify_ns.dart` → `isLogicOnly: true`, `dashboard.isWasm: true`, both actions present. Delete the snippet.

- [ ] **Step 3: README — document the tile + self-check**

Add a short section to `node-summary/README.md`: the plugin now shows a **Node Summary dashboard tile** (polled every 15s through the sandbox — same three read methods, no extra grant) and a **Sandbox self-check** action that attempts a non-allowlisted call (`getpeerinfo`) and shows it refused. Keep the honest-boundary framing.

- [ ] **Step 4: Freshness guard**

`just check-wasm-plugins` (from the MAIN repo) must still pass — the committed `summary.wasm` (rebuilt in Task 4) matches a fresh build.

```bash
just check-wasm-plugins
```

Expected: "node-summary summary.wasm is in sync."

- [ ] **Step 5: Commit (plugins repo)**

```bash
cd examples_redesign/nixblitz_official_plugins
jj commit -m "feat(node-summary): dashboard tile + sandbox self-check action

plugin.json declares a wasm dashboard tile (polled through the sandbox,
no new grant) and a second action that demonstrates the boundary
refusing a non-allowlisted method. Still logic-only, still the same
three-method allowlist. README documents both.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end on the regtest VM (manual)

**Files:** none (manual validation on the running VM).

**Prerequisites:** the main-repo `wasm-plugins` tip built + deployed to the VM (`just vm-deploy`), the plugins-repo `wasm-plugins` branch pushed so the VM can fetch node-summary, and node-summary installed (or reinstalled to pick up the new manifest: `nixblitz plugin add forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/node-summary --branch wasm-plugins`, or `nixblitz plugin update node-summary`).

- [ ] **Step 1: Deploy + refresh the plugin**

Redeploy the TUI (`just vm-deploy`) and reinstall/update node-summary on the VM so its manifest carries the new `dashboard` block + `check_sandbox` action.

- [ ] **Step 2: Verify the dashboard tile**

Open the **Dashboard**. Assert a **Node Summary** tile appears with rows Network / Blocks / Sync / Peers / Mempool showing live regtest data (e.g. `Network: regtest`, `Blocks: 5`), a green "sandboxed read-only" footer, and that it refreshes on its ~15s interval. It must NOT show a red error or "pending" tile.

- [ ] **Step 3: Run the Sandbox self-check action**

Configure → Node Summary → run **Sandbox self-check**. Assert the output pane shows the refusal — "Attempting a NON-allowlisted call: getpeerinfo → refused: method_not_allowed …" and "The sandbox blocked a method this plugin never declared." — exit 0, and (out of an abundance of caution) that `bitcoin-cli getpeerinfo` was never actually run (the node is unaffected).

- [ ] **Step 4: Record the outcome**

Note the result (a screenshot or the pane text). No commit unless a runbook doc is added.

---

## Self-review notes

- **Spec coverage:** §1a → Task 1; §1b (shared helper) + runner quiet → Task 2; §1c poller → Task 3; §1d guest `tile` (flat JSON) → Task 4; §1e (no layout file) → honored (Task 5 adds no tile_manifests); §2 forbidden action (guest `check_sandbox` + manifest action) → Tasks 4-5; §3 testing → Tasks 1-4 (unit + ABI) + Task 6 (E2E).
- **Correction carried from grounding:** the tile is the flat key-value poll tile (`fromCommandOutput`), NOT the `tile_manifests`/`$data` DSL — the plan adds no `tile-*.json` and no `tile_manifests` entry, matching the corrected spec §1d/§1e.
- **Enable-gate fix:** Task 3 also fixes the logic-only-plugin skip in `_reconcile` (same class as the earlier actions-gate fix), via the testable `tilePollEnabled` helper.
- **ABI consistency:** the `tile`/`check_sandbox` exports (Rust, Task 4) match the runner's expectations; the tile emits a flat JSON object that `_interpret` → `fromCommandOutput` turns into rows; `check_sandbox` calls `getpeerinfo`, which is absent from the allowlist declared in Task 5.
