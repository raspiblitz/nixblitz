# WASM Plugin Dashboard Tile + Forbidden-Action Demo — Design

**Date:** 2026-07-18
**Status:** Approved
**Branch:** `wasm-plugins` (continues the WASM plugin runtime slice).
**Depends on:** the WASM plugin runtime (slice 1) — the `WasmActionRunner`,
`HostCallHandler`, sandbox policy, and the `node-summary` example plugin,
all on this branch and proven end to end on regtest.

## Why

node-summary currently proves the sandbox works for an operator-triggered
action. Two additions make the demo complete and show the sandbox in the
two places that matter most:

1. **A dashboard tile** fed by the sandboxed plugin — so the sandbox
   drives live, always-visible node data, not just an on-demand action.
2. **A forbidden-function action** — the interactive twin of the negative
   unit test: the guest tries a method its manifest never declared, and
   the operator watches the host boundary refuse it.

Both stay fully sandboxed: the tile is polled through the _same_
`WasmActionRunner` + allowlist as the actions, not through the existing
unsandboxed bash tile mechanism. node-summary remains logic-only.

## Scope

**In:** a `wasm` variant for the plugin `dashboard` tile spec; a wasm
branch in `PluginDashboardService`'s poller; a small shared helper that
builds a `HostCallHandler` and runs a plugin's wasm module to stdout
(used by both the action view and the tile poller); two new guest exports
(`tile`, `check_sandbox`); node-summary's manifest/tile updates; tests.

**Out:** long-running wasm _streamers_ (the persistent-instance model —
still deferred; polling is sufficient here and matches how the dashboard
already works); any change to the bash tile mechanism (kept as-is for
existing plugins); wiring node-summary into the one-click catalog (it
stays a URL-installed test plugin).

## Guest-language note

The guest stays Rust → `wasm32-wasip1`, one module (`summary.wasm`) with
three exports now: `run` (existing summary action), `tile` (tile-state
JSON), `check_sandbox` (forbidden-call demo). The `alloc` export and the
`nixblitz.host_call` import are unchanged.

---

## 1. Sandboxed dashboard tile

### 1a. `PluginTileSpec` gains a `wasm` variant

`common/lib/src/models/plugin/plugin_tile.dart`'s `PluginTileSpec`
currently requires a bash `command`. Make the data source two-way:
exactly one of `command` (existing bash poll) or
`wasm: { module, export }` (sandboxed poll). Add a `WasmTileSource`
(`module`, `export` default `"tile"`) and a `wasm` field; `fromJson`
rejects declaring both, requires at least one, and keeps all existing
`command`-based parsing unchanged. `poll_interval_seconds` / `timeout`
apply to both.

node-summary's `dashboard` block:

```json
"dashboard": {
  "title": "Node Summary",
  "accent_color": "#5bc0be",
  "wasm": { "module": "actions/summary.wasm", "export": "tile" },
  "poll_interval_seconds": 15
}
```

### 1b. A shared "run plugin wasm → stdout" helper

The action view (`plugin_action_view.dart`) already builds a
`HostCallHandler` (from the plugin's `sandbox` spec + a per-plugin
`BudgetLedger` + `BitcoinCliExecutor` + `DateTime.now`) and runs a wasm
module via `WasmActionRunner`, collecting stdout. The tile poller needs
the same. Extract it once into
`common/lib/src/services/wasm/plugin_wasm_run.dart`:

```
Future<({int exitCode, String stdout})> runPluginWasm({
  required WasmActionRunner runner,
  required PluginManifest manifest,
  required String pluginDir,
  required String export,
  required String stateDir,   // $HOME/nixblitz/state/sandbox
});
```

It builds the `HostCallHandler` (sandbox from `manifest.sandbox`, ledger
at `<stateDir>/budgets/<id>.json`, `BitcoinCliExecutor`, `DateTime.now`),
resolves `<pluginDir>/<action-or-tile module>`, runs the named export,
drains the output stream, and returns exit code + captured stdout. The
action view is refactored to call it (behaviour-preserving); the tile
poller calls it too.

### 1c. `PluginDashboardService` polls wasm tiles

`PluginDashboardService` currently holds only a `PluginActionRunner`
(bash) and its `_PluginPoller._poll()` calls
`runner.runOneShot(command: spec.command, ...)`. Changes:

- The service also reads `wasmActionRunnerProvider` and
  `installedPluginsProvider` (to resolve a wasm tile's manifest +
  `pluginDir`).
- `_PluginPoller` branches in `_poll()`: when `spec.wasm != null`, call
  `runPluginWasm(...)` (§1b) and feed the captured stdout to the **same**
  `_interpret()` that parses bash tile JSON; otherwise the existing bash
  path, unchanged. Trap/limit failures surface as the existing
  `PluginTileSnapshot.failure(...)` (e.g. "poll error: …" / "timed out").
- A plugin gets a poller if it declares a `dashboard` block, wasm or
  bash — the existing eligibility logic is unchanged otherwise.

### 1d. Guest `tile` export

The `dashboard`-block poll is the **flat key-value tile** path:
`PluginTileSnapshot.fromCommandOutput` turns each key of the poll's JSON
object into a tile row (label = key, value = stringified value), with a
few reserved keys — `_status_label`, `_status_color`, `_footer`,
`_footer_color` — controlling the status chip and footer. It is NOT the
`tile_manifests` + `$data` layout-DSL path (that one is streamer-fed and
out of scope here).

So `node-summary/src/lib.rs` gains a `tile` export that calls the three
allowlisted read methods via `host_call` and prints ONE flat JSON object
whose keys are the row labels:

```json
{
  "Network": "regtest",
  "Blocks": "5",
  "Sync": "100.0%",
  "Peers": "0",
  "Mempool": "0 txs",
  "_footer": "sandboxed read-only",
  "_footer_color": "ok"
}
```

That renders directly as a tile titled "Node Summary" (from the
`dashboard` block) with those rows and a green footer — no layout file
needed. Because the poll runs through the same sandbox, `tile` can only
reach the three allowlisted methods; the manifest allowlist is unchanged.

### 1e. No separate layout file / tile_manifests

The flat key-value poll tile needs no `tile-node-summary.json` and no
`tile_manifests` entry — the `dashboard` block plus the guest's flat JSON
are the whole tile. node-summary stays logic-only: a `dashboard` block
and a second wasm action do not change `isLogicOnly` (module still null,
streamers still empty, all actions still wasm).

---

## 2. Forbidden-function action

### 2a. Guest `check_sandbox` export

`node-summary/src/lib.rs` gains a `check_sandbox` export that calls a
method deliberately absent from the allowlist — `getpeerinfo` — via
`host_call`, receives the `{"err":{"code":"method_not_allowed",...}}`
envelope, and prints a clear message:

```
Sandbox self-check
──────────────────
Attempting a NON-allowlisted call: getpeerinfo
→ refused: method_not_allowed (getpeerinfo is not in this plugin's allowlist)

The sandbox blocked a method this plugin never declared.
```

Exit 0 — the action succeeds at _demonstrating_ the refusal (the guest
handled the error path gracefully). Same `summary.wasm` module, different
export.

### 2b. Manifest action

node-summary's `actions` gains:

```json
"check_sandbox": {
  "label": "Sandbox self-check",
  "description": "Attempt a non-allowlisted call; show it refused",
  "confirm": false,
  "wasm": { "module": "actions/summary.wasm", "export": "check_sandbox" }
}
```

The allowlist stays exactly the three read methods — `getpeerinfo` is
deliberately absent, which is the whole point.

---

## 3. Testing

**Unit (`common/test`):**

- `PluginTileSpec.fromJson`: parses the `wasm` variant; rejects declaring
  both `command` and `wasm`; requires at least one; existing bash parsing
  still passes.
- `runPluginWasm` helper: builds the handler and returns stdout/exit for
  a WAT/`.wasm` fixture guest (no node) — including a trap → non-zero
  exit path.
- `PluginDashboardService` wasm-tile poll: the wasm branch feeds
  `_interpret()` and yields a populated `PluginTileSnapshot` for a
  fixture that emits valid tile JSON; a fixture that traps yields a
  `failure` snapshot.

**Guest ABI (end-to-end, `.wasm` through the real runner + fake
executor):** extend the existing check to the two new exports —
`tile` emits the expected JSON object given canned RPC results;
`check_sandbox` prints the refusal when the fake gates `getpeerinfo`
(fake returns the `method_not_allowed` envelope for an off-allowlist
method, matching the real handler).

**Freshness guard:** the rebuilt `summary.wasm` (now three exports) stays
byte-matched to the committed artifact (`just check-wasm-plugins`).

**E2E (manual, regtest):** the Node Summary tile appears on the dashboard
with live regtest data and refreshes on its interval; running "Sandbox
self-check" prints the refusal in the action output pane.

## Error handling summary

- Tile poll trap/timeout/limit → `PluginTileSnapshot.failure(...)` (same
  as a bash tile that errors), so the dashboard shows a red/pending tile
  rather than crashing.
- `check_sandbox` refusal is the _expected_ path — the guest reads the
  `err` envelope and reports it; exit 0.
- A malformed tile JSON from the guest → `_interpret()`'s existing
  parse-failure handling applies unchanged.

## Deferred / non-goals

- Long-running wasm streamers (persistent instance, reactor tick) — still
  a later slice; polling covers this demo.
- Catalog wiring for node-summary — stays URL-installed.
- Per-plugin single-flight on the budget ledger (already tracked as an
  integration-hardening prerequisite) — the tile poll is stateless and
  spends nothing, so it does not change that picture.
