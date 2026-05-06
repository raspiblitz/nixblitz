# Plugin Extraction: blitz-api — Phase 4 Design

**Date:** 2026-05-06
**Status:** Draft
**Tracking:** Phase 4 of "extract bitcoind/lnd/cln/blitz-api/blitz-web into plugins"

## Goal

Move blitz-api from a built-in core feature to a real plugin living in a
separate repository. Exercise the plugin lifecycle end-to-end: install,
manifest-declared dependencies, NixOS module loading, dashboard streamer.
Delete the in-process `BlitzApiBridgeSource` and its `InProcessAdapterSource`
base class — the last transitional pieces from Phase 1.

After Phase 4 the plugin model isn't theoretical any more: there's a real
plugin in production, the install/enable/dependency flow has been driven
through, and the path is paved for Phases 5–6 to do the same for
blitz-web/lnd/cln.

## Non-goals (deferred)

- **Moving bitcoind, lnd, cln, or blitz-web.** Phase 5+. blitz-api depends on
  bitcoind; for Phase 4 bitcoind is still core, declared as a `type: "app"`
  dependency. When bitcoind becomes a plugin (later phase), the dependency
  shape switches to `type: "plugin"` + URL.
- **Moving the `bitcoin.json` / `lightning.json` tile manifests out of core.**
  These tiles describe bitcoind / lnd / cln respectively — the blitz-api
  plugin is just a _data source_ for them. Their canonical owners follow them
  into bitcoind / lnd / cln plugins in later phases. For Phase 4 the
  blitz-api plugin's streamer feeds these still-bundled-in-core manifests.
- **Auto-migration for existing installs.** Operator manually installs the
  blitz-api plugin via TUI after deploying the new binary. Hard-fail rebuild
  is acceptable during development; post-release, blitz-api will never have
  been a core feature so there's no migration scenario.
- **First-party plugin auto-trust.** All plugins (including f44's own) go
  through the same install consent prompt; no special-case URL allowlist.
- **Plugin authoring tooling.** No `nixblitz plugin create` scaffolder, no
  CI workflow templates. Plugins are written by hand for now.

## Architecture

### Before Phase 4

```
core (forge.f44.fyi/f44/nixblitz_ng)
├── templates/modules/apps/blitz-api.nix         # Nix module
├── common/lib/src/services/configure/bundled/manifests/blitz_api.json
├── common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart
├── common/lib/src/services/dashboard/sources/in_process_adapter_source.dart
├── common/lib/src/services/blitz_api/blitz_api_client.dart    # SSE client
└── common/lib/src/services/blitz_api/sse_event.dart           # event type
```

### After Phase 4

```
forge.f44.fyi/f44/nixblitz-plugin-blitz-api  (NEW — separate repo)
├── plugin.json                  # manifest with requires, config_schema, module, streamers
├── module.nix                   # was templates/modules/apps/blitz-api.nix
└── streamers/blitz_api_stream.py    # was BlitzApiBridgeSource's logic, in Python

core (forge.f44.fyi/f44/nixblitz_ng)
├── (templates/modules/apps/blitz-api.nix DELETED)
├── (common/.../bundled/manifests/blitz_api.json DELETED)
├── (common/.../sources/blitz_api_bridge_source.dart DELETED)
├── (common/.../sources/in_process_adapter_source.dart DELETED)
├── (common/.../blitz_api/blitz_api_client.dart DELETED)
├── (common/.../blitz_api/sse_event.dart DELETED)
└── plugin manifest schema gains: requires, module, streamers fields
```

The bitcoin.json + lightning.json tile manifests stay in core. The
blitz-api plugin's `streamers/blitz_api_stream.py` produces JSON-line
events for those tile ids (`bitcoin`, `lightning`).

## Plugin manifest schema additions

Phase 3's `PluginManifest` already has `configSchema`. Phase 4 adds three
fields:

```jsonc
{
  "id": "blitz-api",
  "name": "Blitz API",
  "version": "1.0.0",
  "url": "git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api",

  "requires": [{ "type": "app", "id": "bitcoind" }],

  "module": "module.nix",

  "streamers": [
    {
      "name": "blitz-api-stream",
      "command": "python3",
      "args": ["streamers/blitz_api_stream.py"],
      "tile_ids": ["bitcoin", "lightning"],
    },
  ],

  "config_schema": {
    "label": "Blitz API",
    "fields": [
      {
        "name": "enabled",
        "type": "bool",
        "label": "Enabled",
        "default": false,
      },
    ],
  },
}
```

### `requires` — dependency declaration

Array of objects, each one of two shapes:

- `{ "type": "app", "id": "<app-name>" }` — depends on a still-in-core app.
  Used in Phase 4 because bitcoind hasn't been extracted yet. Check at
  install/enable time: `config.appConfigs[id].enabled == true`.
- `{ "type": "plugin", "url": "<plugin-url>" }` — depends on another
  installed plugin, identified by its source URL (the canonical unique
  identifier, since multiple bitcoind implementations could exist with
  different tradeoffs). Check: an installed plugin's `url` matches.

The TUI's plugin install flow refuses (or warns + lets the operator proceed
into a "missing dependency" state) if a `requires` entry isn't satisfied.

### `module` — NixOS module path

Relative path within the plugin's checkout. Core's `~/nixblitz/plugins.list`
mechanism (below) imports each installed plugin's `module.nix`.

### `streamers` — dashboard tile event sources the plugin contributes

Array of streamer specs:

- `name` — unique identifier within the plugin (used for log lines).
- `command` — executable to spawn (e.g. `python3`, or a path to a Dart
  binary, or `bash`).
- `args` — argv list. Paths are resolved relative to the plugin's
  installation directory.
- `tile_ids` — which tile manifests this streamer is **permitted** to emit
  events for. **Authoritative, not advisory.** `TileDataCache.apply()` (or
  the registry-level glue listening on the source's stream) filters
  incoming events against the source's declared tile_ids; events for tiles
  outside that set are dropped and logged at warn level. Prevents one
  plugin's streamer from emitting fake events for tiles owned by another
  plugin (e.g. a malicious lightning plugin spoofing Bitcoin tile state).

Core's `tileSourceRegistryProvider` (Phase 1) reads installed plugin
manifests and instantiates a `StreamerSubprocessSource` per streamer entry.
Each source's `providedTileIds` field (already on the Phase 1
`TileEventSource` interface) is populated from the manifest's
`tile_ids` array — that's the boundary the cache enforces.
Existing subprocess source machinery (restart-with-backoff, crash-loop
detection, SIGTERM/SIGKILL on dispose) Just Works.

## Streamer: `blitz_api_stream.py`

Same job as `BlitzApiBridgeSource` + `BlitzApiClient` from Phase 1, in
Python. Reads SSE from `http://127.0.0.1:2121/sse/subscribe` (with JWT auth
read from `/var/lib/blitz_api/.login-password`), routes events to tile
ids, emits JSON-lines on stdout.

Key behaviour:

- **Auth path:** read password from `/var/lib/blitz_api/.login-password`
  (Phase 1 chmod'd this readable to `wheel`; Phase 4's plugin runs under
  systemd as a streamer subprocess of the TUI which runs as the operator
  user `admin`, member of `wheel`). Same trust model as before.
- **Login:** POST password to `/system/login`, get JWT.
- **SSE subscribe:** GET `/sse/subscribe` with `Authorization: Bearer
<JWT>`. Parse SSE frames.
- **Event routing:** `btc_info` and `btc_mempool_status` → emit
  `{"tile": "bitcoin", "data": {…}, "ts": …}`. `ln_info` and
  `wallet_balance` → emit `{"tile": "lightning", "data": {…}, "ts": …}`.
  Other event types: ignore.
- **Reconnect:** on stream error, exit non-zero. Core's
  `StreamerSubprocessSource` handles backoff + restart.
- **Cold start:** if the password file is missing or unreadable, exit
  non-zero with a message. Core surfaces this as a tile error.

Dependencies: `requests` + `sseclient-py` (or equivalent — both are in
nixpkgs). The plugin's `module.nix` declares them in the systemd service's
`PATH` / `pythonEnv`.

Approximate size: ~80 lines of Python.

## Dependency check

When the TUI loads installed plugins:

```dart
List<PluginStatus> checkPlugins(List<PluginManifest> plugins, NixblitzConfig config) {
  return plugins.map((p) {
    for (final dep in p.requires) {
      switch (dep) {
        case AppDep(:final id):
          if (!config.isAppEnabled(id)) {
            return PluginStatus.missingDep(p.id, dep);
          }
        case PluginDep(:final url):
          if (plugins.where((other) => other.url == url).isEmpty) {
            return PluginStatus.missingDep(p.id, dep);
          }
      }
    }
    return PluginStatus.ok(p.id);
  }).toList();
}
```

Plugin status surfaces in:

- **Dashboard banner** — if any installed plugin has missing deps, show a
  banner "<plugin> requires <dep>; install/enable it" with the relevant
  `[c] Configure` action.
- **Configure → Plugins screen** — each plugin row shows OK / missing-dep
  / disabled status with the dep that's missing.

Plugins with missing deps:

- **Their `module.nix` is NOT included in the rebuild.** Otherwise the
  rebuild would fail at evaluation time on the missing dependency's options.
- **Their streamer is NOT spawned.** No tile data flows.
- The plugin sits in "installed but inactive" state until the dep is
  satisfied.

## Nix module discovery: `~/nixblitz/plugins.list` (TUI-managed)

Currently `templates/hosts/installed.nix` imports app modules via
`templates/modules/apps/<name>.nix`. After Phase 4 there's no
`blitz-api.nix` in core templates, but the plugin's `module.nix` needs to
be imported.

### Authoritative state vs. derived file

`plugins.list` is **not** the authoritative record of installed plugins —
it's a derived artifact that `installed.nix` reads at Nix-eval time. The
authoritative state lives in **install marker files**, one per plugin:

```
~/nixblitz/plugins/<plugin-id>/.nixblitz-installed.json
  {
    "id": "blitz-api",
    "url": "git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api",
    "version": "1.0.0",
    "rev": "<short git hash>",
    "installed_at": "2026-05-06T..."
  }
```

The marker is written by the TUI's plugin install flow. Its presence is
the only signal that a plugin was installed via the approved path.

`plugins.list` is **regenerated from markers** every time the TUI runs
Apply (or a plugin is installed/enabled/disabled/uninstalled). The TUI:

1. Walks `~/nixblitz/plugins/*/`.
2. Reads each `.nixblitz-installed.json` marker.
3. Skips plugins whose deps aren't satisfied (per the dependency check above).
4. Writes only the satisfied set to `plugins.list`.
5. **Diff-checks `plugins.list` before writing**: if it had paths without
   corresponding markers, those entries are dropped and a `LogService.warn`
   names them. This catches a malicious already-installed plugin appending
   to `plugins.list` to sneak an unapproved module into the rebuild.

`installed.nix` reads the regenerated list:

```nix
{
  imports =
    let
      pluginsListPath = ./plugins.list;
      pluginsListContent =
        if builtins.pathExists pluginsListPath
        then builtins.readFile pluginsListPath
        else "";
      pluginPaths = lib.filter (s: s != "") (lib.splitString "\n" pluginsListContent);
      pluginModules = map (path: import "${path}/module.nix") pluginPaths;
    in
      [ ./hosts/installed-pi5.nix ] ++ pluginModules;
}
```

(Approximate; real placement in installed.nix depends on the existing
structure.)

### TUI plugin install flow

1. **Consent prompt** (see "Install consent + trust contract" below).
2. `git clone <url>` into `~/nixblitz/plugins/<plugin-id>/`.
3. Validate the cloned plugin's `plugin.json` against `PluginManifest.fromJson`.
4. Write `~/nixblitz/plugins/<plugin-id>/.nixblitz-installed.json` with
   `{id, url, version, rev, installed_at}`.
5. Regenerate `plugins.list` from all markers (existing + new).
6. `git add plugins.list plugins/<plugin-id>/` — operator commits via
   the existing TUI Apply flow.

Plugin disable: keep the marker but add a `disabled: true` flag — TUI
filters disabled markers out when regenerating `plugins.list`.

Plugin uninstall: `rm -rf ~/nixblitz/plugins/<plugin-id>/`. Marker goes
with the directory; next regenerate produces a `plugins.list` without
that path.

## Install consent + trust contract

Trust is enforced at install time, not at runtime. The TUI's install flow
surfaces a consent prompt **before** `git clone`, and the prompt enumerates
the privilege positions the plugin will hold:

```
Install plugin: blitz-api
  from:    git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api
  version: 1.0.0 (rev <abcd1234>)
  requires: bitcoind (built-in)

This plugin runs on your system in two privileged positions:

  • NixOS module activation runs AS ROOT on every system rebuild.
    The module can define users, services, network rules, file
    permissions — anything a root-level NixOS module can do.

  • A subprocess streamer runs as the operator user (admin) with
    full network access. It can read /var/lib/blitz_api/.login-password
    (the JWT), invoke systemctl, and make outbound network requests.

Confirm install? [y/N]
```

The prompt enumerates positions, not theoretical attack surfaces. There's
no security theatre ("plugin requested access to: A, B, C — allow?"); just
the honest summary of where the plugin executes.

### Dependency-resolution prompts

When a plugin's `requires` array names another plugin not yet installed,
the TUI offers to install the dep:

```
Plugin blitz-api requires another plugin not yet installed.

  Required:  git+https://forge.f44.fyi/f44/nixblitz-plugin-bitcoind

  Install this dependency now? [y/N]
```

The URL comes **directly from the original plugin's `requires[].url`** —
never operator-typed in this prompt. Eliminates dependency-typosquat: the
operator can't fat-finger an attacker-controlled URL during this step.

If the operator declines, the original plugin sits in
"installed but inactive (missing dep)" state until either the dep is
installed or the operator removes the plugin.

### Trust boundary, stated plainly

There is no runtime sandbox between plugins and the system. A plugin's
`module.nix` is a regular NixOS module merged into the system config; its
streamer is a subprocess in the operator user's session. **If you trust a
plugin enough to install, you trust it.** Mitigations against malicious
plugins focus on:

- Operator awareness at install time (this consent prompt)
- Reducing typosquat risk in dep flows (URL auto-fill above)
- Cross-plugin event isolation (`tile_ids` enforcement above)
- Attempted-tampering detection (orphan paths in `plugins.list` logged)

Mitigations _not_ attempted: process sandboxing, capability filtering,
runtime privilege drop. These add complexity without proportional value
when the install-time trust grant is the actual decision point.

## What gets deleted from core

Files removed in Phase 4's cleanup:

- `templates/modules/apps/blitz-api.nix`
- `common/lib/src/services/configure/bundled/manifests/blitz_api.json`
- `common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart`
- `common/lib/src/services/dashboard/sources/in_process_adapter_source.dart`
  (unused once `BlitzApiBridgeSource` is gone)
- `common/lib/src/services/blitz_api/blitz_api_client.dart`
- `common/lib/src/services/blitz_api/sse_event.dart`
- The `services.bitcoind.zmqpubrawblock` backstop in our wrapper module
  moves into the plugin's `module.nix` (where it belongs — only blitz-api
  needs it).
- The Phase 1 postStart hook for `.login-password` perms also moves into
  the plugin's `module.nix`.

`BitcoinNetwork` enum stays in core (used by install wizard, dashboard
chrome, Nix template — not blitz-api-specific). Phase 1's `system-stats`
streamer stays in core.

## What gets added to core

- `requires`, `module`, `streamers` fields added to `PluginManifest` model
  - parser.
- **Install consent prompt** in TUI's plugin install flow (text per
  "Install consent + trust contract" section above), shown before
  `git clone`.
- **Marker-driven install flow**: clone to `~/nixblitz/plugins/<id>/`,
  write `.nixblitz-installed.json`, regenerate `plugins.list` from all
  markers; never trust pre-existing `plugins.list` content.
- **`plugins.list` orphan detection**: when regenerating, log a warn-level
  message if the previous file had paths without corresponding markers
  ("attempted unauthorized plugin import: <path>").
- Plugin enable/disable flow flips a `disabled: true` flag in the marker;
  TUI filters disabled markers when regenerating `plugins.list`.
- `tileSourceRegistryProvider` reads installed-and-enabled plugin
  manifests' `streamers` arrays, instantiates `StreamerSubprocessSource`
  per entry. Each source's `providedTileIds` is populated from the
  manifest's `tile_ids`.
- **Tile-event boundary enforcement**: glue listening on each source's
  events stream filters out events whose `tileId` is outside the source's
  declared `providedTileIds`; drops + warn-logs.
- Dashboard banner for missing-dep plugins.
- **Dependency-resolution prompts auto-fill the URL** from `requires[].url`
  — never operator-typed in this prompt — to prevent typosquat.

## What's UNTOUCHED

- Bitcoin / Lightning tile manifests in core. They keep getting fed by the
  blitz-api plugin's streamer.
- system-stats streamer (Hardware + System tiles).
- All Phase 1-3 dashboard / config / UI infrastructure.
- bitcoind / lnd / cln / blitz-web Nix modules.
- The v18 `app_configs` JSON shape.

## Migration / compatibility

**For the operator (you, during development):**

1. New TUI binary deploys (via standard `nix flake update nixblitz` +
   rebuild flow).
2. Rebuild fails because `templates/modules/apps/blitz-api.nix` is gone
   from core but config has `app_configs.blitz_api.enabled = true`.
3. Operator opens TUI → Configure → Plugins → install
   blitz-api plugin from `forge.f44.fyi/f44/nixblitz-plugin-blitz-api`.
4. Plugin installs, `plugins.list` gets a line, prompt confirms.
5. Apply → rebuild succeeds, blitz-api back up.

This is acceptable during development. Post-release blitz-api was never a
core feature, so this scenario doesn't occur.

**For test installs:** scaffold a fresh `~/nixblitz/` from the new TUI.
config has `app_configs.blitz_api.enabled = false` by default. Operator
optionally installs the plugin via TUI; rebuild works either way.

## Testing strategy

Phase 4's test surface spans two repos:

**In nixblitz-plugin-blitz-api (the plugin repo):**

- `plugin.json` parses correctly (against core's `PluginManifest` parser
  shipped with the binary).
- `streamers/blitz_api_stream.py` has unit tests for SSE event parsing +
  routing (using a mock SSE source).
- `module.nix` is importable as a NixOS module (`nix-instantiate --parse`).
- One end-to-end VM test: blitz-api running, plugin streamer connected,
  bitcoin tile receives at least one event. (Optional for Phase 4; gates on
  the test-matrix infrastructure landed via issue #26.)

**In core (nixblitz_ng):**

- `PluginManifest.fromJson` round-trips with the new fields (requires,
  module, streamers).
- `requires` parsing: app type, plugin type, mixed, malformed.
- Dependency check function: missing app dep, missing plugin dep,
  satisfied, no deps.
- `tileSourceRegistryProvider` instantiates `StreamerSubprocessSource`
  for plugin streamers (with a mock plugin manifest).

**Cross-cutting smoke** (manual, on the Pi):

- Install plugin → rebuild → blitz-api running → bitcoin/lightning tiles
  populating.
- Disable plugin → rebuild → blitz-api stopped → tiles render "no source"
  footer.
- Uninstall plugin → rebuild → plugin directory + plugins.list line gone.
- Toggle bitcoind off (config) → blitz-api plugin shows "missing dep" in
  configure view; its module is excluded from rebuild.

## Verification

```bash
just test
just analyze
just format
```

Plus a Pi 5 deploy + manual smoke for the install/disable/uninstall flows.

## Phasing handoff

| Phase               | Work                                                                                                                                                                            | Depends on |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| **4** _(this spec)_ | Move blitz-api into a plugin; ship subprocess streamer; depend on still-core bitcoind                                                                                           | 1, 2, 3    |
| 5                   | Move blitz-web into a plugin (mostly Nix; almost no Dart-side change)                                                                                                           | 2, 3, 4    |
| 6                   | Move lnd, cln into plugins; install wizard's `lightning_backend` capability now finds plugin-shipped manifests; bitcoin/lightning tile manifests follow lnd/cln out of core     | 2, 3, 4    |
| later               | Move bitcoind into a plugin (last; transitively depended on by every LN/api plugin). blitz-api's `requires` switches from `{type: "app"}` to `{type: "plugin", url: ...}` here. | 4, 5, 6    |

After Phase 4 alone:

- Real plugin running in production (the canonical example).
- Plugin lifecycle exercised end-to-end (install, enable, dep check, streamer subprocess, uninstall).
- Core 2200 lines lighter (deletions: BlitzApiBridgeSource, InProcessAdapterSource, BlitzApiClient, sse_event, blitz-api Nix module, bundled blitz_api.json).
- Streamer language precedent set (Python).

## Decisions (locked in 2026-05-06)

1. **Plugin lives in a separate repo** at
   `forge.f44.fyi/f44/nixblitz-plugin-blitz-api`. Dogfoods the install
   lifecycle.
2. **Streamer is Python.** SSE + HTTP + JSON via `requests` +
   `sseclient-py`. Existing prior art in `examples_redesign/blitz_api/`.
3. **Dependencies declared in plugin manifest** as
   `requires: [{type: "app" | "plugin", id | url: ...}]`. URL-based for
   plugin-to-plugin, since plugin URL is the canonical unique identifier
   (multiple bitcoind variants with different tradeoffs are possible
   long-term). Phase 4 uses `type: "app"` for the still-core bitcoind dep.
4. **No automatic migration** for existing installs with
   `blitz_api.enabled = true`. Operator manually installs the plugin; hard-
   fail rebuild is acceptable during development.
5. **First-party plugins** treated identically to third-party — same
   install consent, same trust prompt. No URL allowlist.
6. **Bitcoin / Lightning tile manifests stay in core for Phase 4.**
   Migrated to bitcoind / lnd / cln plugins in their respective extraction
   phases.
7. **Plugin module discovery via `~/nixblitz/plugins.list`** — flat text
   file read by `installed.nix` at Nix eval time. Simpler than
   flake-input juggling for plugins that are local checkouts.
8. **`plugins.list` is TUI-managed, regenerated from marker files**
   (`~/nixblitz/plugins/<id>/.nixblitz-installed.json`). The markers are
   the authoritative install record; `plugins.list` is a derived artifact.
   Orphan paths in `plugins.list` (no corresponding marker) are dropped on
   regen and logged. Catches a malicious already-installed plugin that
   tries to sneak unapproved imports into the rebuild by appending to
   `plugins.list` directly.
9. **`streamers[].tile_ids` is authoritative, not advisory.** The glue
   listening on each source's events stream drops + warn-logs events whose
   `tile` field isn't in the source's declared tile_ids. Prevents
   cross-plugin tile-event spoofing.
10. **Install consent prompt enumerates privilege positions**, not
    theoretical attack surfaces. Operator sees: "this plugin runs as root
    via NixOS module activation, and as the operator user via subprocess
    streamer." No security theatre. Dependency-resolution prompts auto-fill
    the URL from `requires[].url` to prevent typosquat.

## Out of this phase, tracked separately

- **Plugin update security** (pin to revision, signer verification on
  update) — separate concern from initial install consent. Tracked as a
  follow-up issue; relevant to the disaster-recovery work in #26 too.
