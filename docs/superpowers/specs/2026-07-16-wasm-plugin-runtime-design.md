# WASM Plugin Runtime (slice 1) — Design

**Date:** 2026-07-16
**Status:** Approved
**Branch:** `wasm-plugins` (continues the branch that holds `wasmtime_dart`;
not merged to main until the Pi validation in this spec passes).
**Depends on:** the `wasmtime_dart` binding package (already on this branch).

## Why

NixBlitz plugins today run as `command:` bash (admin user, full ambient
authority) or `unit:` systemd oneshots (root). We want a **lower-trust
tier**: plugin logic that runs inside a WASM sandbox with a declared,
enforced capability set, so the _amount of damage a plugin can do is
bounded by its manifest_, not by the admin user's authority.

This slice proves the tier end to end with one real example: a
`node-summary` action that reads bitcoind state through a sandboxed host
API and prints a summary. It also establishes the enforcement point for
future spend limits — a plugin that could move funds is capped (e.g. "at
most N sats/day") at the one boundary it cannot bypass.

The sandbox is the entire attack surface for a logic-only plugin: no
network, no ambient filesystem, no exec. The single host-function import
is therefore the only channel to the node, which makes it the one true
policy-enforcement point. A cap enforced there cannot be evaded from
inside the guest.

## Scope

**In:** manifest schema v5 (`wasm:` actions, `sandbox` block, optional
`plugin.nix` for logic-only plugins); `WasmActionRunner` in `common`; the
host ABI + policy gate (allowlist + spend budgets); the budget ledger;
the consent-screen change; the Rust `node-summary` example plugin; Nix
wiring of `libwasmtime.so`; regtest + Pi E2E.

**Out (later slices):** streamers/tiles via wasm; lightning host API;
non-bitcoind capabilities; component model / WIT; multi-import host APIs;
`Func` signature caching and host-func registry lifecycle (named
prerequisites carried from the binding review — see Deferred).

## Guest-language decision

The example is **Rust → `wasm32-wasip1`** (mature WASI toolchain, small
binaries, first-class in nixpkgs, `serde_json` for payloads). This sets
the reference pattern for plugin authors. Other `wasm32-wasip1` languages
(TinyGo, Zig, C) work against the same ABI; Dart guests are not viable
today (dart2wasm targets a JS embedder, not WASI).

---

## 1. Manifest schema v5

`currentPluginManifestVersion` → 5 (min supported stays 2). Additions:

### 1a. `wasm:` action variant

`plugin_action.dart` currently enforces "exactly one of `command`/`unit`".
v5 makes it "exactly one of `command`/`unit`/`wasm`". The `wasm` object:

```json
"actions": {
  "summary": {
    "label": "Node summary",
    "description": "Read-only bitcoind status report",
    "confirm": false,
    "wasm": { "module": "actions/summary.wasm", "export": "run" },
    "timeout_seconds": 10
  }
}
```

- `module`: repo-relative path to the committed `.wasm` (validated: within
  the plugin dir, no symlink escape, exists).
- `export`: guest function to invoke (no params, no results; the guest
  reads via host calls and writes to stdout). Default `"run"`.
- `wasm` actions are never `isPrivileged` (no sudo/systemd path).

### 1b. `sandbox` block (new top-level manifest field)

The plugin's **entire** requested capability set — deny-by-default, shown
verbatim at consent:

```json
"sandbox": {
  "bitcoin_rpc": {
    "methods": ["getblockchaininfo", "getnetworkinfo", "getmempoolinfo"],
    "budgets": { "spend_sats_per_day": 0 }
  },
  "limits": { "fuel": 500000000, "timeout_seconds": 10 }
}
```

- `bitcoin_rpc.methods`: allowlist. A method not listed is refused at
  runtime. Absent `bitcoin_rpc` block ⇒ no RPC access at all.
- `bitcoin_rpc.budgets.spend_sats_per_day`: integer sats. `0` = the
  plugin may call no spend-capable method (and none may appear in
  `methods`). Present-and-positive = the daily cap the policy gate
  enforces.
- `limits.fuel` / `limits.timeout_seconds`: guest requests; the runner
  clamps each to a host-side maximum (`fuel ≤ 5_000_000_000`,
  `timeout ≤ 60`) so a plugin cannot request unbounded execution.
- Modeled as `SandboxSpec` (+ `BitcoinRpcCapability`, `SandboxLimits`,
  `SandboxBudgets`) in `common/lib/src/models/plugin/sandbox_spec.dart`.

### 1c. Logic-only plugins (optional `plugin.nix`)

`requirePluginNix` (in `plugin_git_ops.dart`, called from 4 sites in
`plugin_service.dart`) currently hard-fails without `plugin.nix`. v5:
`plugin.nix` is optional **iff** the manifest declares no `module` and no
`unit:`/`streamers` (nothing that needs system config) — i.e. a pure
logic plugin whose only surface is wasm actions. Introduce
`bool isLogicOnly(manifest)` and gate the requirement on it. Any plugin
that declares a nix module, a privileged unit, or a streamer keeps the
`plugin.nix`-required rule unchanged.

### 1d. Install-time validation

At install/preview (`plugin_service.dart`): reject a manifest where a
spend-capable method appears in an allowlist whose `spend_sats_per_day`
is 0 or absent — fail _at install_, with a clear message, not at runtime.
The spend-capable classification is a static host-side set (§3d).

---

## 2. `WasmActionRunner` (in `common`)

New `common/lib/src/services/wasm/wasm_action_runner.dart`. `common`
gains the `wasmtime_dart` workspace dep (native-only, like its existing
Process/File services). Same public result shape as `PluginActionRunner`:
`({Stream<String> output, Future<int> exitCode}) run(...)`.

Per invocation:

1. Resolve + hash the `.wasm`; get a compiled `Module` from the module
   cache (§2a).
2. Fresh `Engine` (fuel + epoch enabled), `Store`, `Linker`.
3. `context.setFuel(clampedFuel)`, `setEpochDeadline`, start an
   `EpochTicker`; `WasiConfig` with **no** preopens, args `[pluginId]`,
   stdout→temp file. (No network, no fs — the sandbox baseline.)
4. `linker.defineFunc('nixblitz', 'host_call', …, hostCall)` — the one
   import (§3).
5. Instantiate; call the `export`. Stream the stdout temp file into the
   output pane as it fills; surface the final buffer.
6. Map outcomes: normal → exit 0; `WasmTrap(outOfFuel|interrupt)` →
   "plugin exceeded its {fuel|time} budget"; other `WasmTrap`/
   `WasmtimeError` → the message. Always `await ticker.stop()` before
   disposing the engine (binding contract).

### 2a. Module cache

`Module.serialize()` output cached at
`~/nixblitz/state/sandbox/modules/<sha256-of-wasm>.cwasm`; load via
`Module.deserializeFile` when present. Keyed by wasm-file hash so a plugin
update invalidates automatically. Rationale: JIT-compiling ~300 KB of
Rust on every action would dominate runtime on the Pi.

---

## 3. Host ABI and policy gate

### 3a. The single import

`nixblitz.host_call(req_ptr: i32, req_len: i32) -> i64`

- Guest exports `alloc(i32) -> i32` (bump/arena allocator; the host calls
  it to place the response in guest memory).
- Guest writes a UTF-8 JSON request at `req_ptr`; host reads it via
  `Caller.getMemory`.
- Host serializes the JSON response, calls the guest's `alloc` to get a
  buffer, `writeBytes` into it, and returns `(ptr << 32) | len` packed in
  the i64. (Two i32s packed in the i64 result — no multi-value needed.)

### 3b. Envelope (versioned)

Request: `{"v":1,"cap":"bitcoin_rpc","method":"getblockchaininfo","params":[]}`
Response ok: `{"v":1,"ok":<json result>}`
Response err: `{"v":1,"err":{"code":"method_not_allowed","message":"…"}}`

`v` lets the ABI evolve without breaking committed `.wasm` artifacts. Error
codes: `bad_request`, `unknown_capability`, `method_not_allowed`,
`budget_exceeded`, `rpc_failed`.

### 3c. Gate order (in the Dart host function)

1. Parse envelope; unknown `cap` → `unknown_capability`.
2. `method` in the manifest allowlist? else `method_not_allowed`.
3. Spend-capable method (§3d)? → compute intended spend from params,
   check + **reserve** against the ledger (§3e); over cap →
   `budget_exceeded`.
4. Execute: `Process.runSync('bitcoin-cli', [method, ...params])` with the
   same PATH/auth path existing streamers use (nix-bitcoin wraps the
   cookie auth; the guest never sees credentials). Non-zero → `rpc_failed`
   with stderr.
5. **Settle** the reservation from the actual result (real amount + fee);
   return `ok`.

A Dart exception inside the host function becomes a `WasmTrap` (binding
behavior) — fail-closed, the action reports an error rather than
proceeding.

### 3d. Spend-capable classification

A static host-side set of bitcoind methods that move funds
(`sendtoaddress`, `sendmany`, `send`, `fundrawtransaction`,
`walletcreatefundedpsbt`, …). The v1 example uses none of them — its
allowlist is three read methods and its budget is 0 — but the
classification and the reserve/settle path are built and unit-tested now,
because retrofitting enforcement later is exactly the mistake to avoid.
Methods whose sat-cost cannot be attributed from params/result are **not
allowlistable** in v1 (validation rejects them), so the ledger never has
to guess.

### 3e. Budget ledger

Per-plugin JSON at `~/nixblitz/state/sandbox/budgets/<plugin-id>.json`:
a rolling 24h window of `{ts, method, sats}` entries.

- **Reserve-then-settle, fail-closed:** before executing a spend, write a
  reservation for the intended amount; after success, adjust to the actual
  amount; if the process dies between reserve and settle, the reservation
  stands (counts as spent). Better to over-count on a crash than let a
  double-spend slip.
- Day window = trailing 24h from now (entries older than 24h are pruned on
  read). `spent_today = sum(sats in window)`; refuse if
  `spent_today + intended > spend_sats_per_day`.
- `BudgetLedger` service, unit-tested against a fake clock (time injected;
  no `DateTime.now()` in the pure logic).

### 3f. Honest boundary (documented, not overclaimed)

The cap governs **what the plugin initiates through the host API**. Sats
debited per call are derived from the RPC arguments/results; methods whose
cost can't be attributed are not allowlistable. This does **not** claim to
constrain what the operator's node does outside plugin calls, nor to be a
wallet-level policy — it is a plugin-capability cap. The consent screen
and README state this in plain language (no security theater).

---

## 4. Consent UI

`plugin_install_preview.dart` already carries preview data; add the
sandbox summary. In `plugin_install_view.dart` / `plugin_cli.dart`:

- **Logic-only plugin** (no nix module): show the **sandbox card** instead
  of the root-grant warning — "This plugin runs sandboxed. It can: call
  bitcoind [methods]; spend at most N sats/day (0 = never). It cannot
  access the network, filesystem, or run commands." This is the trust
  payoff of the tier.
- **Plugin with a nix module**: unchanged root-grant consent. A nix module
  is root; showing a sandbox card there would be theater. (If such a
  plugin _also_ has wasm actions, the root-grant warning governs.)

---

## 5. Example plugin: `node-summary`

In `examples_redesign/nixblitz_official_plugins/node-summary/`:

- `src/lib.rs` (~150 lines): `run` export calls `host_call` for
  `getblockchaininfo`, `getnetworkinfo`, `getmempoolinfo`; formats a
  summary (chain, height, verification progress, peer count, mempool tx
  count + size) to stdout. A tiny bump `alloc` export. `serde_json` for
  parsing.
- `Cargo.toml`, `flake.nix` (nixpkgs `rustc` + `wasm32-wasip1` target)
  producing the `.wasm`.
- `actions/summary.wasm` — the committed build artifact.
- `plugin.json` — schema v5, **no** `module`, one `wasm` action, the
  `sandbox` block from §1b.
- `README.md` — what it does, the sandbox card contents, and the
  **rebuild-and-diff** procedure (`nix build` → compare against the
  committed `.wasm`). Honest caveat: wasm builds are not guaranteed
  bit-reproducible; the procedure is review-by-rebuild, not a reproducibility
  promise.
- Consistency guard: `check-plugin-consistency.sh` (or a sibling) gains a
  check that `actions/summary.wasm` matches a fresh build, mirroring the
  tile-manifest invariant — flags a stale committed artifact.

---

## 6. Nix wiring

The TUI binary must find `libwasmtime.so` at runtime via the binding's env
contract (`WASMTIME_DART_LIB`). The flake's TUI wrapper sets it to the
store path of `wasmtime.lib` from the **same** nixpkgs input used for the
build (follows-rules as usual). On the Pi this rides the nvmd-pinned
nixpkgs like every other dependency. The dev shell already exports it.

---

## 7. Testing

**Unit (`common/test`):**

- Manifest v5: `wasm` action parse; three-way exclusivity; `sandbox`
  parse; `isLogicOnly`; install-validation rejections (spend method with 0
  budget; unattributable spend method; wasm module path escape).
- Policy gate against a **fake RPC executor** + fake clock: allowlist
  pass/deny; budget reserve/settle/refuse; 24h rollover; fail-closed on
  simulated mid-spend crash.
- `BudgetLedger` pure logic.
- `WasmActionRunner` trap→message mapping (fuel/epoch/other), using a
  small WAT/`.wasm` fixture that calls `host_call` — no external node.

**E2E:**

1. **Regtest VM** (`just vm-boot`): install `node-summary` from the
   plugins repo; run the Node-summary action; assert real regtest bitcoind
   data appears in the output pane. Negative test: a doctored guest that
   requests a non-allowlisted method gets `method_not_allowed` and the
   action reports the refusal.
2. **Pi**: same install-and-run on the live node. This run **doubles as
   the on-hardware wasmtime validation** that un-parks the `wasm-plugins`
   bookmark — the binding's Pi test was the spike; this is the real TUI
   binary exercising the sandbox on the 16 K-page kernel.

## Error handling summary

- Guest trap (fuel/epoch/panic) → action fails with a budget/plugin-error
  message; no partial "success".
- Host-call policy refusal → structured `err` envelope to the guest, which
  decides how to report; the RPC is never executed.
- `bitcoin-cli` failure → `rpc_failed` with stderr; no crash.
- Ledger write failure → treated as refusal (fail-closed): if the reserve
  can't be persisted, the spend is denied.

## Deferred (named prerequisites for later slices)

- Host-func registry lifecycle in `wasmtime_dart` (entries never freed +
  lookup outside the trampoline try) — matters once linkers churn per
  call at scale; revisit if the per-action runner shows it.
- `Func.call` signature caching if host calls become hot.
- Lightning host API; streamer/tile wasm; multi-capability sandboxes.
