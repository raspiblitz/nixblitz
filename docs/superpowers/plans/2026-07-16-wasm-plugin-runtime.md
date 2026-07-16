# WASM Plugin Runtime (slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a sandboxed WASM plugin tier: manifest v5 `wasm:` actions run by a `WasmActionRunner` in `common` through a single `host_call` import gated by an allowlist + spend-budget policy, proven by a Rust `node-summary` example plugin end to end on regtest then the Pi. Per `docs/superpowers/specs/2026-07-16-wasm-plugin-runtime-design.md`.

**Architecture:** New manifest models (`SandboxSpec`, `wasm` action variant) parse the capability block. `WasmActionRunner` (common, depends on `wasmtime_dart`) instantiates a guest per invocation with fuel/epoch limits, no fs/net, and one host function `nixblitz.host_call` whose Dart implementation enforces the RPC allowlist and the reserve-then-settle `BudgetLedger` before running `bitcoin-cli`. The TUI routes `wasm` actions to the new runner and shows a sandbox consent card for logic-only plugins.

**Tech Stack:** Dart 3.11 (common + tui), `wasmtime_dart` (this branch), Rust → `wasm32-wasip1` + `serde_json` (guest), Nix (flake wrapper + example plugin build), just, Jujutsu (jj).

## Global Constraints

- VCS is **jj**. Commit from repo root: `jj commit -m "<msg>"`; after EVERY commit run `jj bookmark set wasm-plugins -r @-`. Commit authorization is granted for this run.
- Every commit message ends with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (blank line before it). Subject + body explain WHY.
- The **official plugins repo** at `examples_redesign/nixblitz_official_plugins/` is a SEPARATE jj-colocated repo — commit there with its own `jj commit` from inside that dir; do NOT bundle its changes into the main repo's commits.
- `currentPluginManifestVersion` becomes **5**; `minCompatibleManifestVersion` stays **2**. Manifest header key is `schema_version`.
- Manifest field names are snake_case in JSON (`spend_sats_per_day`, `timeout_seconds`), camelCase in Dart.
- Host-side limit clamps: `fuel ≤ 5_000_000_000`, `timeout_seconds ≤ 60`.
- Host ABI is versioned: envelope carries `"v":1`. Import is `nixblitz.host_call(i32,i32)->i64` returning `(ptr<<32)|len`. Guest exports `alloc(i32)->i32` and the action `export` (default `"run"`).
- Error codes (exact strings): `bad_request`, `unknown_capability`, `method_not_allowed`, `budget_exceeded`, `rpc_failed`.
- State dirs: `~/nixblitz/state/sandbox/modules/<sha256>.cwasm` (module cache), `~/nixblitz/state/sandbox/budgets/<plugin-id>.json` (ledger).
- Budget policy: deny-by-default; reserve-then-settle; fail-closed (ledger write failure = refusal; crash between reserve and settle = counted as spent); trailing-24h window.
- No security theater: the sandbox card states the honest boundary (governs what the plugin initiates through the host API; not a wallet-level or node-wide policy). Logic-only plugins show the sandbox card; plugins with a nix module keep the root-grant warning unchanged.
- Post-task in `common`/`tui`: `cd <pkg> && dart test && dart analyze && dart format .`. The repo trio is `just test; just analyze; just format`.
- Time and randomness: the ledger's pure logic takes an injected `DateTime now` — never call `DateTime.now()` inside testable logic.
- Never edit `wasmtime_dart/lib/src/generated/bindings.g.dart`.

## File map

| File                                                                | Responsibility                                                                          |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `common/lib/src/models/plugin/sandbox_spec.dart`                    | `SandboxSpec`, `BitcoinRpcCapability`, `SandboxLimits`, `SandboxBudgets` models + parse |
| `common/lib/src/models/plugin/plugin_action.dart` (modify)          | add `wasm` action variant (`WasmActionSpec`), three-way exclusivity                     |
| `common/lib/src/models/plugin/plugin_manifest.dart` (modify)        | v5 bump; parse `sandbox`; `isLogicOnly`; carry `sandbox` field                          |
| `common/lib/src/services/wasm/sandbox_policy.dart`                  | spend-capable classification, envelope types, gate logic (pure, node-agnostic)          |
| `common/lib/src/services/wasm/budget_ledger.dart`                   | reserve/settle/prune, injected clock, JSON persistence                                  |
| `common/lib/src/services/wasm/bitcoin_rpc_executor.dart`            | `BitcoinRpcExecutor` interface + `bitcoin-cli` impl; fake for tests                     |
| `common/lib/src/services/wasm/host_call.dart`                       | wires policy+ledger+executor into a `host_call` handler over the envelope               |
| `common/lib/src/services/wasm/wasm_action_runner.dart`              | `WasmActionRunner`: instantiate guest, limits, module cache, run, trap-map              |
| `common/lib/src/services/wasm/module_cache.dart`                    | serialize/deserialize compiled modules keyed by wasm hash                               |
| `common/lib/src/services/plugin/plugin_git_ops.dart` (modify)       | `requirePluginNix` gated on `isLogicOnly`                                               |
| `common/lib/src/services/plugin_service.dart` (modify)              | install validation for sandbox; logic-only relaxation; preview carries sandbox          |
| `common/lib/src/models/plugin/plugin_install_preview.dart` (modify) | carry `SandboxSpec?` + `hasNixModule`                                                   |
| `common/lib/src/providers/plugin_action_provider.dart` (modify)     | provide `WasmActionRunner`                                                              |
| `common/lib/common.dart` (modify)                                   | export new services/models                                                              |
| `tui/lib/src/ui/views/plugin_action_view.dart` (modify)             | route `wasm` actions to `WasmActionRunner`                                              |
| `tui/lib/src/ui/views/plugin_install_view.dart` (modify)            | sandbox consent card                                                                    |
| `tui/lib/src/cli/plugin_cli.dart` (modify)                          | sandbox consent in CLI                                                                  |
| `flake.nix` (modify)                                                | wrapper exports `WASMTIME_DART_LIB`                                                     |
| `examples_redesign/nixblitz_official_plugins/node-summary/`         | Rust source, flake, committed `.wasm`, `plugin.json`, README                            |
| `docs/plugin-authoring.md` (modify)                                 | document the wasm tier + ABI                                                            |

## Task sequencing

Tasks 1-3 (models) → 4-7 (ledger/policy/host/runner in common) → 8 (install validation + logic-only) → 9 (provider + action routing) → 10 (TUI consent card) → 11 (flake wiring) → 12 (Rust example) → 13 (freshness guard + docs) → 14 (regtest E2E) → 15 (Pi E2E, un-parks the branch). Each task is independently testable; E2E tasks (14-15) are manual and gated on a running VM/Pi.

---

### Task 1: Sandbox spec models

**Files:**

- Create: `common/lib/src/models/plugin/sandbox_spec.dart`
- Test: `common/test/models/plugin/sandbox_spec_test.dart`
- Modify: `common/lib/common.dart` (export)

**Interfaces:**

- Produces: `SandboxSpec({BitcoinRpcCapability? bitcoinRpc, SandboxLimits limits})` with `SandboxSpec.fromJson(Map)`, `bool get hasBitcoinRpc`, `toJson()`; `BitcoinRpcCapability({required List<String> methods, int spendSatsPerDay})`; `SandboxLimits({int fuel, int timeoutSeconds})` with defaults `fuel: 500000000, timeoutSeconds: 10`. All immutable.

- [ ] **Step 1: Write the failing test**

`common/test/models/plugin/sandbox_spec_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  test('parses a full sandbox block', () {
    final s = SandboxSpec.fromJson({
      'bitcoin_rpc': {
        'methods': ['getblockchaininfo', 'getnetworkinfo'],
        'budgets': {'spend_sats_per_day': 1000},
      },
      'limits': {'fuel': 123, 'timeout_seconds': 7},
    });
    expect(s.hasBitcoinRpc, isTrue);
    expect(s.bitcoinRpc!.methods, ['getblockchaininfo', 'getnetworkinfo']);
    expect(s.bitcoinRpc!.spendSatsPerDay, 1000);
    expect(s.limits.fuel, 123);
    expect(s.limits.timeoutSeconds, 7);
  });

  test('defaults: no bitcoin_rpc, default limits', () {
    final s = SandboxSpec.fromJson({});
    expect(s.hasBitcoinRpc, isFalse);
    expect(s.limits.fuel, 500000000);
    expect(s.limits.timeoutSeconds, 10);
  });

  test('spend_sats_per_day defaults to 0 when budgets absent', () {
    final s = SandboxSpec.fromJson({
      'bitcoin_rpc': {'methods': ['getblockchaininfo']},
    });
    expect(s.bitcoinRpc!.spendSatsPerDay, 0);
  });

  test('rejects non-string methods', () {
    expect(
      () => SandboxSpec.fromJson({
        'bitcoin_rpc': {'methods': [1, 2]},
      }),
      throwsFormatException,
    );
  });

  test('rejects negative spend budget', () {
    expect(
      () => SandboxSpec.fromJson({
        'bitcoin_rpc': {
          'methods': ['getblockchaininfo'],
          'budgets': {'spend_sats_per_day': -1},
        },
      }),
      throwsFormatException,
    );
  });

  test('round-trips through toJson', () {
    final json = {
      'bitcoin_rpc': {
        'methods': ['getblockchaininfo'],
        'budgets': {'spend_sats_per_day': 500},
      },
      'limits': {'fuel': 42, 'timeout_seconds': 3},
    };
    expect(SandboxSpec.fromJson(json).toJson(), json);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/models/plugin/sandbox_spec_test.dart`
Expected: FAIL — `SandboxSpec` undefined.

- [ ] **Step 3: Implement sandbox_spec.dart**

```dart
/// Declarative sandbox capability block from a plugin manifest's
/// top-level `sandbox` field (schema v5). This is the plugin's ENTIRE
/// requested authority — deny-by-default, shown verbatim at consent.
class SandboxSpec {
  const SandboxSpec({this.bitcoinRpc, this.limits = const SandboxLimits()});

  final BitcoinRpcCapability? bitcoinRpc;
  final SandboxLimits limits;

  bool get hasBitcoinRpc => bitcoinRpc != null;

  factory SandboxSpec.fromJson(Map<String, dynamic> json) {
    final rpcRaw = json['bitcoin_rpc'];
    final rpc = rpcRaw is Map<String, dynamic>
        ? BitcoinRpcCapability.fromJson(rpcRaw)
        : null;
    final limitsRaw = json['limits'];
    final limits = limitsRaw is Map<String, dynamic>
        ? SandboxLimits.fromJson(limitsRaw)
        : const SandboxLimits();
    return SandboxSpec(bitcoinRpc: rpc, limits: limits);
  }

  Map<String, dynamic> toJson() => {
    if (bitcoinRpc != null) 'bitcoin_rpc': bitcoinRpc!.toJson(),
    'limits': limits.toJson(),
  };
}

/// The `bitcoin_rpc` capability: an allowlist of bitcoind methods and a
/// daily spend cap enforced by the policy gate.
class BitcoinRpcCapability {
  const BitcoinRpcCapability({
    required this.methods,
    this.spendSatsPerDay = 0,
  });

  final List<String> methods;

  /// Daily spend cap in sats. 0 = the plugin may call no spend-capable
  /// method (and none may appear in [methods]).
  final int spendSatsPerDay;

  factory BitcoinRpcCapability.fromJson(Map<String, dynamic> json) {
    final rawMethods = json['methods'];
    if (rawMethods is! List) {
      throw const FormatException('bitcoin_rpc.methods must be a list');
    }
    final methods = <String>[];
    for (final m in rawMethods) {
      if (m is! String || m.isEmpty) {
        throw FormatException('bitcoin_rpc.methods entries must be non-empty '
            'strings, got ${m.runtimeType}');
      }
      methods.add(m);
    }
    final budgets = json['budgets'];
    var spend = 0;
    if (budgets is Map<String, dynamic>) {
      final raw = budgets['spend_sats_per_day'] ?? 0;
      if (raw is! int || raw < 0) {
        throw FormatException(
            'bitcoin_rpc.budgets.spend_sats_per_day must be a non-negative '
            'integer, got $raw');
      }
      spend = raw;
    }
    return BitcoinRpcCapability(methods: methods, spendSatsPerDay: spend);
  }

  Map<String, dynamic> toJson() => {
    'methods': methods,
    'budgets': {'spend_sats_per_day': spendSatsPerDay},
  };
}

/// Execution limits the guest requests; the runner clamps each to a
/// host-side maximum before applying.
class SandboxLimits {
  const SandboxLimits({this.fuel = 500000000, this.timeoutSeconds = 10});

  final int fuel;
  final int timeoutSeconds;

  factory SandboxLimits.fromJson(Map<String, dynamic> json) {
    final fuel = json['fuel'] ?? 500000000;
    final timeout = json['timeout_seconds'] ?? 10;
    if (fuel is! int || fuel <= 0) {
      throw FormatException('sandbox.limits.fuel must be positive, got $fuel');
    }
    if (timeout is! int || timeout <= 0) {
      throw FormatException(
          'sandbox.limits.timeout_seconds must be positive, got $timeout');
    }
    return SandboxLimits(fuel: fuel, timeoutSeconds: timeout);
  }

  Map<String, dynamic> toJson() => {
    'fuel': fuel,
    'timeout_seconds': timeoutSeconds,
  };
}
```

- [ ] **Step 4: Export from common.dart**

Add to `common/lib/common.dart` (in the models export region, alongside the other `plugin/` exports):

```dart
export 'src/models/plugin/sandbox_spec.dart';
```

- [ ] **Step 5: Run the tests**

Run: `cd common && dart test test/models/plugin/sandbox_spec_test.dart`
Expected: 6 PASS.

- [ ] **Step 6: Analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ..
jj commit -m "feat(common): sandbox capability models for manifest v5

SandboxSpec is a plugin's entire requested authority — the bitcoin_rpc
allowlist, the daily spend cap, and the fuel/timeout the runner will
clamp. Deny-by-default: no bitcoin_rpc block means no node access, and
an absent budget means zero spend. Parsing rejects malformed methods
and negative budgets up front so the install path never sees them.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 2: `wasm` action variant

**Files:**

- Modify: `common/lib/src/models/plugin/plugin_action.dart`
- Test: `common/test/models/plugin/plugin_action_test.dart` (add cases; create if absent)

**Interfaces:**

- Consumes: nothing new.
- Produces: `WasmActionSpec({required String module, String export})` (export default `"run"`); `PluginAction.wasm` field (`WasmActionSpec?`); `bool get isWasm => wasm != null`. Three-way exclusivity: exactly one of `command`/`unit`/`wasm`. `isPrivileged` stays `unit != null` (wasm is never privileged).

- [ ] **Step 1: Write the failing test**

Add to `common/test/models/plugin/plugin_action_test.dart` (create the file with this content if it doesn't exist):

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  test('parses a wasm action', () {
    final a = PluginAction.fromJson({
      'label': 'Node summary',
      'confirm': false,
      'wasm': {'module': 'actions/summary.wasm', 'export': 'run'},
      'timeout_seconds': 10,
    });
    expect(a.isWasm, isTrue);
    expect(a.wasm!.module, 'actions/summary.wasm');
    expect(a.wasm!.export, 'run');
    expect(a.isPrivileged, isFalse);
  });

  test('wasm export defaults to run', () {
    final a = PluginAction.fromJson({
      'label': 'x',
      'wasm': {'module': 'a.wasm'},
    });
    expect(a.wasm!.export, 'run');
  });

  test('rejects an action with both command and wasm', () {
    expect(
      () => PluginAction.fromJson({
        'label': 'x',
        'command': 'echo hi',
        'wasm': {'module': 'a.wasm'},
      }),
      throwsFormatException,
    );
  });

  test('rejects an action with none of command/unit/wasm', () {
    expect(
      () => PluginAction.fromJson({'label': 'x'}),
      throwsFormatException,
    );
  });

  test('rejects a wasm action with empty module', () {
    expect(
      () => PluginAction.fromJson({
        'label': 'x',
        'wasm': {'module': ''},
      }),
      throwsFormatException,
    );
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/models/plugin/plugin_action_test.dart`
Expected: FAIL — `isWasm` / `wasm` undefined.

- [ ] **Step 3: Add WasmActionSpec and wire the field**

In `common/lib/src/models/plugin/plugin_action.dart`, add the spec class (top-level, after the imports/before `PluginActionInput`):

```dart
/// A `wasm:` action — a sandboxed guest module invoked through the
/// WASM runtime instead of bash or systemd.
class WasmActionSpec {
  const WasmActionSpec({required this.module, this.export = 'run'});

  /// Plugin-dir-relative path to the compiled `.wasm`.
  final String module;

  /// Exported guest function to invoke (no params, no results).
  final String export;

  factory WasmActionSpec.fromJson(Map<String, dynamic> json) {
    final module = json['module'];
    if (module is! String || module.isEmpty) {
      throw const FormatException('action.wasm.module is required');
    }
    final export = json['export'] as String? ?? 'run';
    if (export.isEmpty) {
      throw const FormatException('action.wasm.export must be non-empty');
    }
    return WasmActionSpec(module: module, export: export);
  }

  Map<String, dynamic> toJson() => {
    'module': module,
    if (export != 'run') 'export': export,
  };
}
```

Add the field to `PluginAction` (after `unit`):

```dart
  /// Sandboxed WASM action. Mutually exclusive with [command]/[unit].
  final WasmActionSpec? wasm;
```

Add `this.wasm` to the constructor. Add the getter next to `isPrivileged`:

```dart
  /// True when this action runs a sandboxed WASM guest.
  bool get isWasm => wasm != null;
```

In `fromJson`, replace the command/unit exclusivity block. The existing code reads `command`/`unit` then checks "must declare either" and "declares both". Replace with a three-way check:

```dart
    final command = json['command'] as String?;
    final unit = json['unit'] as String?;
    final wasmRaw = json['wasm'];
    final wasm = wasmRaw is Map<String, dynamic>
        ? WasmActionSpec.fromJson(wasmRaw)
        : null;
    final variants = [command, unit, wasm].where((v) => v != null).length;
    if (variants == 0) {
      throw FormatException(
        'action `$label` must declare one of `command`, `unit`, or `wasm`',
      );
    }
    if (variants > 1) {
      throw FormatException(
        'action `$label` declares more than one of `command`/`unit`/`wasm`; '
        'pick one',
      );
    }
```

Keep the existing empty-`command`/empty-`unit` checks. Add `wasm: wasm,` to the returned `PluginAction(...)`. Add to `toJson`: `if (wasm != null) 'wasm': wasm!.toJson(),`.

- [ ] **Step 4: Run the tests**

Run: `cd common && dart test test/models/plugin/plugin_action_test.dart`
Expected: 5 PASS (plus any pre-existing action tests still green — run the file).

- [ ] **Step 5: Analyze, format, commit**

```bash
cd common && dart test && dart analyze && dart format . && cd ..
jj commit -m "feat(common): wasm action variant (manifest v5)

Actions become three-way: exactly one of command/unit/wasm. A wasm
action names a plugin-dir-relative module and an export; it is never
privileged (no sudo or systemd path), so the runner and consent flow
treat it as the lowest-authority action type.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 3: Manifest v5 — parse `sandbox`, `isLogicOnly`, version bump

**Files:**

- Modify: `common/lib/src/models/plugin/plugin_manifest.dart`
- Test: `common/test/models/plugin/plugin_manifest_test.dart` (add cases)

**Interfaces:**

- Consumes: `SandboxSpec` (Task 1), `PluginAction.isWasm` (Task 2).
- Produces: `PluginManifest.sandbox` (`SandboxSpec?`); `bool get isLogicOnly` (true iff `module == null` AND no `unit:` action AND `streamers.isEmpty`); `currentPluginManifestVersion == 5`.

- [ ] **Step 1: Write the failing test**

Add to `common/test/models/plugin/plugin_manifest_test.dart`:

```dart
  test('currentPluginManifestVersion is 5', () {
    expect(currentPluginManifestVersion, 5);
  });

  test('parses a v5 logic-only wasm plugin with a sandbox block', () {
    final m = PluginManifest.fromJson({
      'manifest': {'schema_version': 5, 'name': 'Node Summary'},
      'id': 'node-summary',
      'actions': {
        'summary': {
          'label': 'Node summary',
          'wasm': {'module': 'actions/summary.wasm'},
        },
      },
      'sandbox': {
        'bitcoin_rpc': {
          'methods': ['getblockchaininfo'],
          'budgets': {'spend_sats_per_day': 0},
        },
      },
    });
    expect(m.sandbox, isNotNull);
    expect(m.sandbox!.bitcoinRpc!.methods, ['getblockchaininfo']);
    expect(m.isLogicOnly, isTrue);
  });

  test('a plugin with a nix module is not logic-only', () {
    final m = PluginManifest.fromJson({
      'manifest': {'schema_version': 5, 'name': 'x'},
      'module': 'module.nix',
    });
    expect(m.isLogicOnly, isFalse);
  });

  test('a plugin with a streamer is not logic-only', () {
    final m = PluginManifest.fromJson({
      'manifest': {'schema_version': 5, 'name': 'x'},
      'streamers': [
        {'id': 's', 'command': 'echo', 'interval_seconds': 5},
      ],
    });
    expect(m.isLogicOnly, isFalse);
  });
```

(If `StreamerSpec`'s required JSON keys differ, adjust that fixture to a minimal valid streamer — grep `plugin_streamer_spec.dart` `fromJson`.)

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/models/plugin/plugin_manifest_test.dart`
Expected: FAIL — version is 4 / `sandbox` and `isLogicOnly` undefined.

- [ ] **Step 3: Implement the changes**

In `plugin_manifest.dart`:

1. Change `const int currentPluginManifestVersion = 4;` to `= 5;`. Add a doc line to the version history comment above it: `/// v5 (current): wasm actions, top-level sandbox block, optional plugin.nix for logic-only plugins.`
2. Add the field (near `teardown`):

```dart
  /// Declarative WASM sandbox capability set (schema v5). Null when the
  /// plugin declares no `sandbox` block.
  final SandboxSpec? sandbox;
```

Add `this.sandbox` to the constructor.

3. In `fromJson`, after the teardown parse block, add:

```dart
    final sandboxRaw = json['sandbox'];
    final sandbox = sandboxRaw is Map<String, dynamic>
        ? SandboxSpec.fromJson(sandboxRaw)
        : null;
```

Add `sandbox: sandbox,` to the returned `PluginManifest(...)`.

4. Add the getter (after the constructor / near other getters; if none, place it after the factory):

```dart
  /// A logic-only plugin needs no NixOS config: no nix module, no
  /// privileged unit action, no streamers. Such plugins may omit
  /// plugin.nix (their only surface is sandboxed wasm actions).
  bool get isLogicOnly =>
      module == null &&
      streamers.isEmpty &&
      !actions.values.any((a) => a.unit != null);
```

5. Add `import 'sandbox_spec.dart';` at the top if the models are in separate files (they are). If `toJson` exists on the manifest, add `if (sandbox != null) 'sandbox': sandbox!.toJson(),`.

- [ ] **Step 4: Run the tests**

Run: `cd common && dart test test/models/plugin/plugin_manifest_test.dart`
Expected: all PASS (new + pre-existing).

- [ ] **Step 5: Full model suite, analyze, format, commit**

```bash
cd common && dart test test/models/ && dart analyze && dart format . && cd ..
jj commit -m "feat(common): manifest v5 — sandbox block + logic-only plugins

Schema bumps to v5: manifests may carry a top-level sandbox capability
block, and a plugin whose only surface is sandboxed wasm actions (no
nix module, no privileged unit, no streamer) is logic-only — the
trust tier where install need not grant root. isLogicOnly is the
predicate the install path and consent screen key on.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 4: Budget ledger

**Files:**

- Create: `common/lib/src/services/wasm/budget_ledger.dart`
- Test: `common/test/services/wasm/budget_ledger_test.dart`
- Modify: `common/lib/common.dart` (export)

**Interfaces:**

- Produces: `BudgetLedger(String path)` (path to the plugin's JSON ledger file); methods `int spentWithin(DateTime now)` (sum of sats in the trailing 24h, pruning older entries from the in-memory view); `String reserve(DateTime now, String method, int sats)` returns a reservation id and persists it; `void settle(String reservationId, int actualSats)` (adjusts + persists); `void cancel(String reservationId)`. Persistence is synchronous JSON (atomic temp+rename). A failed write throws `BudgetLedgerException` — callers treat that as refusal.
- Ledger entry JSON: `{"id":"...","ts":"<iso8601>","method":"...","sats":N,"settled":bool}`.

- [ ] **Step 1: Write the failing test**

`common/test/services/wasm/budget_ledger_test.dart`:

```dart
import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String ledgerPath;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ledger_test_');
    ledgerPath = '${tmp.path}/budget.json';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final t0 = DateTime.utc(2026, 7, 16, 12, 0, 0);

  test('empty ledger spends 0', () {
    expect(BudgetLedger(ledgerPath).spentWithin(t0), 0);
  });

  test('reserve then settle records actual spend', () {
    final l = BudgetLedger(ledgerPath);
    final id = l.reserve(t0, 'sendtoaddress', 1000);
    expect(l.spentWithin(t0), 1000); // reservation counts immediately
    l.settle(id, 850);
    expect(l.spentWithin(t0), 850);
  });

  test('cancel removes a reservation', () {
    final l = BudgetLedger(ledgerPath);
    final id = l.reserve(t0, 'send', 500);
    l.cancel(id);
    expect(l.spentWithin(t0), 0);
  });

  test('entries older than 24h are excluded from the window', () {
    final l = BudgetLedger(ledgerPath);
    l.reserve(t0, 'send', 700);
    final later = t0.add(const Duration(hours: 25));
    expect(l.spentWithin(later), 0);
  });

  test('reservation survives reload (fail-closed on crash)', () {
    BudgetLedger(ledgerPath).reserve(t0, 'send', 300);
    // New instance = simulated process restart; reservation persisted.
    expect(BudgetLedger(ledgerPath).spentWithin(t0), 300);
  });

  test('write failure throws BudgetLedgerException', () {
    // A path whose parent does not exist and cannot be created.
    final l = BudgetLedger('/proc/nonexistent/budget.json');
    expect(() => l.reserve(t0, 'send', 1), throwsA(isA<BudgetLedgerException>()));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/services/wasm/budget_ledger_test.dart`
Expected: FAIL — `BudgetLedger` undefined.

- [ ] **Step 3: Implement budget_ledger.dart**

```dart
import 'dart:convert';
import 'dart:io';

/// Raised when the ledger cannot be persisted. Callers MUST treat this
/// as a spend refusal (fail-closed) — never let a spend proceed whose
/// accounting could not be written.
class BudgetLedgerException implements Exception {
  BudgetLedgerException(this.message);
  final String message;
  @override
  String toString() => 'BudgetLedgerException: $message';
}

class _Entry {
  _Entry(this.id, this.ts, this.method, this.sats, this.settled);
  final String id;
  final DateTime ts;
  final String method;
  int sats;
  bool settled;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': ts.toIso8601String(),
    'method': method,
    'sats': sats,
    'settled': settled,
  };

  factory _Entry.fromJson(Map<String, dynamic> j) => _Entry(
    j['id'] as String,
    DateTime.parse(j['ts'] as String),
    j['method'] as String,
    j['sats'] as int,
    j['settled'] as bool? ?? true,
  );
}

/// Per-plugin spend ledger with a trailing-24h window and
/// reserve-then-settle accounting. Synchronous, atomic JSON persistence
/// (matches the codebase's sync-IO discipline). One instance ≈ one
/// plugin id; construct fresh per invocation (it reloads from disk).
class BudgetLedger {
  BudgetLedger(this.path) {
    _load();
  }

  final String path;
  final List<_Entry> _entries = [];
  var _counter = 0;

  void _load() {
    final f = File(path);
    if (!f.existsSync()) return;
    try {
      final data = jsonDecode(f.readAsStringSync()) as List;
      for (final e in data) {
        _entries.add(_Entry.fromJson(e as Map<String, dynamic>));
      }
    } catch (_) {
      // A corrupt ledger is treated as empty; the atomic writer below
      // replaces it on the next reserve. (Fail-closed still holds: a
      // missing history can only reduce apparent spend for THIS process,
      // and the file is rewritten cleanly.)
    }
  }

  void _persist() {
    try {
      final tmp = File('$path.tmp');
      tmp.parent.createSync(recursive: true);
      tmp.writeAsStringSync(
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
      tmp.renameSync(path);
    } catch (e) {
      throw BudgetLedgerException('could not persist $path: $e');
    }
  }

  /// Sum of sats in the trailing 24h window ending at [now].
  int spentWithin(DateTime now) {
    final cutoff = now.subtract(const Duration(hours: 24));
    return _entries
        .where((e) => e.ts.isAfter(cutoff))
        .fold(0, (sum, e) => sum + e.sats);
  }

  /// Records an intended spend and persists it BEFORE the caller
  /// executes the RPC. Returns the reservation id for [settle]/[cancel].
  String reserve(DateTime now, String method, int sats) {
    final id = '${now.microsecondsSinceEpoch}-${_counter++}';
    _entries.add(_Entry(id, now, method, sats, false));
    _persist();
    return id;
  }

  /// Adjusts a reservation to the actual spent amount and persists.
  void settle(String reservationId, int actualSats) {
    final e = _entries.firstWhere((e) => e.id == reservationId);
    e.sats = actualSats;
    e.settled = true;
    _persist();
  }

  /// Removes a reservation (RPC refused/failed before spending).
  void cancel(String reservationId) {
    _entries.removeWhere((e) => e.id == reservationId);
    _persist();
  }
}
```

- [ ] **Step 4: Export + run**

Add to `common/lib/common.dart`: `export 'src/services/wasm/budget_ledger.dart';`

Run: `cd common && dart test test/services/wasm/budget_ledger_test.dart`
Expected: 6 PASS.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ..
jj commit -m "feat(common): per-plugin spend BudgetLedger

Reserve-then-settle over a trailing-24h window: the intended spend is
persisted before the RPC runs, then adjusted to the actual amount, so a
crash between the two counts as spent rather than vanishing. A ledger
that cannot be written throws — callers treat that as a refusal, so a
plugin can never spend past a failure to account for it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 5: Sandbox policy — classification + envelope + gate

**Files:**

- Create: `common/lib/src/services/wasm/sandbox_policy.dart`
- Test: `common/test/services/wasm/sandbox_policy_test.dart`
- Modify: `common/lib/common.dart` (export)

**Interfaces:**

- Consumes: `BitcoinRpcCapability` (Task 1).
- Produces:
  - `const Set<String> spendCapableBitcoinMethods` (sendtoaddress, sendmany, send, fundrawtransaction, walletcreatefundedpsbt, sendrawtransaction).
  - `bool isSpendCapable(String method)`.
  - `int? attributedSpendSats(String method, List params)` — intended sats a call would move from its params, or `null` if unattributable (v1: attributes `sendtoaddress`(param 1 = BTC amount), else null for other spend methods → those are not allowlistable, enforced at install).
  - `HostRequest.parse(String json)` → `{int v, String cap, String method, List params}` throwing `HostRequestError(code, message)` on malformed input; `HostResponse.ok(dynamic result)` / `HostResponse.err(String code, String message)` → JSON string.
  - `PolicyDecision checkCall({required BitcoinRpcCapability cap, required String method, required List params, required int spentToday})` returning one of: `PolicyAllow(int? reserveSats)` or `PolicyDeny(String code, String message)`.

- [ ] **Step 1: Write the failing test**

`common/test/services/wasm/sandbox_policy_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  const readCap =
      BitcoinRpcCapability(methods: ['getblockchaininfo'], spendSatsPerDay: 0);
  const spendCap = BitcoinRpcCapability(
      methods: ['sendtoaddress'], spendSatsPerDay: 1000);

  test('spend-capable classification', () {
    expect(isSpendCapable('sendtoaddress'), isTrue);
    expect(isSpendCapable('getblockchaininfo'), isFalse);
  });

  test('attributes sendtoaddress amount (BTC->sats)', () {
    expect(attributedSpendSats('sendtoaddress', ['bc1..', 0.0001]), 10000);
    expect(attributedSpendSats('getblockchaininfo', []), 0);
  });

  test('allows an allowlisted read method', () {
    final d = checkCall(
        cap: readCap, method: 'getblockchaininfo', params: [], spentToday: 0);
    expect(d, isA<PolicyAllow>());
    expect((d as PolicyAllow).reserveSats, anyOf(isNull, 0));
  });

  test('denies a non-allowlisted method', () {
    final d = checkCall(
        cap: readCap, method: 'stop', params: [], spentToday: 0);
    expect((d as PolicyDeny).code, 'method_not_allowed');
  });

  test('allows a spend within budget and reserves it', () {
    final d = checkCall(
        cap: spendCap,
        method: 'sendtoaddress',
        params: ['bc1..', 0.000005], // 500 sats
        spentToday: 0);
    expect((d as PolicyAllow).reserveSats, 500);
  });

  test('denies a spend that exceeds the remaining budget', () {
    final d = checkCall(
        cap: spendCap,
        method: 'sendtoaddress',
        params: ['bc1..', 0.00001], // 1000 sats
        spentToday: 600); // only 400 left
    expect((d as PolicyDeny).code, 'budget_exceeded');
  });

  test('HostRequest.parse rejects malformed json', () {
    expect(() => HostRequest.parse('not json'),
        throwsA(isA<HostRequestError>()));
  });

  test('HostResponse.ok/err serialize with version', () {
    expect(HostResponse.ok({'a': 1}), '{"v":1,"ok":{"a":1}}');
    expect(HostResponse.err('rpc_failed', 'boom'),
        '{"v":1,"err":{"code":"rpc_failed","message":"boom"}}');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/services/wasm/sandbox_policy_test.dart`
Expected: FAIL — symbols undefined.

- [ ] **Step 3: Implement sandbox_policy.dart**

```dart
import 'dart:convert';

import '../../models/plugin/sandbox_spec.dart';

/// bitcoind methods that can move funds. A method NOT in this set is
/// read-only for budget purposes.
const Set<String> spendCapableBitcoinMethods = {
  'sendtoaddress',
  'sendmany',
  'send',
  'sendrawtransaction',
  'fundrawtransaction',
  'walletcreatefundedpsbt',
};

bool isSpendCapable(String method) =>
    spendCapableBitcoinMethods.contains(method);

/// Intended sats a call moves, derived from its params — or null if the
/// cost cannot be attributed from params alone (such methods are not
/// allowlistable in v1; install validation rejects them). Read methods
/// return 0.
int? attributedSpendSats(String method, List<dynamic> params) {
  if (!isSpendCapable(method)) return 0;
  switch (method) {
    case 'sendtoaddress':
      // params: [address, amount(BTC), ...]
      if (params.length >= 2 && params[1] is num) {
        return ((params[1] as num) * 100000000).round();
      }
      return null;
    default:
      return null; // unattributable in v1
  }
}

/// Raised by HostRequest.parse on malformed guest input.
class HostRequestError implements Exception {
  HostRequestError(this.code, this.message);
  final String code;
  final String message;
}

/// A parsed, validated host_call request envelope.
class HostRequest {
  HostRequest(this.v, this.cap, this.method, this.params);
  final int v;
  final String cap;
  final String method;
  final List<dynamic> params;

  static HostRequest parse(String jsonStr) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      throw HostRequestError('bad_request', 'request is not valid JSON');
    }
    if (decoded is! Map) {
      throw HostRequestError('bad_request', 'request must be a JSON object');
    }
    final v = decoded['v'];
    final cap = decoded['cap'];
    final method = decoded['method'];
    final params = decoded['params'] ?? const [];
    if (v is! int) {
      throw HostRequestError('bad_request', 'missing/invalid `v`');
    }
    if (cap is! String || cap.isEmpty) {
      throw HostRequestError('bad_request', 'missing/invalid `cap`');
    }
    if (method is! String || method.isEmpty) {
      throw HostRequestError('bad_request', 'missing/invalid `method`');
    }
    if (params is! List) {
      throw HostRequestError('bad_request', '`params` must be an array');
    }
    return HostRequest(v, cap, method, params);
  }
}

/// Serializers for the response envelope.
class HostResponse {
  static String ok(dynamic result) => jsonEncode({'v': 1, 'ok': result});
  static String err(String code, String message) =>
      jsonEncode({'v': 1, 'err': {'code': code, 'message': message}});
}

/// Outcome of the policy gate for one call.
sealed class PolicyDecision {
  const PolicyDecision();
}

class PolicyAllow extends PolicyDecision {
  const PolicyAllow(this.reserveSats);
  /// Sats to reserve on the ledger before executing (null/0 = no spend).
  final int? reserveSats;
}

class PolicyDeny extends PolicyDecision {
  const PolicyDeny(this.code, this.message);
  final String code;
  final String message;
}

/// The allowlist + budget gate. Pure: [spentToday] is supplied by the
/// caller (from the BudgetLedger) so this stays node- and clock-free.
PolicyDecision checkCall({
  required BitcoinRpcCapability cap,
  required String method,
  required List<dynamic> params,
  required int spentToday,
}) {
  if (!cap.methods.contains(method)) {
    return PolicyDeny('method_not_allowed',
        'method `$method` is not in this plugin\'s allowlist');
  }
  if (!isSpendCapable(method)) {
    return const PolicyAllow(0);
  }
  final intended = attributedSpendSats(method, params);
  if (intended == null) {
    return PolicyDeny('method_not_allowed',
        'method `$method` has an unattributable spend and is not permitted');
  }
  if (spentToday + intended > cap.spendSatsPerDay) {
    return PolicyDeny('budget_exceeded',
        'spend of $intended sats would exceed the daily cap '
        '(${cap.spendSatsPerDay}, already spent $spentToday)');
  }
  return PolicyAllow(intended);
}
```

- [ ] **Step 4: Export + run**

Add to `common/lib/common.dart`: `export 'src/services/wasm/sandbox_policy.dart';`

Run: `cd common && dart test test/services/wasm/sandbox_policy_test.dart`
Expected: 8 PASS.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ..
jj commit -m "feat(common): sandbox policy gate — allowlist + spend attribution

The pure decision core the host_call boundary runs: deny anything off
the manifest allowlist, classify spend-capable methods, attribute a
call's sat cost from its params, and refuse a spend that would breach
the daily cap. Methods whose cost can't be attributed are refused
rather than guessed — so the ledger never has to estimate, and install
validation can reject them up front.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 6: bitcoin-cli executor + host_call handler

**Files:**

- Create: `common/lib/src/services/wasm/bitcoin_rpc_executor.dart`, `common/lib/src/services/wasm/host_call.dart`
- Test: `common/test/services/wasm/host_call_test.dart`
- Modify: `common/lib/common.dart` (export both)

**Interfaces:**

- Consumes: `checkCall`, `HostRequest`, `HostResponse`, `PolicyAllow`/`PolicyDeny` (Task 5); `BudgetLedger` (Task 4); `BitcoinRpcCapability` (Task 1).
- Produces:
  - `abstract class BitcoinRpcExecutor { RpcResult call(String method, List params); }` with `RpcResult({required bool ok, dynamic result, String stderr})`; concrete `BitcoinCliExecutor` (runs `bitcoin-cli`); the handler takes an executor so tests inject a fake.
  - `class HostCallHandler` constructed with `{required SandboxSpec sandbox, required BudgetLedger ledger, required BitcoinRpcExecutor executor, required DateTime Function() clock}`; method `String handle(String requestJson)` returning a response-envelope JSON string. This is the pure-Dart body the runner passes to `linker.defineFunc`.
- Settlement: for a spend, `attributedSpendSats(method, result-aware)` isn't available post-hoc in v1; settle to the reserved amount unless the executor's result exposes a fee (v1: settle to the reserved intended amount — documented; a later slice refines from the tx result).

- [ ] **Step 1: Write the failing test**

`common/test/services/wasm/host_call_test.dart`:

```dart
import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

class FakeExecutor implements BitcoinRpcExecutor {
  FakeExecutor(this._results);
  final Map<String, RpcResult> _results;
  final List<String> calls = [];
  @override
  RpcResult call(String method, List params) {
    calls.add(method);
    return _results[method] ??
        RpcResult(ok: false, result: null, stderr: 'no fake for $method');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('hostcall_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final clock = () => DateTime.utc(2026, 7, 16, 12);

  HostCallHandler handler(SandboxSpec sandbox, FakeExecutor ex) => HostCallHandler(
        sandbox: sandbox,
        ledger: BudgetLedger('${tmp.path}/b.json'),
        executor: ex,
        clock: clock,
      );

  const readSandbox = SandboxSpec(
    bitcoinRpc: BitcoinRpcCapability(
        methods: ['getblockchaininfo'], spendSatsPerDay: 0),
  );

  test('allowed read method returns ok with the rpc result', () {
    final ex = FakeExecutor({
      'getblockchaininfo': RpcResult(ok: true, result: {'blocks': 42}, stderr: ''),
    });
    final resp = handler(readSandbox, ex).handle(
        '{"v":1,"cap":"bitcoin_rpc","method":"getblockchaininfo","params":[]}');
    expect(resp, '{"v":1,"ok":{"blocks":42}}');
    expect(ex.calls, ['getblockchaininfo']);
  });

  test('non-allowlisted method is refused and never executed', () {
    final ex = FakeExecutor({});
    final resp = handler(readSandbox, ex)
        .handle('{"v":1,"cap":"bitcoin_rpc","method":"stop","params":[]}');
    expect(resp, contains('method_not_allowed'));
    expect(ex.calls, isEmpty);
  });

  test('unknown capability is refused', () {
    final resp = handler(readSandbox, FakeExecutor({}))
        .handle('{"v":1,"cap":"lightning","method":"x","params":[]}');
    expect(resp, contains('unknown_capability'));
  });

  test('rpc failure surfaces rpc_failed with stderr', () {
    final ex = FakeExecutor({
      'getblockchaininfo':
          RpcResult(ok: false, result: null, stderr: 'connection refused'),
    });
    final resp = handler(readSandbox, ex).handle(
        '{"v":1,"cap":"bitcoin_rpc","method":"getblockchaininfo","params":[]}');
    expect(resp, contains('rpc_failed'));
    expect(resp, contains('connection refused'));
  });

  test('a spend within budget executes and is accounted', () {
    const spendSandbox = SandboxSpec(
        bitcoinRpc: BitcoinRpcCapability(
            methods: ['sendtoaddress'], spendSatsPerDay: 1000));
    final ex = FakeExecutor({
      'sendtoaddress': RpcResult(ok: true, result: 'txid', stderr: ''),
    });
    final h = handler(spendSandbox, ex);
    final resp = h.handle('{"v":1,"cap":"bitcoin_rpc","method":"sendtoaddress",'
        '"params":["bc1..",0.000005]}');
    expect(resp, contains('txid'));
    expect(ex.calls, ['sendtoaddress']);
  });

  test('a spend over budget is refused and never executed', () {
    const spendSandbox = SandboxSpec(
        bitcoinRpc: BitcoinRpcCapability(
            methods: ['sendtoaddress'], spendSatsPerDay: 100));
    final ex = FakeExecutor({});
    final resp = handler(spendSandbox, ex).handle(
        '{"v":1,"cap":"bitcoin_rpc","method":"sendtoaddress",'
        '"params":["bc1..",0.00001]}'); // 1000 sats > 100
    expect(resp, contains('budget_exceeded'));
    expect(ex.calls, isEmpty);
  });

  test('malformed request json returns bad_request', () {
    final resp = handler(readSandbox, FakeExecutor({})).handle('garbage');
    expect(resp, contains('bad_request'));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/services/wasm/host_call_test.dart`
Expected: FAIL — symbols undefined.

- [ ] **Step 3: Implement bitcoin_rpc_executor.dart**

```dart
import 'dart:convert';
import 'dart:io';

/// Result of one bitcoind RPC via bitcoin-cli.
class RpcResult {
  RpcResult({required this.ok, required this.result, required this.stderr});
  final bool ok;
  final dynamic result; // decoded JSON (or a raw string for non-JSON output)
  final String stderr;
}

/// Runs a bitcoind method. Injected into HostCallHandler so tests use a
/// fake and never touch a node.
abstract class BitcoinRpcExecutor {
  RpcResult call(String method, List<dynamic> params);
}

/// Real executor: shells out to `bitcoin-cli`, which nix-bitcoin wraps
/// with the operator's cookie auth (same path the streamers use). The
/// guest never sees credentials.
class BitcoinCliExecutor implements BitcoinRpcExecutor {
  BitcoinCliExecutor({this.systemPath = '/run/current-system/sw/bin'});
  final String systemPath;

  @override
  RpcResult call(String method, List<dynamic> params) {
    final args = <String>[
      method,
      for (final p in params) p is String ? p : jsonEncode(p),
    ];
    final env = {
      ...Platform.environment,
      'PATH': '$systemPath:${Platform.environment['PATH'] ?? ''}',
    };
    final r = Process.runSync('bitcoin-cli', args,
        environment: env, includeParentEnvironment: false);
    if (r.exitCode != 0) {
      return RpcResult(ok: false, result: null, stderr: (r.stderr as String).trim());
    }
    final out = (r.stdout as String).trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(out);
    } catch (_) {
      decoded = out; // some methods return a bare string (e.g. a txid)
    }
    return RpcResult(ok: true, result: decoded, stderr: '');
  }
}
```

- [ ] **Step 4: Implement host_call.dart**

```dart
import '../../models/plugin/sandbox_spec.dart';
import 'bitcoin_rpc_executor.dart';
import 'budget_ledger.dart';
import 'sandbox_policy.dart';

/// The policy-enforcing body behind the `nixblitz.host_call` import.
/// Pure Dart over strings: the runner handles the wasm memory marshaling
/// and passes the request JSON in, the response JSON out.
class HostCallHandler {
  HostCallHandler({
    required this.sandbox,
    required this.ledger,
    required this.executor,
    required this.clock,
  });

  final SandboxSpec sandbox;
  final BudgetLedger ledger;
  final BitcoinRpcExecutor executor;
  final DateTime Function() clock;

  String handle(String requestJson) {
    final HostRequest req;
    try {
      req = HostRequest.parse(requestJson);
    } on HostRequestError catch (e) {
      return HostResponse.err(e.code, e.message);
    }

    if (req.cap != 'bitcoin_rpc') {
      return HostResponse.err(
          'unknown_capability', 'capability `${req.cap}` is not supported');
    }
    final cap = sandbox.bitcoinRpc;
    if (cap == null) {
      return HostResponse.err(
          'unknown_capability', 'this plugin was granted no bitcoin_rpc access');
    }

    final now = clock();
    final decision = checkCall(
      cap: cap,
      method: req.method,
      params: req.params,
      spentToday: ledger.spentWithin(now),
    );

    switch (decision) {
      case PolicyDeny(:final code, :final message):
        return HostResponse.err(code, message);
      case PolicyAllow(:final reserveSats):
        String? reservationId;
        if (reserveSats != null && reserveSats > 0) {
          try {
            reservationId = ledger.reserve(now, req.method, reserveSats);
          } on BudgetLedgerException catch (e) {
            return HostResponse.err('budget_exceeded',
                'could not reserve budget (refused): ${e.message}');
          }
        }
        final RpcResult r;
        try {
          r = executor.call(req.method, req.params);
        } catch (e) {
          if (reservationId != null) ledger.cancel(reservationId);
          return HostResponse.err('rpc_failed', 'executor error: $e');
        }
        if (!r.ok) {
          if (reservationId != null) ledger.cancel(reservationId);
          return HostResponse.err('rpc_failed', r.stderr);
        }
        // v1: settle to the reserved amount (the tx result's fee is not
        // parsed yet — a later slice refines actual-spend attribution).
        if (reservationId != null) {
          ledger.settle(reservationId, reserveSats!);
        }
        return HostResponse.ok(r.result);
    }
  }
}
```

- [ ] **Step 5: Export + run**

Add to `common/lib/common.dart`:

```dart
export 'src/services/wasm/bitcoin_rpc_executor.dart';
export 'src/services/wasm/host_call.dart';
```

Run: `cd common && dart test test/services/wasm/host_call_test.dart`
Expected: 7 PASS.

- [ ] **Step 6: Analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ..
jj commit -m "feat(common): host_call handler — the enforced node boundary

The pure-Dart body behind the single sandbox import: parse the
envelope, resolve the capability, run the policy gate, reserve budget,
execute via an injected bitcoin-cli executor, then settle or cancel.
Every refusal path (bad request, unknown capability, off-allowlist,
over-budget, rpc failure) returns a structured error and never touches
the node. The executor is an interface so the whole gate is tested
against a fake with no bitcoind.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 7: Module cache + WasmActionRunner

**Files:**

- Create: `common/lib/src/services/wasm/module_cache.dart`, `common/lib/src/services/wasm/wasm_action_runner.dart`
- Test: `common/test/services/wasm/wasm_action_runner_test.dart`
- Modify: `common/pubspec.yaml` (add `wasmtime_dart` dep), `common/lib/common.dart` (export runner)

**Interfaces:**

- Consumes: `wasmtime_dart` (Engine/Store/Module/Linker/Memory/WasiConfig/EpochTicker/FuncType/ValI32/ValI64/WasmTrap/TrapCode); `HostCallHandler` (Task 6); `SandboxSpec`, `SandboxLimits` (Task 1).
- Produces: `WasmActionRunner({required WasmtimeLibrary library, required String cacheDir})`; method `Future<({Stream<String> output, Future<int> exitCode})> run({required String wasmPath, required String export, required SandboxSpec sandbox, required HostCallHandler hostCall})`. Runner clamps `sandbox.limits` to the host maxima (`fuel ≤ 5_000_000_000`, `timeout ≤ 60`).
- `ModuleCache(WasmtimeLibrary lib, String dir)` with `Module load(Engine engine, String wasmPath)` — deserialize the cached `.cwasm` for the wasm file's sha256 if present, else compile + serialize + store.

**Host maxima constants (in wasm_action_runner.dart):** `const maxFuel = 5000000000; const maxTimeoutSeconds = 60;`

- [ ] **Step 1: Add the dependency**

In `common/pubspec.yaml` under `dependencies:` add:

```yaml
wasmtime_dart:
  path: ../wasmtime_dart
```

Run `cd common && dart pub get` (workspace resolves the path).

- [ ] **Step 2: Write the failing test**

`common/test/services/wasm/wasm_action_runner_test.dart` — uses a WAT fixture compiled through `wasmtime_dart`'s own `watToWasm`, so no Rust toolchain. The guest calls `host_call` and writes the response to stdout via WASI `fd_write`. To keep the test self-contained, the fixture exports `run` and `alloc`, imports `nixblitz.host_call` and `wasi_snapshot_preview1.fd_write`, and on `run`: writes a fixed request into memory, calls `host_call`, then `fd_write`s the low 32 bits (len) is complex in WAT — instead assert via a host-observed side effect.

Simpler, robust approach: the test provides a `HostCallHandler` backed by a `FakeExecutor` and asserts (a) the guest's request reached the handler (executor recorded the method) and (b) fuel/epoch limits trip on a spinning guest. Use two WAT fixtures:

```dart
import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

// Guest: allocs a request string is awkward in raw WAT, so the fixture
// hardcodes the request bytes in a data segment and passes their address
// to host_call. alloc returns a fixed scratch offset.
const callWat = r'''
(module
  (import "nixblitz" "host_call" (func $hc (param i32 i32) (result i64)))
  (memory (export "memory") 1)
  (data (i32.const 0)
    "{\"v\":1,\"cap\":\"bitcoin_rpc\",\"method\":\"getblockchaininfo\",\"params\":[]}")
  (func (export "alloc") (param i32) (result i32) (i32.const 4096))
  (func (export "run")
    (drop (call $hc (i32.const 0) (i32.const 64)))))
''';

const spinWat = r'''
(module
  (import "nixblitz" "host_call" (func $hc (param i32 i32) (result i64)))
  (memory (export "memory") 1)
  (func (export "alloc") (param i32) (result i32) (i32.const 0))
  (func (export "run") (loop $l br $l)))
''';

class FakeExecutor implements BitcoinRpcExecutor {
  final List<String> calls = [];
  @override
  RpcResult call(String method, List params) {
    calls.add(method);
    return RpcResult(ok: true, result: {'blocks': 1}, stderr: '');
  }
}

void main() {
  late Directory tmp;
  late WasmActionRunner runner;
  late FakeExecutor executor;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('runner_');
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

  HostCallHandler handler() => HostCallHandler(
        sandbox: sandbox,
        ledger: BudgetLedger('${tmp.path}/b.json'),
        executor: executor,
        clock: () => DateTime.utc(2026, 7, 16),
      );

  Future<String> writeWasm(String wat, String name) async {
    // Compile WAT -> wasm bytes via a throwaway engine, write to disk.
    final lib = WasmtimeLibrary.discover();
    final engine = Engine(lib);
    final bytes = watToWasm(engine, wat);
    engine.dispose();
    final path = '${tmp.path}/$name.wasm';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  test('guest host_call reaches the handler', () async {
    final path = await writeWasm(callWat, 'call');
    final res = await runner.run(
      wasmPath: path,
      export: 'run',
      sandbox: sandbox,
      hostCall: handler(),
    );
    final code = await res.exitCode;
    expect(code, 0);
    expect(executor.calls, ['getblockchaininfo']);
  });

  test('a spinning guest is stopped by the time budget', () async {
    final path = await writeWasm(spinWat, 'spin');
    final res = await runner.run(
      wasmPath: path,
      export: 'run',
      sandbox: const SandboxSpec(limits: SandboxLimits(timeoutSeconds: 1)),
      hostCall: handler(),
    );
    final out = <String>[];
    res.output.listen(out.add);
    final code = await res.exitCode;
    expect(code, isNot(0));
    expect(out.join(), contains('budget'));
  });

  test('module cache produces a .cwasm and a second run reuses it', () async {
    final path = await writeWasm(callWat, 'call2');
    await (await runner.run(
            wasmPath: path,
            export: 'run',
            sandbox: sandbox,
            hostCall: handler()))
        .exitCode;
    final caches =
        Directory('${tmp.path}/cache').listSync().whereType<File>().toList();
    expect(caches, isNotEmpty);
    // second run still succeeds
    final code = await (await runner.run(
            wasmPath: path,
            export: 'run',
            sandbox: sandbox,
            hostCall: handler()))
        .exitCode;
    expect(code, 0);
  });
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `export WASMTIME_DART_LIB=$(nix build nixpkgs#wasmtime.lib --no-link --print-out-paths)/lib/libwasmtime.so; cd common && dart test test/services/wasm/wasm_action_runner_test.dart`
Expected: FAIL — `WasmActionRunner` undefined.

- [ ] **Step 4: Implement module_cache.dart**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

/// Caches compiled modules as `<sha256-of-wasm>.cwasm` so a plugin's
/// guest is JIT-compiled once, not per action. Keyed by the wasm file's
/// content hash, so a plugin update invalidates automatically.
class ModuleCache {
  ModuleCache(this.dir);
  final String dir;

  Module load(Engine engine, String wasmPath) {
    final bytes = File(wasmPath).readAsBytesSync();
    final hash = sha256.convert(bytes).toString();
    final cachePath = '$dir/$hash.cwasm';
    final cached = File(cachePath);
    if (cached.existsSync()) {
      try {
        return Module.deserializeFile(engine, cachePath);
      } catch (_) {
        // Stale/incompatible cache (e.g. wasmtime bump) — recompile.
      }
    }
    final module = Module.fromWasm(engine, bytes);
    try {
      Directory(dir).createSync(recursive: true);
      File(cachePath).writeAsBytesSync(module.serialize(), flush: true);
    } catch (_) {
      // Cache write is best-effort; the module is still usable.
    }
    return module;
  }
}
```

If `crypto` isn't already a `common` dep, add `crypto: ^3.0.3` to `common/pubspec.yaml` and `dart pub get`. (Check first: `grep crypto common/pubspec.yaml`.)

- [ ] **Step 5: Implement wasm_action_runner.dart**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wasmtime_dart/wasmtime_dart.dart';

import '../../models/plugin/sandbox_spec.dart';
import 'host_call.dart';
import 'module_cache.dart';

const int maxFuel = 5000000000;
const int maxTimeoutSeconds = 60;

/// Runs a sandboxed WASM action: one guest instance per invocation with
/// fuel + wall-clock limits, no filesystem/network, and the single
/// `nixblitz.host_call` import wired to [HostCallHandler].
class WasmActionRunner {
  WasmActionRunner({required this.library, required this.cacheDir})
      : _cache = ModuleCache(cacheDir);

  final WasmtimeLibrary library;
  final String cacheDir;
  final ModuleCache _cache;

  Future<({Stream<String> output, Future<int> exitCode})> run({
    required String wasmPath,
    required String export,
    required SandboxSpec sandbox,
    required HostCallHandler hostCall,
  }) async {
    final controller = StreamController<String>();
    final fuel = sandbox.limits.fuel.clamp(1, maxFuel);
    final timeout = sandbox.limits.timeoutSeconds.clamp(1, maxTimeoutSeconds);

    final exitFuture = () async {
      final engine =
          Engine(library, config: const EngineConfig(consumeFuel: true, epochInterruption: true));
      final store = Store(engine);
      final ctx = store.context;
      final stdoutFile = File('$cacheDir/.stdout-${DateTime.now().microsecondsSinceEpoch}');
      EpochTicker? ticker;
      try {
        ctx.setFuel(fuel);
        ctx.setEpochDeadline(timeout * 100); // ticker fires every 10ms
        final wasi = WasiConfig(args: const ['plugin'], stdoutFile: stdoutFile.path);
        ctx.setWasi(wasi);

        final module = _cache.load(engine, wasmPath);
        final linker = Linker(engine)..defineWasi();

        // The one host import. host_call reads the request from guest
        // memory, runs the policy gate, writes the response back via the
        // guest's `alloc`, and returns (ptr<<32)|len.
        linker.defineFunc('nixblitz', 'host_call',
            FuncType(params: [ValType.i32, ValType.i32], results: [ValType.i64]),
            (caller, args) {
          final reqPtr = (args[0] as ValI32).value;
          final reqLen = (args[1] as ValI32).value;
          final mem = caller.getMemory('memory');
          final reqBytes = mem.readBytes(caller.context, reqPtr, reqLen);
          final responseJson = hostCall.handle(utf8.decode(reqBytes));
          final respBytes = utf8.encode(responseJson);
          final alloc = caller.getFunc('alloc');
          final outPtr =
              (alloc.call(caller.context, [ValI32(respBytes.length)]).single
                      as ValI32)
                  .value;
          mem.writeBytes(caller.context, outPtr, respBytes);
          final packed = (outPtr << 32) | respBytes.length;
          return [ValI64(packed)];
        });

        ticker = await EpochTicker.start(engine,
            interval: const Duration(milliseconds: 10));

        final instance = linker.instantiate(ctx, module);
        final fn = instance.getFunc(ctx, export);
        controller.add('> wasm action: $export\n');
        fn.call(ctx);

        final out = stdoutFile.existsSync() ? stdoutFile.readAsStringSync() : '';
        if (out.isNotEmpty) controller.add(out);
        return 0;
      } on WasmTrap catch (t) {
        final msg = switch (t.code) {
          TrapCode.outOfFuel => 'plugin exceeded its fuel budget',
          TrapCode.interrupt => 'plugin exceeded its time budget',
          _ => 'plugin trapped: ${t.message}',
        };
        controller.add('$msg\n');
        return 1;
      } on WasmtimeError catch (e) {
        controller.add('wasm runtime error: ${e.message}\n');
        return 1;
      } finally {
        if (ticker != null) await ticker.stop();
        try {
          store.dispose();
        } catch (_) {}
        engine.dispose();
        if (stdoutFile.existsSync()) {
          try {
            stdoutFile.deleteSync();
          } catch (_) {}
        }
        await controller.close();
      }
    }();

    return (output: controller.stream, exitCode: exitFuture);
  }
}
```

- [ ] **Step 6: Export + run**

Add to `common/lib/common.dart`: `export 'src/services/wasm/wasm_action_runner.dart';` and `export 'src/services/wasm/module_cache.dart';`

Run: `export WASMTIME_DART_LIB=$(nix build nixpkgs#wasmtime.lib --no-link --print-out-paths)/lib/libwasmtime.so; cd common && dart test test/services/wasm/wasm_action_runner_test.dart`
Expected: 3 PASS.

If the guest crashes on `alloc` semantics, the WAT fixture's `alloc` returning a fixed offset is the contract; the real Rust guest (Task 12) implements a bump allocator matching it. Do not change the runner's ABI to accommodate a fixture bug — fix the fixture.

- [ ] **Step 7: gen-locks, analyze, format, commit**

Because `common` gained deps, regenerate the Nix lock files: `just gen-locks`.

```bash
cd common && dart analyze && dart format . && cd ..
just gen-locks
jj commit -m "feat(common): WasmActionRunner — sandboxed guest execution

One guest instance per action: fuel + wall-clock limits (clamped to
host maxima), no filesystem or network, stdout captured to a temp file,
and the single nixblitz.host_call import marshaling the request/response
JSON across guest memory via the guest's alloc export. Traps map to
plain operator messages (\"exceeded its time/fuel budget\"). Compiled
modules are cached by wasm-hash so the Pi JITs each guest once.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 8: Install validation + logic-only plugin.nix relaxation

**Files:**

- Modify: `common/lib/src/services/plugin/plugin_git_ops.dart` (`requirePluginNix` → gate on logic-only), `common/lib/src/services/plugin_service.dart` (sandbox validation + pass logic-only to the nix check), `common/lib/src/models/plugin/plugin_install_preview.dart` (carry `SandboxSpec?` + `hasNixModule`)
- Test: `common/test/services/plugin_service_test.dart` (add cases; or a focused new file)

**Interfaces:**

- Consumes: `PluginManifest.isLogicOnly`, `.sandbox` (Task 3); `isSpendCapable`, `attributedSpendSats` (Task 5).
- Produces: `void validateSandbox(PluginManifest)` (throws `FormatException` on a spend method with 0/absent budget, or an unattributable spend method in the allowlist); `PluginInstallPreview.sandbox` (`SandboxSpec?`), `PluginInstallPreview.hasNixModule` (`bool`); `requireModuleOrLogicOnly(String dir, PluginManifest manifest)` replacing bare `requirePluginNix` at the install sites.

- [ ] **Step 1: Write the failing test**

Add to `common/test/services/plugin_service_test.dart` (import `package:common/common.dart`):

```dart
  group('validateSandbox', () {
    PluginManifest mf(Map<String, dynamic> sandbox) => PluginManifest.fromJson({
          'manifest': {'schema_version': 5, 'name': 'x'},
          'actions': {
            'a': {'label': 'a', 'wasm': {'module': 'a.wasm'}},
          },
          'sandbox': sandbox,
        });

    test('accepts a read-only sandbox', () {
      expect(() => validateSandbox(mf({
            'bitcoin_rpc': {'methods': ['getblockchaininfo']},
          })), returnsNormally);
    });

    test('rejects a spend method with zero budget', () {
      expect(
        () => validateSandbox(mf({
          'bitcoin_rpc': {
            'methods': ['sendtoaddress'],
            'budgets': {'spend_sats_per_day': 0},
          },
        })),
        throwsFormatException,
      );
    });

    test('rejects an unattributable spend method even with a budget', () {
      expect(
        () => validateSandbox(mf({
          'bitcoin_rpc': {
            'methods': ['sendmany'], // unattributable in v1
            'budgets': {'spend_sats_per_day': 1000},
          },
        })),
        throwsFormatException,
      );
    });

    test('accepts an attributable spend method with a budget', () {
      expect(() => validateSandbox(mf({
            'bitcoin_rpc': {
              'methods': ['sendtoaddress'],
              'budgets': {'spend_sats_per_day': 1000},
            },
          })), returnsNormally);
    });
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd common && dart test test/services/plugin_service_test.dart -n validateSandbox`
Expected: FAIL — `validateSandbox` undefined.

- [ ] **Step 3: Implement validateSandbox**

Add to `plugin_service.dart` as a top-level function (or a static on `PluginService` — match the file's style; if `_secretFieldNames` is a static method, make this a public static `PluginService.validateSandbox` and export via the class). Given the test calls it bare, make it top-level in the same library and export from `common.dart`:

```dart
/// Install-time sandbox validation. A spend-capable method is only
/// permitted if (a) the daily budget is positive AND (b) its sat cost is
/// attributable from params (v1: only sendtoaddress). Rejecting here
/// means the runtime never faces an un-cappable spend.
void validateSandbox(PluginManifest manifest) {
  final cap = manifest.sandbox?.bitcoinRpc;
  if (cap == null) return;
  for (final method in cap.methods) {
    if (!isSpendCapable(method)) continue;
    if (cap.spendSatsPerDay <= 0) {
      throw FormatException(
        'sandbox: method `$method` can move funds but the plugin\'s '
        'spend_sats_per_day is ${cap.spendSatsPerDay}. Grant a positive '
        'daily budget or remove the method.',
      );
    }
    if (attributedSpendSats(method, const [0, 0.0]) == null) {
      throw FormatException(
        'sandbox: method `$method` has a spend cost that cannot be '
        'attributed from its arguments; it is not permitted in a sandboxed '
        'plugin (v1).',
      );
    }
  }
}
```

Add `export 'src/services/plugin_service.dart' show validateSandbox;` if `common.dart` doesn't already export the service surface (check — if the service is already exported, no new export line needed; if `validateSandbox` must be visible, ensure the file is exported).

- [ ] **Step 4: Relax the plugin.nix requirement for logic-only plugins**

In `plugin_git_ops.dart`, keep `requirePluginNix` and add a sibling:

```dart
/// Requires plugin.nix UNLESS the manifest is logic-only (its only
/// surface is sandboxed wasm actions — no nix module, no privileged
/// unit, no streamer). Logic-only plugins legitimately ship no
/// plugin.nix.
void requireModuleOrLogicOnly(String dir, PluginManifest manifest) {
  if (manifest.isLogicOnly) return;
  requirePluginNix(dir);
}
```

In `plugin_service.dart`, at each of the 4 `requirePluginNix(pluginSourceDir)` call sites, replace with `requireModuleOrLogicOnly(pluginSourceDir, manifest)` — the manifest is in scope at each (it's parsed before the check). Also call `validateSandbox(manifest)` right after each parse, before the nix check. Grep to confirm the `manifest` variable name at each site.

- [ ] **Step 5: Carry sandbox + hasNixModule on the preview**

In `plugin_install_preview.dart`, add fields:

```dart
  final SandboxSpec? sandbox;
  final bool hasNixModule;
```

Add to the constructor: `this.sandbox, this.hasNixModule = true,` (import `sandbox_spec.dart`). At both `PluginInstallPreview(` construction sites in `plugin_service.dart`, add:

```dart
          sandbox: manifest.sandbox,
          hasNixModule: manifest.module != null,
```

- [ ] **Step 6: Run the tests**

Run: `cd common && dart test test/services/plugin_service_test.dart && dart test test/models/`
Expected: all PASS.

- [ ] **Step 7: Analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ..
jj commit -m "feat(common): install-time sandbox validation + logic-only plugins

A logic-only plugin (only wasm actions) may ship no plugin.nix — the
install path stops demanding it. In exchange, the sandbox block is
validated up front: a fund-moving method is refused unless it has a
positive daily budget AND an attributable per-call cost, so the runtime
never meets an un-cappable spend. The install preview now carries the
sandbox spec and whether a nix module is present, for the consent card.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 9: WasmActionRunner provider + TUI action routing

**Files:**

- Modify: `common/lib/src/providers/plugin_action_provider.dart` (add a `wasmActionRunnerProvider`), `tui/lib/src/ui/views/plugin_action_view.dart` (route wasm actions)
- Test: covered by Task 15 E2E + existing action view manual paths (no new unit test — this is wiring; a unit test would need a live wasmtime lib and is redundant with Task 7)

**Interfaces:**

- Consumes: `WasmActionRunner`, `HostCallHandler`, `BitcoinCliExecutor`, `BudgetLedger`, `WasmtimeLibrary`.
- Produces: `wasmActionRunnerProvider` (Riverpod `Provider<WasmActionRunner>`); the action view calls it for `action.isWasm`.

- [ ] **Step 1: Provider**

Add to `plugin_action_provider.dart`:

```dart
/// Sandbox runtime home + module cache under the nixblitz state dir.
final wasmActionRunnerProvider = Provider<WasmActionRunner>((ref) {
  final home = Platform.environment['HOME'] ?? '.';
  return WasmActionRunner(
    library: WasmtimeLibrary.discover(),
    cacheDir: '$home/nixblitz/state/sandbox/modules',
  );
});
```

(Import `dart:io`, `package:wasmtime_dart/wasmtime_dart.dart`, and the runner.) This provider is native-only; it is only read on the wasm-action path, so non-wasm flows never construct a `WasmtimeLibrary`.

- [ ] **Step 2: Route wasm actions in the view**

In `plugin_action_view.dart`, where it currently does `component.runner.run(component.action, inputs: _collected)` (around line 107): branch on `action.isWasm`. Build a `HostCallHandler` from the installed plugin's manifest sandbox + a `BudgetLedger` at `$HOME/nixblitz/state/sandbox/budgets/<pluginId>.json` + `BitcoinCliExecutor()` + `clock: DateTime.now`, and call the wasm runner:

```dart
if (component.action.isWasm) {
  final runner = context.read(wasmActionRunnerProvider);
  final pluginDir = component.pluginSourceDir; // dir of the installed plugin
  final handler = HostCallHandler(
    sandbox: component.manifest.sandbox ?? const SandboxSpec(),
    ledger: BudgetLedger(
        '${Platform.environment['HOME']}/nixblitz/state/sandbox/budgets/'
        '${component.manifest.id ?? component.manifest.name}.json'),
    executor: BitcoinCliExecutor(),
    clock: DateTime.now,
  );
  final run = await runner.run(
    wasmPath: '$pluginDir/${component.action.wasm!.module}',
    export: component.action.wasm!.export,
    sandbox: component.manifest.sandbox ?? const SandboxSpec(),
    hostCall: handler,
  );
  // feed run.output / run.exitCode into the same UI phase machinery the
  // command/unit path uses.
} else {
  final run = component.runner.run(component.action, inputs: _collected);
  ...
}
```

Adapt to the view's actual field names: the view needs the installed plugin's source dir and manifest. If `plugin_action_view.dart` doesn't already hold the manifest/dir, thread them in from the caller (`configure_view.dart` / wherever the action view is constructed) — grep for `PluginActionView(` to find the construction site and add `manifest` + `pluginSourceDir` params. Keep the streaming/exit-code handling identical to the existing path (the runner's return shape matches `PluginActionRunner.run` except it's a `Future` of the record — `await` it first).

- [ ] **Step 3: Analyze, format, commit**

```bash
cd common && dart analyze && dart format . && cd ../tui && dart analyze && dart format . && cd ..
just test
jj commit -m "feat(tui): route wasm actions through the sandbox runner

A wasm action builds a HostCallHandler from the installed plugin's
sandbox spec, a per-plugin budget ledger, and the real bitcoin-cli
executor, then runs the guest via WasmActionRunner — reusing the
action view's existing output/exit-code plumbing. command/unit actions
are unchanged. The runtime library is resolved lazily, so non-wasm
flows never load libwasmtime.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 10: Sandbox consent card (CLI + install view)

**Files:**

- Modify: `tui/lib/src/cli/plugin_cli.dart` (`_askConsent`), `tui/lib/src/ui/views/plugin_install_view.dart` (`_buildConsentPhase`)
- Test: manual (consent is interactive); the preview-data path is covered by Task 8.

**Interfaces:**

- Consumes: `PluginInstallPreview.sandbox`, `.hasNixModule` (Task 8).
- Produces: consent shows the sandbox card for logic-only plugins (no nix module), keeps the root-grant warning otherwise.

- [ ] **Step 1: CLI consent card**

In `plugin_cli.dart`'s `_askConsent`, after the schema/signature lines and the secret-field block, replace the unconditional root-grant `WARNING` with a branch:

```dart
  if (!p.hasNixModule && p.sandbox != null) {
    final cap = p.sandbox!.bitcoinRpc;
    stdout.writeln();
    stdout.writeln('SANDBOX: this plugin runs in a WASM sandbox. It can only:');
    if (cap != null) {
      stdout.writeln('  • call bitcoind: ${cap.methods.join(", ")}');
      stdout.writeln('  • spend at most ${cap.spendSatsPerDay} sats/day '
          '(0 = never)');
    } else {
      stdout.writeln('  • (no node access requested)');
    }
    stdout.writeln('  • time limit ${p.sandbox!.limits.timeoutSeconds}s, '
        'no network, no filesystem, no shell.');
    stdout.writeln('The cap governs what the plugin initiates through this '
        'API — it is not a');
    stdout.writeln('wallet-level or node-wide policy.');
  } else {
    // existing root-grant WARNING block, unchanged
  }
```

- [ ] **Step 2: Install-view consent card**

In `plugin_install_view.dart`'s `_buildConsentPhase`, mirror the same branch: when `!p.hasNixModule && p.sandbox != null`, emit Text lines describing the sandbox card (methods, budget, limits, honest-boundary sentence) in place of the root-grant warning Text lines. Keep the y/N prompt and the secret-field block unchanged.

- [ ] **Step 3: Analyze, format, commit**

```bash
cd tui && dart analyze && dart format . && cd ..
just analyze
jj commit -m "feat(tui): sandbox consent card for logic-only plugins

A logic-only plugin gets an honest capability card at consent — the
RPC methods it may call, its daily spend cap, its time limit, and the
plain statement that it has no network, filesystem, or shell — instead
of the root-grant warning, which would be theater for a plugin that
never runs privileged code. Plugins with a nix module keep the
root-grant warning unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 11: Flake wiring — `WASMTIME_DART_LIB` in the wrapper

**Files:**

- Modify: `flake.nix` (the `nixblitzWrapped` `writeShellScriptBin`)

**Interfaces:** none (packaging).

- [ ] **Step 1: Export the library path in the wrapper**

In `flake.nix`, the wrapper is:

```nix
nixblitzWrapped = pkgs.writeShellScriptBin "nixblitz" ''
  export PATH="${pkgs.lib.makeBinPath [
    disko.packages.${system}.default
    pkgs.git
  ]}:$PATH"
  exec ${nixblitzUnwrapped}/bin/nixblitz "$@"
'';
```

Add a `WASMTIME_DART_LIB` export using `wasmtime.lib` from the same nixpkgs the TUI is built with. `nixblitzUnwrapped` is built from `pkgsUnstable` (line 75); use the matching wasmtime:

```nix
nixblitzWrapped = pkgs.writeShellScriptBin "nixblitz" ''
  export PATH="${pkgs.lib.makeBinPath [
    disko.packages.${system}.default
    pkgs.git
  ]}:$PATH"
  export WASMTIME_DART_LIB="${pkgsUnstable.wasmtime.lib}/lib/libwasmtime.so"
  exec ${nixblitzUnwrapped}/bin/nixblitz "$@"
'';
```

(Confirm the binding-name for the unstable pkgs set at flake.nix:75 — it's `pkgsUnstable`. Use whatever that line uses.)

- [ ] **Step 2: Verify the build**

Run: `nix build .#nixblitz-unwrapped` then `nix build .#nixblitz` — both must succeed. Inspect: `cat result/bin/nixblitz | grep WASMTIME_DART_LIB` shows the store path.

- [ ] **Step 3: Commit**

```bash
jj commit -m "build(flake): bake WASMTIME_DART_LIB into the TUI wrapper

The wasmtime_dart binding resolves libwasmtime.so from
WASMTIME_DART_LIB; the wrapper now points it at wasmtime.lib from the
same nixpkgs the TUI is built with, so the sandbox runtime is available
on nodes without a dev shell. Rides the pinned nixpkgs like every other
dep (nvmd's on the Pi).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 12: Rust `node-summary` example plugin

**Files (in the SEPARATE plugins repo `examples_redesign/nixblitz_official_plugins/node-summary/`):**

- Create: `src/lib.rs`, `Cargo.toml`, `flake.nix`, `plugin.json`, `README.md`, `actions/summary.wasm` (built artifact), `.gitignore` (target/)

**Interfaces (the guest side of the ABI — must match Task 7's runner exactly):**

- Guest imports `nixblitz.host_call(i32,i32)->i64`; exports `alloc(i32)->i32` (bump allocator over a static arena) and `run()`.
- `run` builds a request `{"v":1,"cap":"bitcoin_rpc","method":M,"params":[]}`, calls `host_call`, unpacks `(ptr<<32)|len`, reads the response JSON from `[ptr,ptr+len)`, parses `{"v":1,"ok":...}` / `{"v":1,"err":...}`, and prints a summary to stdout (WASI). Repeats for the three methods.

- [ ] **Step 1: Cargo.toml**

```toml
[package]
name = "node-summary"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
serde_json = "1"

[profile.release]
opt-level = "z"
lto = true
strip = true
```

- [ ] **Step 2: src/lib.rs**

Full guest (the ABI is load-bearing — bump allocator, packed return unpacking, WASI stdout via `println!` which wasip1 maps to fd 1):

```rust
use std::io::Write;

// Bump arena the host writes responses into via `alloc`.
static mut ARENA: [u8; 65536] = [0; 65536];
static mut ARENA_OFFSET: usize = 0;

#[no_mangle]
pub extern "C" fn alloc(n: i32) -> i32 {
    unsafe {
        let off = ARENA_OFFSET;
        ARENA_OFFSET += n as usize;
        ARENA.as_ptr().add(off) as i32
    }
}

extern "C" {
    // Host import: returns (ptr << 32) | len of the response in memory.
    fn host_call(req_ptr: i32, req_len: i32) -> i64;
}

fn call(method: &str) -> Result<serde_json::Value, String> {
    let req = format!(
        "{{\"v\":1,\"cap\":\"bitcoin_rpc\",\"method\":\"{}\",\"params\":[]}}",
        method
    );
    let bytes = req.into_bytes();
    let packed = unsafe { host_call(bytes.as_ptr() as i32, bytes.len() as i32) };
    let ptr = (packed >> 32) as usize;
    let len = (packed & 0xffff_ffff) as usize;
    let resp = unsafe { std::slice::from_raw_parts(ptr as *const u8, len) };
    let v: serde_json::Value =
        serde_json::from_slice(resp).map_err(|e| format!("bad response: {e}"))?;
    if let Some(ok) = v.get("ok") {
        Ok(ok.clone())
    } else if let Some(err) = v.get("err") {
        Err(format!(
            "{}: {}",
            err["code"].as_str().unwrap_or("error"),
            err["message"].as_str().unwrap_or("")
        ))
    } else {
        Err("malformed response envelope".into())
    }
}

#[no_mangle]
pub extern "C" fn run() {
    let out = std::io::stdout();
    let mut out = out.lock();
    match summary() {
        Ok(s) => {
            let _ = writeln!(out, "{s}");
        }
        Err(e) => {
            let _ = writeln!(out, "node-summary error: {e}");
        }
    }
}

fn summary() -> Result<String, String> {
    let chain = call("getblockchaininfo")?;
    let net = call("getnetworkinfo")?;
    let mem = call("getmempoolinfo")?;
    Ok(format!(
        "Node summary\n\
         ───────────\n\
         chain:        {}\n\
         blocks:       {}\n\
         verifyprog:   {:.4}\n\
         peers:        {}\n\
         mempool txs:  {}\n\
         mempool size: {} bytes",
        chain["chain"].as_str().unwrap_or("?"),
        chain["blocks"].as_i64().unwrap_or(-1),
        chain["verificationprogress"].as_f64().unwrap_or(0.0),
        net["connections"].as_i64().unwrap_or(-1),
        mem["size"].as_i64().unwrap_or(-1),
        mem["bytes"].as_i64().unwrap_or(-1),
    ))
}
```

Note: `run`/`alloc` must not be optimized away — `crate-type = ["cdylib"]` + `#[no_mangle] pub extern "C"` keeps them exported. wasip1's `_start` isn't used (this is a reactor-style module invoked via `run`), which matches the runner calling the named export after instantiation.

- [ ] **Step 3: flake.nix (builds the .wasm)**

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      rust = pkgs.rust-bin or null;
    in {
      packages.${system}.default = pkgs.rustPlatform.buildRustPackage {
        pname = "node-summary-wasm";
        version = "0.1.0";
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;
        target = "wasm32-wasip1";
        # buildRustPackage with a wasm target: override the build/install
        # to emit the .wasm. Use a plain derivation if this proves fiddly:
        buildPhase = ''
          cargo build --release --target wasm32-wasip1
        '';
        installPhase = ''
          mkdir -p $out
          cp target/wasm32-wasip1/release/node_summary.wasm $out/summary.wasm
        '';
        doCheck = false;
      };
    };
}
```

If `buildRustPackage` fights the wasm target, fall back to a `mkDerivation` with `nativeBuildInputs = [ pkgs.cargo pkgs.rustc ]` and `RUSTFLAGS`/`--target wasm32-wasip1`, `CARGO_HOME` in `$TMPDIR`, and vendored deps via `cargoDeps`. The deliverable is `$out/summary.wasm`; the exact derivation shape is the implementer's call as long as it builds offline-ish under nix. Generate `Cargo.lock` with `cargo generate-lockfile` and commit it.

- [ ] **Step 4: Build and place the artifact**

```bash
cd examples_redesign/nixblitz_official_plugins/node-summary
nix build
cp result/summary.wasm actions/summary.wasm
```

Sanity-check the module with the binding: it must export `run`, `alloc`, `memory` and import `nixblitz.host_call`. Quick check via a throwaway Dart snippet using `Module.fromWasm` + `instance` export lookup, or `wasm-tools print actions/summary.wasm | grep -E 'export|import'`.

- [ ] **Step 5: plugin.json (schema v5, logic-only)**

```json
{
  "manifest": { "schema_version": 5, "name": "Node Summary" },
  "id": "node-summary",
  "description": "Read-only bitcoind status report, run in a WASM sandbox.",
  "actions": {
    "summary": {
      "label": "Node summary",
      "description": "Read-only bitcoind status via the sandbox",
      "confirm": false,
      "wasm": { "module": "actions/summary.wasm", "export": "run" },
      "timeout_seconds": 10
    }
  },
  "sandbox": {
    "bitcoin_rpc": {
      "methods": ["getblockchaininfo", "getnetworkinfo", "getmempoolinfo"],
      "budgets": { "spend_sats_per_day": 0 }
    },
    "limits": { "fuel": 500000000, "timeout_seconds": 10 }
  }
}
```

No `module` key ⇒ logic-only; no `plugin.nix` file in the dir.

- [ ] **Step 6: README.md**

Document: what it does; the sandbox card contents (verbatim: three read methods, 0 sats/day, 10s, no net/fs/shell); the honest boundary sentence; and the **rebuild-and-diff** procedure:

```
nix build
cmp result/summary.wasm actions/summary.wasm   # byte-identical build
```

State plainly: wasm builds are not guaranteed bit-reproducible across
toolchain versions; a mismatch means "rebuild and review the diff," not
"tampering." This is review-by-rebuild, not a reproducibility promise.

- [ ] **Step 7: Commit (in the plugins repo)**

```bash
cd examples_redesign/nixblitz_official_plugins
# .gitignore node-summary/target/
jj commit -m "feat: node-summary — first sandboxed WASM example plugin

A logic-only plugin (no plugin.nix): a Rust wasm32-wasip1 guest that
reads bitcoind via the sandbox host API and prints a status summary.
Ships source + a nix build + the committed summary.wasm; the README
documents rebuild-and-diff review. Requests three read RPCs and a zero
spend budget — the reference shape for the sandbox tier.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(The plugins repo is jj-colocated; this commit is separate from the main repo's stack. Do NOT set the main repo's bookmark here.)

### Task 13: `.wasm` freshness guard + plugin-authoring docs

**Files:**

- Create: `tests/scripts/check-wasm-plugins.sh` (or extend `check-plugin-consistency.sh`)
- Modify: `justfile` (wire the check into `test`/`ci`), `docs/plugin-authoring.md`

**Interfaces:** none (tooling + docs).

- [ ] **Step 1: Freshness guard**

The committed `node-summary/actions/summary.wasm` must match a fresh
build (mirrors the tile-manifest invariant). Add `tests/scripts/check-wasm-plugins.sh`:

```bash
#!/usr/bin/env bash
# Fails if a plugin's committed .wasm is stale vs a fresh nix build.
set -euo pipefail
plugin="examples_redesign/nixblitz_official_plugins/node-summary"
if [ ! -d "$plugin" ]; then
  echo "node-summary plugin not found; skipping wasm freshness check"
  exit 0
fi
built=$(nix build "path:$plugin" --no-link --print-out-paths)/summary.wasm
if ! cmp -s "$built" "$plugin/actions/summary.wasm"; then
  echo "STALE: $plugin/actions/summary.wasm differs from a fresh build."
  echo "Rebuild: (cd $plugin && nix build && cp result/summary.wasm actions/summary.wasm)"
  echo "Note: wasm builds are not guaranteed bit-reproducible — review the diff."
  exit 1
fi
echo "node-summary summary.wasm is in sync."
```

`chmod +x` it. Honest caveat in the script comment: a mismatch on a
different toolchain is expected; this guard is most meaningful in CI with
the pinned nixpkgs. If bit-reproducibility proves flaky in practice, the
guard can compare the wasm's exports/imports signature instead of bytes —
document that fallback in the script header, but ship byte-compare first.

- [ ] **Step 2: Wire into just**

Add a recipe (repo comment convention: detail lines, bare `#`, concise last):

```make
# Rebuilds node-summary's guest and byte-compares against the committed
# actions/summary.wasm, mirroring the tile-manifest invariant. wasm
# builds aren't guaranteed bit-reproducible; a mismatch means review the
# diff, not tampering.
#
# Fail if a plugin's committed .wasm is stale vs a fresh build
check-wasm-plugins:
  bash tests/scripts/check-wasm-plugins.sh
```

Call it from `ci` after `check-wasm-plugins` — but only if a nix-labeled
runner exists; since `ci` already runs under nix locally, add
`just check-wasm-plugins` to the `ci` recipe after `check-templates`.
(This build can be slow on a cold store; acceptable for the ci gate.)

- [ ] **Step 3: Document the wasm tier in plugin-authoring.md**

Add a "Sandboxed WASM actions (schema v5)" section: the `wasm` action
shape; the `sandbox` block and what each field means; the host ABI
(`host_call` envelope, `alloc`/`run` exports, packed return); the
logic-only trust tier (optional plugin.nix); the honest spend-cap
boundary; and a pointer to `node-summary` as the reference. Keep it
consistent with the v4 material already there (the "schema history" list
gains a v5 entry).

- [ ] **Step 4: Commit**

```bash
just check-wasm-plugins  # verify green against the committed artifact
jj commit -m "chore: wasm-plugin freshness guard + authoring docs for the sandbox tier

check-wasm-plugins rebuilds node-summary's guest and byte-compares the
committed .wasm, the same invariant we hold for tile manifests (with
the honest caveat that wasm builds aren't guaranteed reproducible).
plugin-authoring.md gains the schema-v5 sandbox section: the wasm action
shape, the host_call ABI, the logic-only tier, and the spend-cap
boundary.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 14: Regtest VM end-to-end

**Files:** none (manual validation; may add a short runbook under `docs/`).

**Prerequisites:** `just vm-boot` works; the plugins repo commit from Task 12 is pushed/reachable by the VM (or installed from a local path the VM can reach).

- [ ] **Step 1: Boot + deploy the TUI**

```bash
just iso-build && just vm-boot   # or: just vm-deploy after an install
```

Install the freshly built TUI (with the Task 11 wrapper) on the VM.

- [ ] **Step 2: Install node-summary**

From the VM's TUI plugin flow, install `node-summary` from the plugins
repo URL (or a local path). **Verify the consent screen shows the sandbox
card** (three read methods, 0 sats/day, 10s, no net/fs/shell) — NOT the
root-grant warning. Confirm install succeeds with no plugin.nix.

- [ ] **Step 3: Run the action against regtest bitcoind**

Trigger the "Node summary" action. **Assert:** the output pane shows real
regtest data — chain `regtest`, the current block height, peer count,
mempool counts. No trap, exit 0.

- [ ] **Step 4: Negative test — refused method**

Temporarily edit the installed guest's request (or install a doctored
variant) to call a method NOT in the allowlist (e.g. `stop`). **Assert:**
the guest reports `method_not_allowed` and `bitcoin-cli stop` never runs
(the node stays up). Restore the real guest.

- [ ] **Step 5: Record the result**

Write a short outcome note (what passed, screenshots/paste of the output
pane) into the plan's ledger or a `docs/` runbook. This task has no
commit unless a runbook doc is added; if so, commit it with
`docs: node-summary regtest E2E runbook + results`.

---

### Task 15: Pi end-to-end (un-parks the branch)

**Files:** none (manual, on-hardware).

**Prerequisites:** Pi reachable (`ssh admin@<pi>`); the branch's TUI builds
for aarch64; the plugins repo reachable from the Pi.

- [ ] **Step 1: Build/deploy the aarch64 TUI to the Pi**

Build the wrapped TUI for aarch64 (or `nix run` the branch on the Pi).
Confirm `WASMTIME_DART_LIB` resolves on the Pi (`echo` it from the wrapper
env) and that `libwasmtime.so` substitutes from cache (no local kernel/JIT
rebuild).

- [ ] **Step 2: Install + run node-summary on the live node**

Same flow as Task 14 steps 2-3, against the Pi's real bitcoind. **Assert:**
the sandbox card shows at consent; the action prints real mainnet/live
data; page size is 16384 (`getconf PAGESIZE`) and the guest still runs —
this is the on-hardware wasmtime validation.

- [ ] **Step 3: Confirm limits on hardware**

Verify a time-limit trip: a spinning guest fixture (or a deliberately slow
call) hits the 10s deadline and reports "exceeded its time budget" rather
than hanging the TUI.

- [ ] **Step 4: Un-park the branch**

With the Pi E2E green, record it: update the branch status. This is the
gate the whole track waited on — the `wasm-plugins` bookmark is now
mergeable pending your review. Do NOT merge to main autonomously; report
the green result and hand the merge decision to the user.

---

## Self-review notes

- **Spec coverage:** §1 manifest v5 → Tasks 1-3; §2 runner + cache →
  Task 7; §3 ABI/policy/ledger → Tasks 4-6; §1c/1d validation + logic-only
  → Task 8; §4 consent → Task 10; §5 example → Task 12; §6 nix → Task 11;
  §7 testing → Tasks 4-8 (unit) + 14-15 (E2E); freshness guard (§5) →
  Task 13; docs → Task 13. Provider/routing wiring (implied by §2/§4) →
  Task 9.
- **Deferred items** from the spec (host-func registry lifecycle, Func
  signature caching) are NOT tasks here — correctly, they're later-slice
  prerequisites.
- **ABI consistency:** the packed return `(ptr<<32)|len`, the `alloc`/`run`
  exports, and the `nixblitz.host_call(i32,i32)->i64` signature are stated
  identically in Task 7 (host), Task 7's WAT fixture, and Task 12 (Rust
  guest). The envelope `{"v":1,...}` and error codes match Tasks 5/6/12.
