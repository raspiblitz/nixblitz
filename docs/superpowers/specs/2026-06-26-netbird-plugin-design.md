# NetBird plugin — design

Date: 2026-06-26
Status: approved (design)

## Goal

Add a NetBird plugin to NixBlitz with the same shape as the existing Tailscale
plugin: enable the NetBird client on a node, join a network on demand via an
ephemeral setup key, and surface connection status as a dashboard tile. The
operator has switched from Tailscale to NetBird and wants parity.

## Context

Tailscale is a self-contained plugin, not a core module. It is three files in
the **separate** `nixblitz_official_plugins` repo
(`forge.f44.fyi/f44/nixblitz_official_plugins`, checked out locally at
`examples_redesign/nixblitz_official_plugins/tailscale/`):

- `plugin.json` — manifest: config schema, actions, permissions, dashboard tile.
- `plugin.nix` — two-stage-ABI NixOS module: `services.tailscale.enable`, the
  connect/leave oneshot units, the tile-state + app-version shell scripts.
- `README.md`.

Plus a one-line catalog entry in _this_ repo at
`tui/lib/src/ui/views/configure/plugin_catalog.dart` pointing at the plugin's
forge URL. The plugin system is fully manifest-driven, so **no core Dart code
changes** are needed — NetBird reaches Tailscale parity by shipping an
equivalent manifest + module.

NetBird is therefore a parallel three-file plugin in the official-plugins repo
plus one catalog line here. Two repos ⟶ two commits.

## NetBird vs Tailscale mapping

| Tailscale                             | NetBird                                     | Notes                                                                                                         |
| ------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `services.tailscale.enable`           | `services.netbird.enable`                   | direct analog                                                                                                 |
| `tailscale up --authkey=KEY`          | `netbird up --setup-key=KEY`                | ephemeral key → Connect action input, never persisted                                                         |
| `login_server` (headscale)            | `management_url` (self-hosted mgmt server)  | persisted string field, default `""` = NetBird cloud                                                          |
| `tailscale status --json`             | `netbird status --json`                     | tile script, different JSON keys                                                                              |
| `tailscale logout` (forgets identity) | `netbird down` (disconnect, keeps identity) | **Disconnect** verb, decided below                                                                            |
| `exit_node` / `--advertise-exit-node` | _(dropped)_                                 | NetBird routes are configured server-side in the management dashboard; there is no client-side exit-node flag |

### Decisions

- **Exit node: dropped.** NetBird routing peers / network routes are defined
  server-side in the NetBird management dashboard, not via a `netbird up` flag.
  Carrying an `exit_node` toggle would be misleading. Config schema is just
  `enabled` + `management_url`.
- **Disconnect, not logout.** `netbird down` stops the connection but keeps the
  node's registration, so reconnecting via Connect does **not** require a fresh
  setup key. This matches NetBird's natural model. A single `disconnect` action
  (confirm-gated) covers it; no separate "forget" verb.

## Components

### `nixblitz_official_plugins/netbird/plugin.json`

- `id: "netbird"`, `version`, `app_version: { "command": "netbird-app-version" }`.
- `manifest`: `schema_version: 4` (matching the current Tailscale manifest),
  `min_tui_version: 1`, name "NetBird", description.
- `branches`: `stable` → `main`, default.
- `config_schema.fields`:
  - `enabled` — bool, default `false`.
  - `management_url` — string, default `""`. Label: "Management server URL
    (self-hosted; blank = NetBird cloud)".
- `actions`:
  - `connect` — label "Connect with setup key", `unit:
netbird-connect-setupkey.service`, `confirm: false`, `timeout_seconds: 60`,
    one input `setupkey` (type `secret`, label "Setup key", description noting
    it comes from the NetBird dashboard / self-hosted management console and is
    consumed immediately, not persisted).
  - `disconnect` — label "Disconnect", description "Runs `netbird down` —
    disconnects from the network. The node keeps its registration, so Connect
    reconnects without a new setup key.", `unit: netbird-down.service`,
    `confirm: true`, `timeout_seconds: 30`.
- `permissions`: `network: ["outbound"]`, `privileged_units:
["netbird-connect-setupkey.service", "netbird-down.service"]`.
- `dashboard`: title "NetBird", `accent_color: "#F68330"` (NetBird orange),
  `command: "netbird-tile-state"`, `poll_interval_seconds: 30`,
  `timeout_seconds: 5`.

### `nixblitz_official_plugins/netbird/plugin.nix`

Two-stage ABI: `{pluginCfg ? {}}: {lib, pkgs, ...}:`.

- Read `managementUrl = pluginCfg.management_url or "";`.
- `services.netbird.enable = true;`.
- `netbird-connect-setupkey.service` — oneshot, `after`/`wants`
  network-online, `EnvironmentFile = "-/run/nixblitz/netbird-connect-setupkey-input.env"`.
  Script: error out if `NIXBLITZ_INPUT_SETUPKEY` is empty (with the same
  "start this through the TUI's Connect action" message as Tailscale), else run
  `netbird up --setup-key="$NIXBLITZ_INPUT_SETUPKEY"`, adding
  `--management-url=<managementUrl>` (via `lib.escapeShellArg`) only when set.
- `netbird-down.service` — oneshot `netbird down`.
- `netbird-tile-state` (`pkgs.writeShellScriptBin`) — runs `netbird status
--json`; state machine:
  - command fails / empty / non-JSON → `error`, label "daemon down",
    footer "netbird.service is not responding".
  - `.management.connected != true` → `error`, label "not connected",
    footer "open Configure → NetBird → Connect".
  - else → `ok`, label "connected", with rows: `ip` (`.netbirdIp`),
    `peers` (`.peers.connected`/`.peers.total`), `fqdn` (`.fqdn`).
- `netbird-app-version` (`pkgs.writeShellScriptBin`) — `netbird version | head -1`.
- `environment.systemPackages = [tileStateScript appVersionScript];`.

All `netbird` invocations use the path the default-client daemon expects — see
verifications below.

### This repo: catalog entry

One `OfficialPlugin(...)` in
`tui/lib/src/ui/views/configure/plugin_catalog.dart`:
`id: 'netbird'`, name "NetBird", description, `url:
'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/netbird'`.

### `nixblitz_official_plugins/netbird/README.md`

Short operator/author note mirroring `tailscale/README.md`: what it does, the
`enabled` + `management_url` fields, and the Connect (setup key) / Disconnect
actions.

## Data flow

1. Operator enables NetBird and optionally sets `management_url` in Configure →
   NetBird. Stored in `config.json` `app_configs.netbird`.
2. `nixos-rebuild` feeds `app_configs.netbird` to the plugin's outer function as
   `pluginCfg`; `services.netbird.enable` brings up the daemon.
3. Operator runs Configure → NetBird → Connect, enters a setup key. The TUI's
   `PluginActionRunner` writes it to
   `/run/nixblitz/netbird-connect-setupkey-input.env` (root, mode 600), starts
   the unit `--wait`, then deletes the file. The unit runs `netbird up`.
4. The dashboard tile polls `netbird-tile-state` every 30s.

## Error handling

- Missing setup key in the connect unit → explicit non-zero exit with guidance,
  same pattern as Tailscale.
- Tile script degrades to `error` states for daemon-down / not-connected rather
  than failing the poll.
- `EnvironmentFile` leading `-` keeps the connect unit valid before any Connect
  run (file absent post-rebuild).

## Testing

- This is a plugin in a separate repo; there is no NixBlitz-core test harness
  for it. Validate by: `nix` eval of the plugin module against a fixture
  `pluginCfg`, and a manual VM/host run (`services.netbird.enable`, Connect with
  a real setup key, observe the tile go `connected`).
- The catalog entry change in this repo is covered by the standard
  `just test; just analyze; just format` trio.

## Implementation-time verifications (must confirm against pinned nixpkgs 25.11 / `pkgs.netbird`)

1. `services.netbird.enable` is the correct option, and the **daemon socket /
   CLI** used by the default single client — so `up`/`down`/`status` target the
   right daemon (plain `netbird` for the default client, or the module's
   wrapped CLI if it differs).
2. The exact `netbird status --json` key names (`management.connected`,
   `netbirdIp`, `peers.connected`/`peers.total`, `fqdn`).

## Out of scope

- Routing-peer / exit-node support (server-side concern in NetBird).
- A "forget identity" action.
- Multi-client (`services.netbird.clients.*`) setups — single default client
  only, matching Tailscale's single-tailnet shape.
