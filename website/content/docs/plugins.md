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

For ephemeral or one-shot secrets — pre-auth keys, OTPs, unlock
tokens — use an [action input](#action-inputs) instead of a
`secret` config field. Inputs are collected from the operator at
action time, transported to the spawned process via an env var
(or a transient `/run` EnvironmentFile for `unit:` actions), and
discarded immediately afterwards. They never touch
`config.json` or the store.

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
auto-renders the right editor. Values are persisted to the
plugin's `config.json` and read at every `nixos-rebuild` — pick
this block for stable knobs (URLs, toggles, paths). For
ephemeral or one-shot values, use [action inputs](#action-inputs)
instead.

```json
"config": {
  "login_server": {
    "type": "string",
    "label": "Login server URL (headscale, etc.)",
    "required": false
  },
  "exit_node": {
    "type": "bool",
    "label": "Advertise this node as an exit node",
    "default": false
  },
  "shared_token": {
    "type": "secret",
    "label": "Long-lived shared token",
    "required": false
  }
}
```

Available `type`s:

- `bool` — checkbox-style toggle.
- `int` — number input.
- `string` — single-line text.
- `secret` — masked input. Stored cleartext in `config.json`
  today; the masking is just UI hygiene. Reserve this for
  long-lived shared tokens — pre-auth keys, OTPs and other
  one-shot values belong on an action's
  [`inputs`](#action-inputs) list, which never persists.
- `select<a|b|c>` — pick one. Pipe-separated choices.
- `list<string>` / `list<int>` / `list<bool>` — homogeneous list.

`label` is the displayed prompt. `required: true` makes the field
mandatory; `default` provides an initial value (defaults are NOT
written to `config.json` until the user touches them — the
plugin code should re-derive the default if absent).

In `plugin.nix`, read each field via `pluginCfg.<key> or
<fallback>`:

```nix
loginServer = pluginCfg.login_server or "";
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
| `inputs`          | `[]`    | Operator-supplied values collected just before the action runs. See [Action inputs](#action-inputs).        |

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

#### Action inputs

Some actions need an ephemeral value the operator types in once
and the plugin then consumes — a pre-auth key, an OTP, a one-shot
unlock token. Persisting that to `config.json` (and thereby git
history) is both pointless and a small leak surface, so actions
declare these as `inputs` and the TUI collects them right before
the run:

```json
"actions": {
  "connect": {
    "label": "Connect with pre-auth key",
    "description": "Join the tailnet with a one-time pre-auth key.",
    "unit": "tailscale-connect-preauth.service",
    "confirm": false,
    "inputs": [
      {
        "name": "authkey",
        "label": "Pre-auth key",
        "description": "From the Tailscale admin console (Settings → Keys).",
        "type": "secret"
      }
    ]
  }
}
```

| Input field   | Required | Meaning                                                                                        |
| ------------- | -------- | ---------------------------------------------------------------------------------------------- |
| `name`        | yes      | Identifier — must match `[a-z][a-z0-9_]*`. Becomes the env-var suffix (see below).             |
| `label`       | yes      | Prompt label shown above the input field.                                                      |
| `description` | no       | Helper text rendered under the label. Optional.                                                |
| `type`        | no       | `"text"` (plain row) or `"secret"` (masked, uses the password-input widget). Default `"text"`. |

The TUI prompts for each input in declared order. `secret` fields
reuse the password-input widget (Tab to peek, no length minimum
for action inputs, no confirmation step).

**Transport into the action's process** depends on the action's
flavor:

- **`command:` action** → each input becomes an env var on the
  spawned `bash -c` process, named `NIXBLITZ_INPUT_<NAME_UPPER>`.
  Read it directly in your script:

  ```bash
  echo "got authkey: $NIXBLITZ_INPUT_AUTHKEY" >&2
  ```

- **`unit:` action** → the TUI writes the inputs to a transient
  EnvironmentFile at `/run/nixblitz/<unit-stem>-input.env` via
  sudo (mode 600, root-owned) right before
  `systemctl start --wait`, and deletes it after the unit exits.
  Your unit declares `EnvironmentFile=-` pointing at the same
  path and reads the same env-var names:

  ```nix
  systemd.services.tailscale-connect-preauth = {
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "-/run/nixblitz/tailscale-connect-preauth-input.env";
    };
    script = ''
      if [ -z "''${NIXBLITZ_INPUT_AUTHKEY:-}" ]; then
        echo "no auth key provided" >&2
        exit 1
      fi
      ${pkgs.tailscale}/bin/tailscale up \
        --authkey="''${NIXBLITZ_INPUT_AUTHKEY}"
    '';
  };
  ```

  The leading `-` on `EnvironmentFile` matters: it keeps the unit
  valid when the file is absent (the operator might
  `systemctl start` the unit without going through the TUI, in
  which case there's no env file and the unit should fail
  cleanly with the "no value" message, not refuse to start).

Inputs are never on the command line (so `ps -ef` doesn't see
them) and never written to `config.json`. They live in
`PluginActionRunner`'s in-memory map for the duration of the run
and are discarded afterwards.

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

### Reading another plugin's user config

The block above (`config.services.lnd.certPath` etc.) is the
upstream NixOS module's view — its declared options, after all
modules have evaluated. That works for hardware paths and other
post-eval shapes, but it doesn't help when you need to know
whether the operator has _enabled_ another plugin, or which
network they picked. Plugins don't declare NixOS options for
those (and the old `config.features.apps.<id>.<key>` wiring was
removed when bitcoind / lnd / cln became plugins themselves).

Instead, every entry in `~/nixblitz/config.json`'s `app_configs.*`
block is exposed as `config.nixblitz.appConfigs.<id>.<key>`:

```nix
{ config, lib, pkgs, ... }: let
  appCfgs = config.nixblitz.appConfigs or {};
  lndEnabled = (appCfgs.lnd or {}).enabled or false;
  btcNetwork = (appCfgs.bitcoind or {}).network or "mainnet";
in {
  # ... condition on lndEnabled / btcNetwork ...
}
```

The shape is loose (`attrsOf attrs`), so always read with `or
default` fallbacks — the option's value mirrors whatever JSON
the operator's `config.json` has, including fields that haven't
been seeded yet.

Use this for state-of-other-apps reads; keep `config.services.X.*`
for post-eval option reads.

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

| Change                                                           | Propagated by                                                           | When applied                        |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------- |
| Manifest edit (new field, bumped tile poll interval, new action) | `nixblitz plugin update <id>` or implicit during `Update entire system` | Immediately after update            |
| `plugin.nix` change (new systemd unit, env var, hardening tweak) | Same — the new file lands on disk during refresh                        | Next `nixos-rebuild switch` (Apply) |

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
- **`secret` config fields end up in the store.** Phase 1 inlines
  `pluginCfg` values into the build. If the operator commits
  `~/nixblitz/` to a public mirror, secrets leak. For one-shot
  values (pre-auth keys, OTPs) prefer an [action
  input](#action-inputs) — it bypasses `config.json` entirely
  and is discarded after the action runs.
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
  — tile with state-machine status, two privileged `unit:`
  actions (`connect` with a `secret` input for the one-time
  pre-auth key, `leave` with a y/N confirm). No persisted
  secrets: the pre-auth key is consumed once and discarded — the
  canonical example of the action-inputs pattern.
- [**lnbits**](https://forge.f44.fyi/f44/nixblitz_official_plugins/src/branch/main/lnbits)
  — `select` config field (`backend`), credential-staging from
  LND's macaroon (the RTL pattern), one privileged `unit:`
  action (`reset_db`) with a y/N confirm and no inputs.

Read both. Between them they cover ~95% of the patterns you'll
need; everything else is straightforward NixOS.

## Where to ask

Issues + design discussion in
[`forge.f44.fyi/f44/nixblitz_ng/issues`](https://forge.f44.fyi/f44/nixblitz_ng/issues).
