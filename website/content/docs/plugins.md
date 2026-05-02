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
[`nixblitz_official_plugins`](https://forge.f44.fyi/f44/nixblitz_official_plugins).

## What you're shipping

A plugin is a directory tree with three (sometimes four) files:

```
my-plugin/
├── plugin.nix       # NixOS module — what the system runs
├── manifest.json    # User-facing surface — fields, actions, tile
├── README.md        # Operator-facing docs (recommended)
└── LICENSE          # (recommended)
```

Plus, on the operator's installed system, after `nixblitz plugin add`:

```
~/nixblitz/plugins/my-plugin/
├── plugin.nix       # ← clone of the above
├── manifest.json    # ← clone of the above
├── config.json      # ← user's settings, written by the TUI
├── README.md
└── LICENSE
```

`config.json` is per-plugin and the TUI manages it. It mirrors
what the operator typed into the manifest's `config:` form, plus
metadata the system tracks (`enabled`, `auto_update`, `pinned_rev`).

Hosting: a plugin lives in its own git repo (the simplest case)
or as a subdir of a multi-plugin repo. The `nixblitz plugin add`
command supports both:

```
nixblitz plugin add forgejo:forge.f44.fyi/f44/my-plugin
nixblitz plugin add forgejo:forge.f44.fyi/f44/all-plugins/tailscale
nixblitz plugin add github:fusion44/some-plugin
```

The repo is shallow-cloned; only `plugin.nix`, `manifest.json`,
`README.md`, and `LICENSE` are copied to the operator's tree.

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
strings, not fine for long-lived secrets.

## Manifest reference

### `manifest` header (required)

```json
{
  "manifest": {
    "schema_version": 2,
    "min_tui_version": 1,
    "name": "Tailscale",
    "description": "Enable Tailscale on this NixBlitz node…"
  }
}
```

| Field             | Required | Meaning                                                                                                                                                        |
| ----------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `schema_version`  | yes      | Manifest schema your plugin targets. v2 is current.                                                                                                            |
| `min_tui_version` | yes      | Lowest TUI version that can render this plugin safely.                                                                                                         |
| `name`            | yes      | Human-readable display name shown in Configure → plugins. Keep it short and properly capitalized (`"Tailscale"`, `"LNBits"`) — _not_ an identifier-style slug. |
| `description`     | no       | Long-form description shown at install time.                                                                                                                   |

A TUI loading a manifest with `min_tui_version >
currentPluginManifestVersion` refuses to install with a clear
error. A TUI loading a `schema_version` it doesn't understand
hard-fails (no silent partial parsing).

### `config` block (optional)

User-editable fields. Each field is a typed entry; the TUI
auto-renders the right editor.

```json
"config": {
  "login_server": {
    "type": "string",
    "label": "Login server URL (headscale, etc.)",
    "required": false
  },
  "auth_key": {
    "type": "secret",
    "label": "Tailnet auth key",
    "required": false
  },
  "exit_node": {
    "type": "bool",
    "label": "Advertise this node as an exit node",
    "default": false
  }
}
```

Available `type`s:

- `bool` — checkbox-style toggle.
- `int` — number input.
- `string` — single-line text.
- `secret` — masked input. Stored cleartext in `config.json`
  today; the masking is just UI hygiene.
- `select<a|b|c>` — pick one. Pipe-separated choices.
- `list<string>` / `list<int>` / `list<bool>` — homogeneous list.

`label` is the displayed prompt. `required: true` makes the field
mandatory; `default` provides an initial value (defaults are NOT
written to `config.json` until the user touches them — the
plugin code should re-derive the default if absent).

In `plugin.nix`, read each field via `pluginCfg.<key> or
<fallback>`:

```nix
authKey = pluginCfg.auth_key or "";
exitNode = pluginCfg.exit_node or false;
```

### `actions` block (optional)

User-triggerable verbs. Two flavors, discriminated by which key
is set:

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

Exactly one of `command` / `unit` per action. The discrimination
matters:

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

| Field                   | Default   | Meaning                                        |
| ----------------------- | --------- | ---------------------------------------------- |
| `title`                 | —         | Tile heading.                                  |
| `accent_color`          | `#888899` | Hex `#rrggbb` for the title + top rule.        |
| `command`               | —         | Polled command. Runs as admin user.            |
| `poll_interval_seconds` | `30`      | How often to poll. Floor: 5s.                  |
| `timeout_seconds`       | `5`       | SIGTERM at this limit; tile shows "timed out". |

Tile commands always run as the admin user — no `run_as_root`,
no sudo. Tile polls fire on a 30s timer; surfacing a sudo modal
on a background poll would be a UX disaster. If your tile needs
privileged data, expose it through a group-readable file or a
setuid wrapper, never through sudo.

#### Tile-state output protocol

The polled command writes JSON to stdout. Shape: a flat object
where reserved keys (`_status_label`, `_status_color`, `_footer`,
`_footer_color`) drive the badge / footer chrome, and every other
key/value pair becomes a `(label, value)` row in declared order.

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

### `permissions` block (optional)

Declarative for now (informational; no runtime enforcement).
Surfaced at `plugin add` time as the consent-prompt summary.

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
runner injects PATH preambles so the lookup just works.

## Reading core service config from `plugin.nix`

Plugins frequently need to wire into the node's bitcoind / lnd /
cln config. The plugin's inner module receives the full
`config` argument and can read anything declared by other modules:

```nix
{ config, lib, pkgs, ... }: let
  lndCertPath = config.services.lnd.certPath;
  lndDataDir  = config.services.lnd.networkDir;
in {
  # ...
}
```

`config.services.X.*` is keyed off the option _as the upstream
module declares it_ — usually `services.<name>` for nix-bitcoin
modules.

### The credential-staging pattern (RTL / lnbits)

Several core service files (LND's admin macaroon, e.g.) live with
mode `0600` owned by the service user. Group membership doesn't
help. The standard NixOS dance:

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

## Update flow: what propagates how

Two kinds of plugin update:

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
  in your README.
- **Tile-state command timeouts.** The polled command runs every
  N seconds with a hard timeout. If it depends on a network call
  set a generous `timeout_seconds` and a shorter explicit
  timeout inside the script (e.g. `curl --max-time 3`). A tile
  that hangs locks up the poller.

## Publishing

The
[`nixblitz_official_plugins`](https://forge.f44.fyi/f44/nixblitz_official_plugins)
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

## Worked examples

Two in-tree plugins exercise everything in this doc:

- [**tailscale**](https://forge.f44.fyi/f44/nixblitz_official_plugins/src/branch/main/tailscale)
  — secret config field (`auth_key`), tile with state-machine
  status, autoconnect systemd unit gated on the auth key, no
  privileged actions.
- [**lnbits**](https://forge.f44.fyi/f44/nixblitz_official_plugins/src/branch/main/lnbits)
  — `select` config field (`backend`), credential-staging from
  LND's macaroon (the RTL pattern), one privileged `unit:`
  action (`reset_db`).

Read both. Between them they cover ~95% of the patterns you'll
need; everything else is straightforward NixOS.

## Where to ask

Issues + design discussion in
[`forge.f44.fyi/f44/nixblitz_ng/issues`](https://forge.f44.fyi/f44/nixblitz_ng/issues).
