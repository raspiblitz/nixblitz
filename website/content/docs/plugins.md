---
title: Plugins - NixBlitz
---

# Plugin authoring

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. The plugin system in
> particular is pre-1.0; ABI and manifest schema may shift.

How to build a NixBlitz plugin: directory layout, manifest
reference, the load-bearing patterns that catch every first-time
author, and worked examples cribbed from the tailscale + lnbits
plugins shipped under
[`nixblitz_official_plugins`](https://github.com/raspiblitz/nixblitz_official_plugins).

This doc is the practical "how do I build one" companion to
[`docs/decisions/plugins.md`](https://github.com/raspiblitz/nixblitz/src/branch/main/docs/decisions/plugins.md), which
captures the architectural rationale (D1-D19). Read this first if
you just want to ship a plugin.

## Two kinds of plugin

Pick the tier before you start — it decides almost everything else. A
**NixOS-module plugin** integrates a service into the node: it ships a
`plugin.nix` that evaluates as a full NixOS module, so installing it is
a root grant. A **sandboxed WASM plugin** ships only logic: a
`wasm32-wasip1` guest that reaches the node through one narrow,
allowlisted door, so what it can do is bounded by its manifest rather
than by your trust in the author.

|                       | NixOS-module plugin                                                                                          | Sandboxed WASM plugin                                                                |
| --------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| **Ships**             | `plugin.nix` + `plugin.json`                                                                                 | `plugin.json` + `actions/*.wasm`                                                     |
| **Can do**            | anything a NixOS module can — enable services, wire into bitcoind/lnd/cln, systemd units, activation scripts | call an allowlisted set of bitcoind RPCs, compute, print to the operator             |
| **Trust at install**  | a root grant; the only real defense is reading the source                                                    | bounded by the `sandbox` allowlist + spend cap, enforced host-side                   |
| **Runs as**           | a peer NixOS module at rebuild time (root)                                                                   | a wasmtime guest — fuel- and time-limited, no filesystem / network / subprocess      |
| **Takes effect**      | after Apply (`nixos-rebuild`)                                                                                | on demand, no rebuild                                                                |
| **Written in**        | Nix (+ shell scripts)                                                                                        | any language targeting `wasm32-wasip1` (Rust is the reference)                       |
| **Reach for it when** | integrating a service (Tailscale, LNbits, RTL)                                                               | read-only / compute logic you'd rather not trust with root (a status tile, a report) |
| **Example**           | tailscale, lnbits                                                                                            | node-summary                                                                         |

Everything from [What you're shipping](#what-youre-shipping) down is
common to both tiers unless noted. The WASM-specific shapes — the
`wasm` action, the `sandbox` block, the host ABI, the tile source, and
the logic-only tier — are collected under
[Sandboxed WASM actions (schema v5)](#sandboxed-wasm-actions-schema-v5);
the trust-model rationale is D14/D19 in the
[design log](https://github.com/raspiblitz/nixblitz/src/branch/main/docs/decisions/plugins.md).

## What you're shipping

A plugin is a directory tree with three (sometimes four) files:

```
my-plugin/
├── plugin.nix       # NixOS module — what the system runs
├── plugin.json      # Manifest — user-facing surface: fields, actions, tile
├── README.md        # Operator-facing docs (recommended)
└── LICENSE          # (recommended)
```

(A **logic-only WASM plugin** omits `plugin.nix` entirely — its
whole tree is `plugin.json`, the compiled `actions/*.wasm`, and
source. See [the logic-only trust tier](#the-logic-only-trust-tier).)

Plus, on the operator's installed system, after `nixblitz plugin
add`:

```
~/nixblitz/plugins/my-plugin/
├── plugin.nix                # ← clone of the above
├── plugin.json               # ← clone of the above
├── .nixblitz-installed.json  # ← marker the TUI writes: pinned rev,
│                             #    branch, auto_update, disabled, …
├── README.md
└── LICENSE
```

The operator's _values_ for your config fields do **not** live in
the plugin dir: they're seeded into the node's main
`~/nixblitz/config.json` under `app_configs.<id>` at install time
and edited there via the Configure view. The marker file carries
install metadata (pin, branch, signature fingerprint, disabled).

Hosting: a plugin lives in its own git repo (the simplest case)
or as a subdir of a multi-plugin repo. The `nixblitz plugin add`
command supports both:

```
nixblitz plugin add forgejo:codeberg.org/you/my-plugin
nixblitz plugin add forgejo:codeberg.org/you/all-plugins/tailscale
nixblitz plugin add github:fusion44/some-plugin
```

The repo is shallow-cloned and the plugin's **whole tree** is
copied to the operator's tree (minus `.git`; symlinks are
rejected). Helper modules your `plugin.nix` imports, `streamers/`,
tile manifests — all of it rides along, so don't rely on files
being filtered out.

## The two-stage `plugin.nix` ABI

This is the single thing every plugin author gets wrong on the
first try. The signature is:

```nix
{ pluginCfg ? {} }: { config, lib, pkgs, ... }: {
  # ...your plugin's module body...
}
```

Two functions, applied in sequence:

1. **Outer** — receives the plugin's own `config.json` via
   `pluginCfg`. Consume it as a normal Nix attribute set, e.g.
   `pluginCfg.auth_key or ""`. This stage runs once when the
   flake imports the plugin.
2. **Inner** — a regular NixOS module. Receives `config`, `lib`,
   `pkgs` like any other module. Has access to the closure of
   the outer stage (so it can read `pluginCfg`).

### Why the awkward shape?

NixOS's module system routes every named module-function arg
through `_module.args.<name>`, which is a single global
namespace shared across every module. If two plugins both
declared `{ pluginCfg, config, lib, ... }` as their (single)
module function, the second import would crash with:

```
_module.args.pluginCfg' is defined multiple times
```

The two-stage shape sidesteps this by passing `pluginCfg` to the
_outer_ function as a closure argument. The inner module function
never sees `pluginCfg` as a named arg, so no `_module.args`
collision.

Caveat: `pluginCfg` is read by NixBlitz's flake at evaluation
time, inlined into the store path. Today the values land in the
store cleartext, where any process that can read `/nix/store` can
recover them. **Treat any field passed via `pluginCfg` as
publicly-readable on the node** — fine for switches and option
strings, not fine for long-lived secrets. There's no near-term
path to fix this short of moving secret material out of `pluginCfg`
entirely (e.g. via `sops-nix` or systemd `LoadCredential`); see
`docs/decisions/plugins.md` D14 for the trust-model framing.

## Manifest reference

### `manifest` header (required)

```json
{
  "manifest": {
    "schema_version": 5,
    "min_tui_version": 1,
    "name": "Tailscale",
    "description": "Enable Tailscale on this NixBlitz node…"
  }
}
```

| Field             | Required | Meaning                                                                                                                                                        |
| ----------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `schema_version`  | yes      | Manifest schema your plugin targets. **v5 is current**; the TUI refuses anything below v2 (v1's `run_as_root` action path is gone).                            |
| `min_tui_version` | yes      | Lowest TUI version that can render this plugin safely.                                                                                                         |
| `name`            | yes      | Human-readable display name shown in Configure → plugins. Keep it short and properly capitalized (`"Tailscale"`, `"LNBits"`) — _not_ an identifier-style slug. |
| `description`     | no       | Long-form description shown at install time.                                                                                                                   |

Schema history: **v2** replaced `run_as_root: true` actions with
systemd `unit:` dispatch; **v3** added `tile_manifests`; **v4**
added the `branches` block; **v5** added `wasm` actions, the
top-level `sandbox` block, and the logic-only trust tier (optional
`plugin.nix`) — see
["Sandboxed WASM actions (schema v5)"](#sandboxed-wasm-actions-schema-v5)
below. Additive fields are ignored by older TUIs; a manifest with
`min_tui_version` above what the TUI understands refuses to install
with a clear error.

### Top-level fields

Sibling keys of the `manifest` header. Everything except `id` is
optional; the official plugins are the living reference for the
full shapes.

| Field            | Meaning                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| `id`             | Stable identifier (`"tailscale"`). Directory name under `plugins/`, key in `app_configs`. Defaults to `name`. |
| `version`        | Plugin semver (`"0.3.1"`). Powers version-aware update tracking; omit to fall back to SHA tracking.           |
| `url`            | Self-declared canonical install URL; `requires` entries in other plugins match against it verbatim.           |
| `branches`       | (v4) Publisher-declared branch set: operator label → git ref, with an optional default for install.           |
| `requires`       | Dependencies: built-in app ids or other plugins by URL. Checked at install + runtime gating.                  |
| `module`         | Path to the NixOS module inside the checkout when it isn't `plugin.nix`.                                      |
| `tile_manifests` | (v3) DSL tile-manifest paths the dashboard registers while the plugin is enabled.                             |
| `streamers`      | Subprocess streamers launched at TUI startup, emitting dashboard tile events.                                 |
| `app_version`    | Command the TUI runs on demand to read the managed app's real version.                                        |
| `config_schema`  | User-editable fields — see below.                                                                             |
| `actions`        | Operator-triggerable verbs — see below.                                                                       |
| `permissions`    | Declarative access summary — see below.                                                                       |
| `dashboard`      | Polled dashboard tile — see below.                                                                            |
| `teardown`       | Id of a no-input action to run on the live system when the plugin is disabled/removed, before the rebuild.    |

### `config_schema` block (optional)

User-editable fields. `fields` is a **list** of typed entries; the
TUI auto-renders the right editor for each and seeds the defaults
into the node's main `config.json` under `app_configs.<id>` at
install time.

```json
"config_schema": {
  "id": "tailscale",
  "label": "Tailscale",
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled",
      "default": false },
    { "name": "login_server", "type": "string",
      "label": "Login server URL (headscale, etc.)", "default": "" },
    { "name": "exit_node", "type": "bool",
      "label": "Advertise this node as an exit node", "default": false }
  ]
}
```

Available `type`s (see `app_config_field.dart` for exact keys):

- `bool` — toggle.
- `int` (`integer`) — number input; supports `min` / `max`.
- `string` (`str`) — single-line text.
- `secret` — masked input. **Stored cleartext** in the git-tracked
  main `config.json` and world-readable in `/nix/store` once your
  `plugin.nix` consumes it — the masking is UI hygiene only. The
  install consent prompt warns the operator when a manifest
  declares one. Prefer ephemeral action `inputs` (below) for
  credentials, like the tailscale/netbird plugins do.
- `enum` — pick one of `choices: ["a", "b"]`.
- `string_list` — homogeneous list of strings.

`label` is the displayed prompt; `default` provides the value
seeded into `app_configs.<id>` at install.

In `plugin.nix`, read each field via `pluginCfg.<name> or
<fallback>` — keep the fallbacks in sync with the manifest
defaults so a not-yet-seeded config resolves to the same shape:

```nix
loginServer = pluginCfg.login_server or "";
exitNode = pluginCfg.exit_node or false;
```

### `actions` block (optional)

User-triggerable verbs. Three flavors, discriminated by which key
is set. `command`/`unit` are covered here; the third, `wasm`, runs
inside the sandboxed WASM runtime and is significant enough to get
its own section below —
["Sandboxed WASM actions (schema v5)"](#sandboxed-wasm-actions-schema-v5).

```json
"actions": {
  "tail_logs": {
    "label": "Tail logs",
    "description": "Last 200 lines from journalctl -u myservice.",
    "command": "myservice-tail-logs",
    "confirm": false,
    "timeout_seconds": 30
  },
  "reset_db": {
    "label": "Reset database",
    "description": "Wipes the on-disk DB. Loses wallet data.",
    "unit": "myservice-reset-db.service",
    "confirm": true,
    "timeout_seconds": 60
  }
}
```

| Field             | Default | Meaning                                                                                                     |
| ----------------- | ------- | ----------------------------------------------------------------------------------------------------------- |
| `label`           | —       | Menu entry text.                                                                                            |
| `description`     | `""`    | Shown in the y/N confirmation overlay.                                                                      |
| `command`         | —       | Shell command, runs as admin via `bash -c`. _Mutually exclusive with `unit`._                               |
| `unit`            | —       | Type=oneshot systemd service name. Dispatched as root via SudoSession. _Mutually exclusive with `command`._ |
| `confirm`         | `true`  | Show y/N before launching.                                                                                  |
| `timeout_seconds` | `300`   | Watchdog SIGTERM at this limit; SIGKILL after grace.                                                        |

Exactly one of `command` / `unit` / `wasm` per action. The
discrimination matters:

- **`command:`** runs as the admin user. No sudo. Use for
  read-only operations or anything that doesn't need root
  (`tail`, `cat`, `journalctl --user`, `myservice-cli status`).
- **`unit:`** dispatches a Type=oneshot systemd service via
  `sudo systemctl start --wait <unit>`. Used for anything that
  needs root. The unit must:
  1. Exist (your `plugin.nix` declares it via
     `systemd.services.<name>`).
  2. Appear in the manifest's
     `permissions.privileged_units: [...]` allow-list.

Without the allow-list cross-check, a manifest could trigger
arbitrary system units; with it, the operator sees exactly which
units a plugin claims root for at install-time consent.

An action may also declare `inputs` — values the operator is
prompted for when triggering it, delivered to the unit as
environment variables (`NIXBLITZ_INPUT_<NAME>`) via a root-owned,
mode-0600 env file under `/run/nixblitz/` that the TUI deletes
after the run. `"type": "secret"` masks the prompt. This is the
right home for credentials (Tailscale pre-auth keys, NetBird setup
keys): unlike a `config_schema` `secret` field, the value is
**never persisted** — not in config.json, not in the store.

```json
"inputs": [
  { "name": "authkey", "label": "Pre-auth key", "type": "secret" }
]
```

### `dashboard` block (optional)

A polled tile rendered alongside the core dashboard tiles.

```json
"dashboard": {
  "title": "Tailscale",
  "accent_color": "#2596be",
  "command": "tailscale-tile-state",
  "poll_interval_seconds": 30,
  "timeout_seconds": 5
}
```

| Field                   | Default   | Meaning                                                                                                                                         |
| ----------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `title`                 | —         | Tile heading.                                                                                                                                   |
| `accent_color`          | `#888899` | Hex `#rrggbb` for the title + top rule.                                                                                                         |
| `command`               | —         | Polled shell command; runs as admin user. _Mutually exclusive with `wasm`._                                                                     |
| `wasm`                  | —         | `{ "module": …, "export": "tile" }` — poll a sandboxed wasm export instead of a shell command (schema v5). _Mutually exclusive with `command`._ |
| `poll_interval_seconds` | `30`      | How often to poll. Floor: 5s.                                                                                                                   |
| `timeout_seconds`       | `5`       | SIGTERM (command) / trap (wasm) at this limit; tile shows "timed out".                                                                          |

A tile declares exactly one source — `command` or `wasm`.

Tile commands always run as the admin user — no `run_as_root`,
no sudo. Tile polls fire on a 30s timer; surfacing a sudo modal
on a background poll would be a UX disaster. If your tile needs
privileged data, expose it through a group-readable file or a
setuid wrapper, never through sudo.

#### WASM tile source (schema v5)

A logic-only WASM plugin has no shell command to poll, so its tile
names a sandboxed wasm export as the data source instead:

```json
"dashboard": {
  "title": "Node Summary",
  "accent_color": "#5bc0be",
  "wasm": { "module": "actions/summary.wasm", "export": "tile" },
  "poll_interval_seconds": 15
}
```

| Field    | Default  | Meaning                                                            |
| -------- | -------- | ------------------------------------------------------------------ |
| `module` | —        | Plugin-dir-relative path to the compiled `.wasm` guest (required). |
| `export` | `"tile"` | Exported function the poller calls (no args/return).               |

The export runs through the **same** `WasmActionRunner` + `sandbox`
allowlist as the plugin's wasm actions — one fresh, fuel-metered,
wall-clock-limited instance per poll, reaching only the RPC methods
`sandbox.bitcoin_rpc.methods` grants. It buys no extra authority: a
tile can read exactly what an action could, nothing more. The
tile's `timeout_seconds` further tightens — never loosens — the
sandbox's own wall-clock limit.

The export writes the same [tile-state JSON](#tile-state-output-protocol)
a `command` tile does (one flat object to stdout, reserved keys and
all), so the protocol section below applies unchanged. This is how a
logic-only plugin drives a live tile without ever leaving the
sandbox: `node-summary`'s `tile` export runs its three allowlisted
reads and prints
`{"Network":"regtest","Blocks":"5","Sync":"100.0%",…,"_footer":"sandboxed read-only","_footer_color":"ok"}`.

#### Tile-state output protocol

The polled command writes JSON to stdout. Shape: a flat object
where reserved keys (`_status_label`, `_status_color`, `_footer`,
`_footer_color`) drive the badge / footer chrome, and every other
key/value pair becomes a `(label, value)` row in declared order
(JSON object order is preserved by the TUI's parser).

```json
{
  "_status_label": "online",
  "_status_color": "ok",
  "tailnet": "headscale.f44.fyi",
  "self_ip": "100.64.0.1"
}
```

| Reserved key    | Effect                                               |
| --------------- | ---------------------------------------------------- |
| `_status_label` | Short text rendered next to the title.               |
| `_status_color` | `"ok"` (green) / `"warn"` (amber) / `"error"` (red). |
| `_footer`       | Text rendered under the last row.                    |
| `_footer_color` | Same scheme as `_status_color`.                      |

Failure modes (handled by the runner, you don't need to):

- Non-zero exit → tile renders with footer `"command failed (exit N)"` in red.
- Timeout → footer `"timed out"` in red.
- Unparseable stdout → footer `"invalid JSON output"` in red.
- First poll hasn't run yet → tile renders title with `loading…`.

Author-side error states are explicit:

```json
{
  "_status_label": "daemon down",
  "_status_color": "error",
  "_footer": "tailscaled.service is not responding",
  "_footer_color": "error"
}
```

— exit 0 still, just with `_status_color: "error"`. Distinguishes
"plugin reports error" (operator action: read the footer) from
"tile-state command itself failed" (operator action: check the
log; something's broken in the plugin).

### `permissions` block (optional)

Declarative for now (informational; no runtime enforcement).
Surfaced at `plugin add` time as the consent-prompt summary.
Phase 6 adds enforcement.

```json
"permissions": {
  "bitcoin": ["rpc:read"],
  "lightning": ["wallet:read", "wallet:write"],
  "filesystem": {
    "read": ["/mnt/data"],
    "write": []
  },
  "network": ["outbound"],
  "privileged_units": ["myservice-reset-db.service"]
}
```

`privileged_units` is the **only** field cross-validated at parse
time today: every `unit:` action must reference a unit listed
here, otherwise the manifest is rejected.

The other fields are forward-looking (Phase 6 will enforce
filesystem / network / RPC scoping). Declare them honestly anyway
— the consent prompt depends on them.

## Sandboxed WASM actions (schema v5)

v5 adds a third action flavor, `wasm`, alongside `command`/`unit`.
A wasm action runs inside an actual sandbox: a fresh wasmtime guest
instance per invocation, fuel-metered and wall-clock-limited, no
filesystem, no network, and exactly one host import
(`nixblitz.host_call`) gating a capability allowlist the manifest
declares up front. It can never touch systemd, sudo, or the host
filesystem — there's no escape hatch by construction, only the
`host_call` door, and that door only opens onto what `sandbox`
grants.

[`node-summary`](https://github.com/raspiblitz/nixblitz_official_plugins/src/branch/main/node-summary)
is the reference: a read-only bitcoind status report compiled from
Rust to `wasm32-wasip1`. Read it end to end before writing your
own — this section explains the shapes it uses.

### The `wasm` action shape

```json
"actions": {
  "summary": {
    "label": "Node summary",
    "description": "Read-only bitcoind status via the sandbox",
    "confirm": false,
    "wasm": { "module": "actions/summary.wasm", "export": "run" },
    "timeout_seconds": 10
  }
}
```

| Field    | Default | Meaning                                                                                 |
| -------- | ------- | --------------------------------------------------------------------------------------- |
| `module` | —       | Plugin-dir-relative path to the compiled `.wasm` guest (required).                      |
| `export` | `"run"` | Exported function the runner calls, no args/return — the guest writes output to stdout. |

The usual action fields (`label`, `description`, `confirm`,
`timeout_seconds`) apply unchanged. `wasm` actions are never
privileged, so `confirm: false` is typical for read-only ones —
there's no root grant to gate.

### The `sandbox` block

A top-level manifest field (sibling of `actions`), the plugin's
**entire** requested authority. Deny-by-default: absent means the
guest gets no `host_call` capability grants at all, and any request
it makes is refused.

```json
"sandbox": {
  "bitcoin_rpc": {
    "methods": ["getblockchaininfo", "getnetworkinfo", "getmempoolinfo"],
    "budgets": { "spend_sats_per_day": 0 }
  },
  "limits": { "fuel": 500000000, "timeout_seconds": 10 }
}
```

| Field                                    | Default     | Meaning                                                                                                                                     |
| ---------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `bitcoin_rpc.methods`                    | (none)      | Allowlist of bitcoind RPC method names the guest may call via `host_call`. Anything not listed is refused with `method_not_allowed`.        |
| `bitcoin_rpc.budgets.spend_sats_per_day` | `0`         | Daily cap, in sats, on spend-capable methods this plugin may move. `0` means the plugin may call no spend-capable method at all.            |
| `limits.fuel`                            | `500000000` | wasmtime fuel budget for one action invocation — the guest traps with "exceeded its fuel budget" once exhausted. Host clamps to a max.      |
| `limits.timeout_seconds`                 | `10`        | Wall-clock deadline (epoch-interruption ticker) for one invocation — traps with "exceeded its time budget" past this. Host clamps to a max. |

Only a fixed set of methods are **spend-capable**
(`sendtoaddress`, `sendmany`, `send`, `sendrawtransaction`,
`fundrawtransaction`, `walletcreatefundedpsbt`); everything else is
free for budget purposes. Install-time validation rejects a
manifest that lists a spend-capable method with `spend_sats_per_day
<= 0`, and — in this slice — rejects any spend-capable method other
than `sendtoaddress`, because that's the only one whose sat cost can
be attributed straight from its call params (`params[1]` in BTC).
Methods whose cost can't be attributed from params alone aren't
allowlistable yet; a future slice may add more as their param shapes
get attribution support. Read-only methods (`getblockchaininfo`,
etc.) need no budget and never touch the ledger.

`limits.fuel`/`limits.timeout_seconds` are the guest's own request;
the host always clamps them to a hard maximum before applying —
declaring a huge number in your manifest does not buy you an
unbounded sandbox.

### The host ABI

The guest and host speak a tiny, versioned protocol: a JSON request
envelope in, a JSON response envelope out, both marshaled through
wasm linear memory.

**Host import** — the guest's module must declare exactly this
import (Rust shown, the pattern generalizes to any language that
compiles to `wasm32-wasip1`):

```rust
#[link(wasm_import_module = "nixblitz")]
extern "C" {
    // Returns (ptr << 32) | len of the response, packed into one i64.
    fn host_call(req_ptr: i32, req_len: i32) -> i64;
}
```

**Guest export** — the guest must export an `alloc` function the
host calls to get a scratch pointer for writing the response bytes
into guest memory before `host_call` returns:

```rust
#[no_mangle]
pub extern "C" fn alloc(n: i32) -> i32 {
    // return a pointer to >= n free bytes in guest memory
}
```

`node-summary` backs this with a static bump arena (see its
`src/lib.rs`) — safe because the host instantiates a **fresh**
module per action invocation, so the arena starts zeroed every time
and never needs resetting between calls.

**Request envelope** (guest → host, JSON, versioned):

```json
{ "v": 1, "cap": "bitcoin_rpc", "method": "getblockchaininfo", "params": [] }
```

| Field    | Meaning                                                              |
| -------- | -------------------------------------------------------------------- |
| `v`      | Envelope version. `1` today.                                         |
| `cap`    | Capability namespace. Only `"bitcoin_rpc"` exists today.             |
| `method` | The RPC method name — checked against `sandbox.bitcoin_rpc.methods`. |
| `params` | JSON array of positional RPC params (may be empty).                  |

**Response envelope** (host → guest, JSON, versioned) — exactly one
of `ok`/`err`:

```json
{ "v": 1, "ok": { "chain": "main", "blocks": 901234, "...": "..." } }
{ "v": 1, "err": { "code": "method_not_allowed", "message": "method `sendtoaddress` is not in this plugin's allowlist" } }
```

Error `code`s the guest should expect and can match on:
`bad_request` (malformed envelope), `unknown_capability` (`cap`
not `bitcoin_rpc`, or the plugin was granted none), `method_not_allowed`
(not in the allowlist, or an unattributable spend-capable method),
`budget_exceeded` (would exceed today's spend cap), `rpc_failed`
(bitcoind itself errored).

**Call sequence** — one `host_call` per RPC round trip:

1. Guest serializes the request JSON into its own memory, calls
   `host_call(ptr, len)`.
2. Host reads the request bytes out of guest memory, runs the
   policy gate (allowlist check, then — for spend-capable methods
   only — budget check + ledger reservation), executes the RPC,
   settles or cancels the reservation, serializes the response.
3. Host calls the guest's `alloc(n)` to get a write target, writes
   the response bytes into guest memory at that pointer, and
   returns `(ptr << 32) | len` packed into the `i64` result.
4. Guest unpacks `ptr`/`len`, reads its own memory back out,
   parses the JSON, and either returns `ok` or surfaces the `err`.

The guest's exported action function (`run` by default) takes no
arguments and returns nothing; it communicates its result to the
operator by writing to WASI stdout, which the runner captures and
displays. `node-summary`'s `run()` does three `host_call`s
(`getblockchaininfo`, `getnetworkinfo`, `getmempoolinfo`) and prints
a formatted summary.

One module can export several entry points that share the one
`sandbox`. `node-summary` adds two more alongside `run`: a `tile`
export (the same three reads, formatted as
[tile-state JSON](#wasm-tile-source-schema-v5) for its dashboard
tile — see the `dashboard` block above) and a `check_sandbox` export
that deliberately calls a non-allowlisted method (`getpeerinfo`) so
the operator can watch the host refuse it with `method_not_allowed`.
`check_sandbox` is the interactive twin of the allowlist: it exits 0
having _demonstrated_ the refusal, the visible proof that the
sandbox denies what the manifest never declared. Each export is
reached by a `wasm` action or the `dashboard` block naming it.

### The logic-only trust tier

A plugin whose **entire** surface is sandboxed wasm actions — no
NixOS module, no streamers, and every declared action is a `wasm`
one — may omit `plugin.nix` entirely. This is the point of the
sandbox: if the plugin can't touch the system outside the
`host_call` capability grant, there's nothing for a NixOS module to
declare or for the operator to review at the systemd-unit level.
`node-summary` is exactly this shape; its whole tree is
`plugin.json`, `actions/summary.wasm`, and source.

The moment a plugin adds a `command:`/`unit:` action, a streamer, or
a NixOS module of its own, it drops out of the logic-only tier and
needs `plugin.nix` like any other plugin — those surfaces run
unsandboxed and still need the module + consent-time review that
`plugin.nix` provides.

### The spend-cap boundary — what it actually governs

`sandbox.bitcoin_rpc.budgets.spend_sats_per_day` is a hard cap on
what **this plugin can initiate through the `bitcoin_rpc`
capability**, tracked against a per-plugin ledger the host
maintains. Be precise about what it does _not_ claim to be:

- It is **not** a wallet-wide or node-wide spend limit. Other
  plugins, the operator's own bitcoind-cli usage, or any other
  channel to the node are entirely outside this ledger.
- It is **not** enforced by bitcoind itself — it's a host-side gate
  in front of the RPC call, evaluated before the call is made. A
  compromised or buggy host process is the only thing that could
  bypass it; a compromised wasm guest cannot, since it never gets
  a raw RPC credential, only the `host_call` door.
- "Per day" is a **trailing 24-hour window**, not a reset at
  midnight in the operator's calendar — a spend right before the
  24h mark still counts against the cap an hour later. Read
  `BudgetLedger` in
  `common/lib/src/services/wasm/budget_ledger.dart` if you need the
  exact boundary semantics for a spend-sensitive plugin.

Declare `spend_sats_per_day` honestly and as low as your plugin's
actual use case needs — it's shown verbatim at install-consent time,
and it's the only thing standing between "this plugin can move my
funds" and "this plugin is read-only."

### Building the guest

The guest is any language that targets `wasm32-wasip1` and can
declare the one `nixblitz.host_call` import plus the `alloc` export.
`node-summary` is Rust; its
[`flake.nix`](https://github.com/raspiblitz/nixblitz_official_plugins/src/branch/main/node-summary/flake.nix)
is the reference build recipe, and worth reading before you set up
your own — nixpkgs' `pkgsCross.wasi32` cargo wrapper hardcodes a
`--config target.wasm32-wasip1.linker=<clang-wrapper>` that doesn't
understand rustc's `-flavor wasm` linker invocation, so the flake
bypasses `cargoBuildHook` and calls `cargo build` directly with
`CARGO_TARGET_WASM32_WASIP1_LINKER` pointed at raw `wasm-ld` and
`-C link-arg=--allow-undefined`, so the lone `host_call` import
resolves as a wasm import rather than a link error. The compiled
`.wasm` is committed to the plugin repo; `just check-wasm-plugins`
byte-compares it against a fresh build so a stale artifact can't
drift from its source.

On the host side the runtime is a **pinned** wasmtime C-API
(`nix/wasmtime.nix`, currently 46.0.1 — deliberately independent of
nixpkgs, since the `wasmtime_dart` FFI bindings are transcribed from
one wasmtime major's headers); the compiled TUI bakes the library
path in as a compile-time define so self-update / systemd launches
find it without an env var. Plugin authors don't touch any of this —
it's the machinery your `.wasm` runs inside.

## Companion scripts pattern

Most plugins ship one or more small shell scripts the manifest
references by name:

```nix
# inside plugin.nix
let
  myStateScript = pkgs.writeShellScriptBin "myservice-tile-state" ''
    set -eu
    state=$(${pkgs.systemd}/bin/systemctl is-active myservice 2>/dev/null \
      || echo "inactive")
    case "$state" in
      active) color=ok ;;
      activating) color=warn ;;
      *) color=error ;;
    esac
    ${pkgs.jq}/bin/jq -n \
      --arg state "$state" \
      --arg color "$color" \
      '{ _status_label: $state, _status_color: $color }'
  '';
in {
  environment.systemPackages = [ myStateScript ];
}
```

`pkgs.writeShellScriptBin` produces a derivation with one
executable at `result/bin/<name>`. `environment.systemPackages =
[ ... ]` puts it on the system PATH at
`/run/current-system/sw/bin/`. The manifest references it by bare
name (`"command": "myservice-tile-state"`); the TUI's plugin
runner injects PATH preambles (`/run/current-system/sw/bin` and
`/run/wrappers/bin`) so the lookup just works.

Why scripts vs. inlining shell into the manifest:

- **Reproducibility**: Nix-built scripts pin the exact version of
  `jq`, `systemctl`, etc. used. Inline manifest commands inherit
  whatever's on the operator's PATH.
- **Reviewability**: a script in `plugin.nix` is reviewed at
  `plugin add` time as part of the diff. An inline manifest
  command is just a string; harder to spot security issues.
- **Idiomatic Nix**: `writeShellScriptBin` is the standard
  pattern for plugin-shipped commands.

## Reading core service config from `plugin.nix`

Plugins frequently need to wire into the node's bitcoind / lnd /
cln config — read the macaroon path, talk to bitcoind RPC, share
a group, etc. The plugin's inner module receives the full
`config` argument and can read anything declared by other modules:

```nix
# inside plugin.nix's inner function
{ config, lib, pkgs, ... }: let
  lndCertPath = config.services.lnd.certPath;
  lndDataDir  = config.services.lnd.networkDir;
in {
  # ...
}
```

`config.services.X.*` is keyed off the option _as the upstream
module declares it_ — usually `services.<name>` for nix-bitcoin
modules. Look at
[nix-bitcoin's modules](https://github.com/fort-nix/nix-bitcoin/tree/master/modules)
for the canonical names.

### The credential-staging pattern (RTL / lnbits)

Several core service files (LND's admin macaroon, e.g.) live with
mode `0600` owned by the service user. Group membership doesn't
help — the file is mode 0600, period. The standard NixOS dance:

```nix
systemd.services.myservice = {
  serviceConfig.ExecStartPre = [
    # The `+` prefix runs ExecStartPre as root, regardless of
    # User=. We use it to copy macaroon → readable location with
    # the right ownership, then the unit body runs as `myservice`.
    "+${pkgs.writeShellScript "stage-creds" ''
      ${pkgs.coreutils}/bin/install --compare \
        -m 640 -o myservice -g myservice -D \
        ${config.services.lnd.networkDir}/admin.macaroon \
        /var/lib/myservice/creds/admin.macaroon
    ''}"
  ];
};
```

`install --compare` is idempotent: no-op if source and dest are
already byte-identical, so it runs cheaply on every start.

This pattern is borrowed verbatim from
[nix-bitcoin's `modules/rtl.nix`](https://github.com/fort-nix/nix-bitcoin/blob/master/modules/rtl.nix).
The lnbits dogfood plugin
([`examples_redesign/nixblitz_official_plugins/lnbits/plugin.nix`](https://github.com/raspiblitz/nixblitz_official_plugins/src/branch/main/lnbits/plugin.nix))
shows the full integration including waiting for the backend
service.

Why not `LoadCredential`? It works but kernel-version-sensitive:
older kernels emit `Protocol error (status=243/CREDENTIALS)` when
the credential bind-mount fails. RTL-style staging sidesteps this
entirely.

## Update flow: what propagates how

There are two kinds of plugin update:

| Change                                                           | Propagated by                                                            | When applied                        |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------- |
| Manifest edit (new field, bumped tile poll interval, new action) | `nixblitz plugin refresh <id>` or implicit during `Update entire system` | Immediately after refresh           |
| `plugin.nix` change (new systemd unit, env var, hardening tweak) | Same — the new file lands on disk during refresh                         | Next `nixos-rebuild switch` (Apply) |

Manifest changes affect how the TUI renders the plugin (config
form, action menu, tile). They take effect as soon as the new
manifest lands on disk — no rebuild needed.

`plugin.nix` changes affect the deployed system. They land on
disk during refresh but don't activate until the operator hits
Apply. The TUI's pending-changes banner surfaces the diff between
old and new `plugin.nix` so the operator reviews before deploying.

This split matters for plugin authors: **shipping a manifest-only
change is cheap** (operator runs `plugin refresh`, change visible
immediately). **Shipping a `plugin.nix` change requires the
operator to Apply** (rebuild + service restart). Plan accordingly
when bumping versions.

## Common pitfalls

- **The two-stage ABI.** Already covered. Forget to wrap the
  outer function and you'll get module-arg collisions the first
  time anyone installs your plugin alongside another.
- **Forgetting `environment.systemPackages`.** Your manifest
  references `mything-foo` but the binary isn't in
  `/run/current-system/sw/bin/`. The action / tile fails with
  "command not found." Always add the script's wrapper to
  `environment.systemPackages`.
- **`pluginCfg` is JSON, not Nix.** It's a parsed JSON object, so
  values come through as `bool`, `string`, `int`, lists. There's
  no Nix interpolation in `pluginCfg` values; treat them as
  inert data.
- **`auth_key` (or any `secret`) ends up in the store.** Phase 1
  inlines them into the build. If the operator commits
  `~/nixblitz/` to a public mirror, secrets leak. Document this
  in your README; recommend `pin: true` on plugins handling
  secrets to limit unintended refreshes.
- **App stores configuration in its own state.** Some upstream
  apps (LNBits is the canonical case) read env vars on first
  start, persist to a SQLite DB, and ignore the env on subsequent
  boots. A plugin config change won't take effect until the
  operator wipes the DB. Either expose an `app_force_env`-style
  config flag (if upstream provides one), or document the
  reset-DB action as the supported migration path. See plugins.md
  D17.
- **Tile-state command timeouts.** The polled command runs every
  N seconds with a hard timeout. If it depends on a network call
  (RPC, HTTPS check), set a generous `timeout_seconds` and a
  shorter explicit timeout inside the script (e.g.
  `curl --max-time 3`). A tile that hangs locks up the poller.
- **`assertions` in `plugin.nix`** fire at rebuild eval time.
  Use them for "this plugin requires
  `features.apps.lnd.enable`" — clearer error than a confusing
  service failure later.
- **`builtins.getFlake` doesn't follow.** When you load an
  upstream flake via `getFlake "github:foo/bar/<rev>"` (the
  pattern the LNBits plugin uses), the upstream brings its own
  pinned `nixpkgs` — your `nixpkgs.overlays = [...]`
  declarations at NixOS-module level **don't reach** the
  upstream's pre-built package outputs. They were captured at
  upstream-flake-eval time. If the upstream needs a 16K-page
  jemalloc-sys override (Pi 5 quirk) or any other overlay
  surgery, you'll need to fork upstream and patch its flake to
  apply the overlay at its own eval time, OR rebuild the
  package from source via your local `pkgs`. There's no
  follows mechanism for `getFlake` calls — that's a flake-input
  feature only. CLAUDE.md's "Flake input rules" section
  covers the static-input case; getFlake is the loose end.

## Publishing

### `nixblitz_official_plugins`

The
[`nixblitz_official_plugins`](https://github.com/raspiblitz/nixblitz_official_plugins)
repo is for plugins the NixBlitz team takes responsibility for.
Open a PR there if your plugin:

- Wraps a service with broad community use (bitcoin sidecar tools,
  Lightning utilities, monitoring exporters).
- Has been stable across at least one TUI release.
- Has a maintainer willing to keep it current.

For everything else (single-operator hacks, work-in-progress,
bespoke integrations), ship from your own repo. The
`plugin add forgejo:.../<repo>` and
`plugin add github:user/<repo>` paths work the same.

### Versioning + branches

Plugins follow git branch / tag conventions:

- **`main` is the rolling head.** `nixblitz plugin add` defaults
  to `--branch main` and pulls the tip.
- **Release branches** (`v1.x`, `v2.x`) for plugins that want
  stability guarantees; operators add with
  `--branch v2.x` to track that line.
- **Commit pinning**: operators set `auto_update: false` on
  `~/nixblitz/config.json` for a plugin to freeze its
  `pinned_rev`. Useful for security-sensitive plugins.

### Bumping `manifest.schema_version`

If a future TUI bump changes the manifest format breaking-ly
(like v1 → v2's `run_as_root` removal), authors need to publish a
matching plugin update. Existing operators of the old plugin
hit a hard-fail on next `plugin refresh` until they upgrade.

Breaking bumps are rare (so far: just v1 → v2, for sudo posture
A). v3 (`tile_manifests`), v4 (`branches`), and v5 (`wasm` actions +
`sandbox`) were all additive — old TUIs keep loading those manifests
and ignore the new fields (a `wasm` action just can't run on a pre-v5
TUI, same as any other unrecognized action shape). When a breaking
bump happens, plugins.md will document the migration shape; this doc
gets updated alongside.

## Worked examples

Three in-tree plugins exercise everything in this doc:

- [**tailscale**](https://github.com/raspiblitz/nixblitz_official_plugins/src/branch/main/tailscale)
  — secret config field (`auth_key`), tile with state-machine
  status, autoconnect systemd unit gated on the auth key, no
  privileged actions.
- [**lnbits**](https://github.com/raspiblitz/nixblitz_official_plugins/src/branch/main/lnbits)
  — `select` config field (`backend`), credential-staging from
  LND's macaroon (the RTL pattern), one privileged `unit:`
  action (`reset_db`).
- [**node-summary**](https://github.com/raspiblitz/nixblitz_official_plugins/src/branch/main/node-summary)
  — the logic-only WASM tier: no `plugin.nix`, a Rust guest compiled
  to `wasm32-wasip1` with `run` / `tile` / `check_sandbox` exports, a
  read-only `bitcoin_rpc` allowlist, a sandboxed dashboard tile, and
  the forbidden-call demo. The reference for "Sandboxed WASM actions"
  above.

Read all three. Between them they cover ~95% of the patterns
you'll need; everything else is straightforward NixOS.

## Where to ask

Issues + design discussion in
[`github.com/raspiblitz/nixblitz/issues`](https://github.com/raspiblitz/nixblitz/issues).
Plugin-system design rationale is in
[`docs/decisions/plugins.md`](https://github.com/raspiblitz/nixblitz/src/branch/main/docs/decisions/plugins.md) — read D14
(threat model + permissions) and D18 (sudo posture) before
proposing changes to the security surface.
