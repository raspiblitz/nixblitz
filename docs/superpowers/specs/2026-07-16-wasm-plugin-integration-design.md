# WASM Plugin Integration (Slice 1) — Design

**Date:** 2026-07-16
**Status:** Approved
**Depends on:** `wasmtime_dart` package
(`docs/superpowers/specs/2026-07-13-wasmtime-dart-binding-design.md`),
complete on the `wasm-plugins` branch.

## Why

Today a plugin's imperative surface (`command:` actions, streamers) is
arbitrary bash running as the admin user — full home directory, full
network, everything. The `wasmtime_dart` binding gives us a sandbox with
none of that ambient authority. This slice integrates it end to end:

- a new **`wasm:` action** type executed inside the sandbox,
- a **host API** (`bitcoin_rpc`) that is the guest's *only* channel to
  the node — which makes it the single enforcement point for
  capability policy, including quantitative budgets ("this plugin may
  spend at most N sats per day"),
- the first **logic-only plugin tier**: a plugin with no `plugin.nix`
  is no longer a root grant, and its consent screen shows its exact
  sandbox capabilities instead of the root warning,
- one real example plugin (`node-summary`, Rust → `wasm32-wasip1`)
  proven end to end on the regtest VM and on the Pi.

## Goals

1. Operator can install a logic-only plugin and run its `wasm:` action;
   output appears in the existing action-output pane.
2. The guest can only do what its manifest `sandbox` block declares —
   enforced, not advisory: RPC method allowlist, spend budgets, fuel
   and wall-clock limits.
3. The example plugin produces a real node summary from regtest and
   from the Pi's live node.
4. The pattern (envelope ABI, policy gate, ledger) extends to
   lightning and to streamers in later slices without schema breaks.

## Non-goals (this slice)

- Lightning host API (design accommodates it; not built).
- `wasm:` streamers / dashboard tiles.
- Any change to normal (nix-module) plugins' consent or trust story —
  install of a nix module remains a root grant, stated as such.
- Network or filesystem capabilities for guests beyond what WASI
  preopens already support (the example needs neither).
- Signature/verification schemes for `.wasm` artifacts (review story
  is rebuild-and-diff, documented honestly).

## 1. Manifest schema v5

`schema_version: 5` (minimum stays 2). Changes:

### 1.1 `wasm:` action variant

Alongside `command:` and `unit:`:

```json
{
  "id": "node-summary",
  "label": "Show node summary",
  "wasm": { "module": "actions/summary.wasm", "export": "run" }
}
```

- `module` — path relative to the plugin directory; must exist at
  install validation and stay inside the plugin dir (no `..`).
- `export` — the exported function invoked after WASI `_initialize`
  handling; signature `() -> ()` (all input/output flows through the
  host API and stdout). Default `"run"`.
- `inputs` (the existing ephemeral operator-input mechanism) is NOT
  supported on wasm actions in this slice; validation rejects the
  combination rather than silently ignoring it.

### 1.2 `sandbox` block (top level)

The plugin's complete requested capability set:

```json
"sandbox": {
  "bitcoin_rpc": {
    "methods": ["getblockchaininfo", "getnetworkinfo", "getmempoolinfo"],
    "budgets": { "spend_sats_per_day": 0 }
  },
  "limits": { "fuel": 500000000, "timeout_seconds": 10 }
}
```

Validation rules (install-time, hard failures):

- `methods`: non-empty list of RPC method names. Deny-by-default at
  runtime: anything not listed is refused.
- Method classification lives host-side (in nixblitz, not the
  manifest): a static table classifies each *supported* method as
  `read` or `spend`. A method not in the table at all is refused at
  install ("unknown method") — the allowlist can only name methods the
  host knows how to police. v