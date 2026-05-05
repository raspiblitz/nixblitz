# Dashboard DSL & Streamer Protocol — Phase 1 Design

**Date:** 2026-05-05
**Status:** Draft
**Tracking:** Phase 1 of "extract bitcoind/lnd/cln/blitz-api/blitz-web into plugins"

## Goal

Replace the dashboard's hand-coded tile widgets with a **generic, manifest-driven
renderer** fed by **JSON-lines events from named tile providers**. After Phase 1, core
contains zero Dart code that anticipates any specific plugin: every tile is described
by a manifest, painted by one generic renderer, and supplied data by a `TileEventSource`
implementation. Bundled core tile providers conform to the same protocol any future
plugin will use — they're just shipped in the binary for now and lift out into actual
plugins in later phases.

This phase also detaches hardware and system metrics from blitz-api: a small
**`system-stats`** streamer reads `procfs` / `sysfs` directly so the base system has a
populated dashboard with zero plugins (and zero blitz-api) installed.

## Non-goals (deferred)

- **Plugin-defined custom layout primitives.** Phase 1's primitive registry is closed
  (six primitives, listed below). Letting plugins register their own widget primitives
  is a separate phase once the base set is proven.
- **Manifest-driven SSE-or-similar source DSL.** Plugins that need protocol-specific
  ingestion (SSE, gRPC, IPC) ship a streamer process. Core does not parse SSE or speak
  HTTP-on-behalf-of-plugins.
- **Generalising `NixblitzConfig`.** That's Phase 2.
- **Generalising the Configure view.** That's Phase 3.
- **Moving blitz-api / blitz-web Nix modules into actual plugins.** That's Phase 4–5.
  Phase 1 keeps both Nix modules in core; the Dart-side data path is what changes.
- **Hot-reloading manifests at runtime.** Manifests are loaded once at TUI startup.
  Changing them requires a TUI restart (matches today's tile-code reload story).
- **Socket-based IPC.** The streamer source contract is JSON-lines on stdout in
  Phase 1. The `TileEventSource` interface is shaped so a unix-socket source can drop
  in later without touching the renderer or the manifest schema.

## Architecture

### After Phase 1

```
                              ┌────────────────────────────┐
                              │  Dashboard chrome (always) │
                              │  hostname · platform · net │
                              └────────────────────────────┘

  ┌── TileEventSourceRegistry ─────────────────────────────────────────────────┐
  │                                                                            │
  │   ┌── system-stats source ─────────┐   ┌── blitz-api-bridge source ─────┐ │
  │   │  StreamerSubprocessSource      │   │  InProcessAdapterSource        │ │
  │   │  spawns: nixblitz streamer     │   │  wraps existing SSE consumer   │ │
  │   │           system-stats         │   │                                │ │
  │   │  reads stdout JSON-lines       │   │  emits TileEvents directly     │ │
  │   │  emits TileEvents              │   │                                │ │
  │   └────────┬────────────┬──────────┘   └──────────┬──────────┬──────────┘ │
  │            │            │                          │          │            │
  │       tile=hardware  tile=system           tile=bitcoin   tile=lightning   │
  └────────────┼────────────┼──────────────────────────┼──────────┼────────────┘
               │            │                          │          │
               ▼            ▼                          ▼          ▼
                       TileDataCache (Map<tileId, Map<String, dynamic>>)
                                          │
                                          ▼
              ┌───────────────────────────────────────────────────┐
              │  TileRenderer (one widget per tile manifest)       │
              │  reads cache[tileId] + manifest layout DSL         │
              │  paints Row / ProgressBar / StatusRow / Section /  │
              │  Spacer / Footer primitives                        │
              └───────────────────────────────────────────────────┘
```

Three things to notice:

1. **No Dart-coded tile widgets.** The four hand-written tiles (`bitcoin_tile.dart`
   etc.) are deleted. The single `TileRenderer` paints whatever its manifest tells it.
2. **No typed snapshot classes.** `BtcSnapshot`, `LnSnapshot`, `HardwareSnapshot`,
   `SystemSnapshot` are deleted. Tile data is `Map<String, dynamic>` parsed from
   streamer JSON; the manifest's binding language picks fields out by key.
3. **Sources don't know about tiles' shapes.** A source emits `TileEvent(tileId, data)`
   tuples. Routing to renderers happens through the `TileDataCache`. Multiple sources
   can feed different tiles without coordinating.

## Tile manifest schema

A tile manifest is a JSON object:

```jsonc
{
  "id":           "bitcoin",            // unique within the dashboard
  "title":        "Bitcoin",
  "accent_color": "#f7931a",            // hex, or semantic name (see Colors)
  "layout":       [ /* primitive nodes, see below */ ],
  "footer":       { /* optional footer node */ }
}
```

A *layout* is an ordered list of **primitive nodes**. A primitive node is a JSON
object with exactly one key — the primitive's name — whose value is the primitive's
args map. This shape is borrowed from your SSR snippet's registry pattern.

```jsonc
[
  { "Row":         { "label": "Peers", "value": { "$data": "peers" } } },
  { "ProgressBar": { "label": "Sync",  "value": { "$data": "verification_progress" }, "format": "percent" } },
  { "Spacer":      { "height": 1 } },
  { "StatusRow":   { "label": "Network", "value": { "$data": "chain_name" }, "color": { "$data": "chain_color" } } }
]
```

### Primitive registry (Phase 1)

Six primitives, each typed. The "Where" column says where each primitive may appear:
`layout` = the tile body's layout list, `footer` = the optional `footer:` block at
the bottom of the manifest, `children` = nested inside a `Section`. Using a primitive
outside its allowed positions is a parse error.

| Primitive    | Args (all optional unless ✱)                                                      | Where                  | Purpose                                                          |
|--------------|----------------------------------------------------------------------------------|------------------------|------------------------------------------------------------------|
| `Row`        | `label✱`, `value✱`, `value_color`                                                 | layout, children       | One line, `label: value`. Most common.                          |
| `StatusRow`  | `label✱`, `value✱`, `color✱`                                                      | layout, children       | Like `Row` but value is rendered as a coloured pill.            |
| `ProgressBar`| `value✱`, `label`, `max` (default 1.0), `format` (`percent`\|`fraction`\|`bytes`), `color` | layout, children       | Horizontal bar. Width is tile-content-width minus padding. |
| `Section`    | `title`, `children✱`                                                              | layout                 | Group with optional header. Children are other primitives.      |
| `Spacer`     | `height` (default 1, in cells)                                                    | layout, children       | Vertical gap.                                                    |
| `Footer`     | `text✱`, `color`                                                                  | footer                 | Tile footer (one line below layout). Only legal inside `footer:`. |

Args may be **literal values** (strings, numbers, booleans), **data references** (see
binding language below), or — for `children` — nested primitive nodes. The renderer
walks the tree, resolves references against current data, and paints. Unknown
primitives = render error inside the tile (red text, "unknown primitive: X"); does not
crash the dashboard.

### Footer

`footer` is a single node, either a `Footer` primitive or a `$status` directive that
resolves to one:

```jsonc
"footer": {
  "$status": {
    "$on": "sync_state",
    "synced":  { "text": "synced",            "color": "ok"    },
    "syncing": { "text": "syncing {sync_pct}%", "color": "warn"  },
    "stalled": { "text": "stalled",           "color": "error" }
  }
}
```

Resolves to a `Footer` primitive whose args are picked from the matching case based on
the value of `data["sync_state"]`.

### Colors

Semantic names map to nocterm theme colors at render time:

| Name      | Use                                                  |
|-----------|------------------------------------------------------|
| `ok`      | Synced, healthy, running                             |
| `warn`    | Syncing, degraded, slow                              |
| `error`   | Failed, unreachable, stalled                         |
| `accent`  | Tile's `accent_color`                                |
| `muted`   | Secondary info (timestamps, fine print)              |
| `default` | Default text color from theme                        |

Hex values (`#rrggbb`) are accepted everywhere a color is expected and bypass the
theme. Phase 1 uses semantic names in bundled manifests; hex stays available for plugin
authors who want explicit colors.

## Data binding language

A handful of `$`-prefixed directives pluck values from the per-tile data map. All
directives evaluate against `cache[tileId]` (which is a `Map<String, dynamic>`).

| Directive    | Args                              | Resolves to                                                          |
|--------------|-----------------------------------|----------------------------------------------------------------------|
| `$data`      | string key                        | `data[key]` (any type; renderer stringifies if needed)               |
| `$bytes`     | string key                        | `data[key]` formatted as a human-readable byte size (e.g. `4.2 GB`) |
| `$duration`  | string key                        | `data[key]` (seconds) formatted as `1d 2h 3m`                        |
| `$pct`       | string key                        | `data[key]` (0.0–1.0) formatted as `87%`                             |
| `$truncate`  | `{ "key": string, "len": int }`   | `data[key]` truncated with `…` to `len` chars                        |
| `$format`    | template string                   | `"{a}/{b}"` — keys in braces resolve against data; literals pass-through |
| `$status`    | `{ "$on": key, <case>: <node> }`  | Selects a node based on `data[key]`'s string value                   |

Missing keys render as a placeholder (`—`) and log once per (tileId, key) pair so we
don't drown the log on a slow source.

## `TileEventSource` contract

```dart
class TileEvent {
  final String tileId;
  final Map<String, dynamic> data;   // partial — merges into cache
  final DateTime ts;                 // for staleness display in footer
}

abstract class TileEventSource {
  String get id;                     // 'system-stats', 'blitz-api-bridge', etc.
  Set<String> get providedTileIds;   // ['hardware', 'system']

  Future<void> start();              // begin emitting
  Stream<TileEvent> get events;      // broadcast; multiple listeners OK
  Future<void> dispose();
}
```

Sources emit `TileEvent` tuples; the registry forwards each event into the
`TileDataCache` keyed by `tileId`. Errors propagate via `events.addError`; the renderer
shows them in the footer (`error` color) until the next successful event arrives.

`providedTileIds` is advisory metadata used for log lines and the (future) "no source
provides this tile" diagnostic. The cache silently accepts events for unrecognized
tile ids (forward-compat for plugins that ship their own tiles).

### `StreamerSubprocessSource` (the streamer protocol)

Spawns a long-lived child process and parses its stdout as line-delimited JSON. Each
line is a `TileEvent`:

```jsonc
{ "tile": "bitcoin", "data": { "blocks": 871234, "verification_progress": 0.99987 }, "ts": 1746480000000 }
```

Behaviour:

- **Spawn** on `start()`. Working directory is `/var/lib/nixblitz/streamers/<id>/`
  (created if missing). Environment scrubbed to a small allowlist
  (`PATH`, `HOME=/var/lib/nixblitz/streamers/<id>`, `LANG=C.UTF-8`).
- **Stdout** parsed line-by-line; UTF-8, max line length 64 KiB (longer lines
  truncated + warned). Malformed JSON lines logged + dropped.
- **Stderr** drained to the TUI log, prefixed with the source id.
- **Exit** before `dispose()` is called → restart with backoff `[1, 2, 5, 10, 30]`s
  (same shape as `BlitzApiClient`'s reconnect loop). Backoff resets on the first
  successful event after restart.
- **Shutdown** on `dispose()` → SIGTERM, wait 2s, SIGKILL if still alive.
- **Spawn args** passed to constructor: `command` (path) + `args` list. No shell
  involvement.
- **No restart on `dispose()`.**

The interface is shaped so a future `StreamerSocketSource` can implement the same
`TileEventSource` contract reading lines from a unix socket instead. The wire format
(JSON line per event) is reusable.

### `InProcessAdapterSource` (transitional, Phase 1 only)

Runs in-process; emits `TileEvent`s by calling a callback when its underlying state
changes. Used by `blitz-api-bridge` (which wraps the existing SSE consumer code) so
Phase 1 doesn't have to ship a Dart subprocess for blitz-api just to delete it in
Phase 4. The interface matches `TileEventSource` exactly; the only difference is
implementation.

Phase 4 deletes `InProcessAdapterSource` entirely once `blitz-api-bridge` becomes a
plugin-shipped subprocess streamer.

## Bundled tile providers

### `system-stats` (real subprocess streamer)

A small standalone Dart program shipped as a hidden subcommand of the TUI binary:
`nixblitz streamer system-stats`. Reasons for "subcommand of the same binary":

- Single binary; no extra build artifact in the Nix package
- Shares the Dart runtime (no second VM startup overhead at runtime)
- Plugins ship whatever they want; bundled streamers reuse the TUI binary
- The subcommand is `--hidden` from the user-visible help

Reads:

- CPU: `/proc/stat` (deltas across two reads, ~1s apart)
- Memory: `/proc/meminfo`
- Temperature (best-effort): `/sys/class/thermal/thermal_zone0/temp`
- Disk: `df`-equivalent read of `/proc/mounts` + `statvfs` on data mountpoint
- Uptime: `/proc/uptime`
- Service health: `systemctl is-active <unit>` polled at low rate, list of units from
  the manifest's tile params (so `blitz-api`, `blitz-web`, `nginx`, `redis` etc. land
  in the system tile when they're configured to be present)

Emits two tile events:

- `tile=hardware` — every 2s — CPU%, memory used/total, temperature, disk used/total
- `tile=system`   — every 5s — uptime, services map

Bundled tile manifests:

- `hardware.json` — replaces today's hardware tile
- `system.json`   — partially replaces today's system tile (uptime + service-health rows)

### `blitz-api-bridge` (in-process adapter, transitional)

Wraps the existing SSE consumer code (`BlitzApiClient`, `sse_event.dart`, the parsing
logic currently in `ApiDashboardSource`). Translates SSE events into `TileEvent`s for
two tiles:

- `tile=bitcoin` — driven by `btc_info` + `btc_mempool_status` events
- `tile=lightning` — driven by `wallet_balance` + `ln_info` events

Bundled tile manifests:

- `bitcoin.json` — replaces today's bitcoin tile
- `lightning.json` — replaces today's lightning tile

Activation gate: still `config.blitzApi.enabled` (Phase 1 doesn't change this).
Phase 4 will rip the bridge out, ship the same SSE-consumer logic as a plugin
subprocess streamer, and drop the gate to "blitz-api plugin installed."

## Dashboard chrome

Above the tile area, a fixed two-line header:

```
nixblitz-pi5  ·  raspi5  ·  mainnet
uptime ?h ?m  ·  applied 2h ago
```

Line 1 is config-derived (hostname, platform, network). Always rendered, never empty.
Line 2 mixes data the cache happens to have available — uptime from system-stats once
that tile event lands; "applied N ago" from existing `git_provider`. Falls back to
config-only state on cold start.

This chrome is the *only* dashboard concern that knows about specific data fields. It's
hardcoded because (a) hostname/platform/network are always knowable from config alone,
(b) the chrome's role is identity, not metric display.

## Riverpod wiring

```dart
final tileSourceRegistryProvider = Provider<TileEventSourceRegistry>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final reg = TileEventSourceRegistry();

  // system-stats: always on. No dependency on config flags.
  reg.register(StreamerSubprocessSource(
    id: 'system-stats',
    command: Platform.resolvedExecutable,   // the TUI binary itself
    args: ['streamer', 'system-stats'],
  ));

  // blitz-api-bridge: gated on config (Phase 4 swaps to plugin presence).
  if (config != null && config.blitzApi.enabled) {
    reg.register(BlitzApiBridgeSource());
  }

  unawaited(reg.startAll());
  ref.onDispose(() => reg.disposeAll());
  return reg;
});

final tileDataCacheProvider = Provider<TileDataCache>((ref) {
  final reg = ref.watch(tileSourceRegistryProvider);
  final cache = TileDataCache();
  for (final src in reg.sources) {
    src.events.listen(cache.apply, onError: cache.applyError);
  }
  ref.onDispose(cache.dispose);
  return cache;
});

final tileManifestsProvider = Provider<List<TileManifest>>((_) => bundledManifests);

final tileSnapshotProvider = StreamProvider.family<TileSnapshot, String>((ref, tileId) {
  final cache = ref.watch(tileDataCacheProvider);
  return cache.streamFor(tileId);   // emits whenever data[tileId] changes
});
```

`TileSnapshot` is a small immutable record:

```dart
class TileSnapshot {
  final Map<String, dynamic> data;   // empty on cold start
  final Object? lastError;           // null when healthy
  final DateTime? lastEventTs;       // null until the first event
  const TileSnapshot({this.data = const {}, this.lastError, this.lastEventTs});
}
```

`TileDataCache` holds one `TileSnapshot` per tile id plus a per-tile broadcast stream.
`apply(event)` merges the event's `data` into the snapshot's data map, updates
`lastEventTs`, clears `lastError`, and pushes the new snapshot on the stream.
`applyError(tileId, e)` sets `lastError` without touching `data` (so the renderer
keeps showing the last-known values with an error footer).

The single dashboard view widget walks `tileManifestsProvider`, instantiates one
`TileRenderer(manifest: m)` per entry, and the renderer subscribes to
`tileSnapshotProvider(m.id)`.

## File-level changes

**New:**

- `common/lib/src/services/dashboard/tile_event.dart` — `TileEvent` data class
- `common/lib/src/services/dashboard/tile_event_source.dart` — abstract interface
- `common/lib/src/services/dashboard/tile_event_source_registry.dart` — registry
- `common/lib/src/services/dashboard/tile_data_cache.dart` — keyed cache + per-tile streams
- `common/lib/src/services/dashboard/sources/streamer_subprocess_source.dart` — subprocess runner
- `common/lib/src/services/dashboard/sources/in_process_adapter_source.dart` — transitional base class
- `common/lib/src/services/dashboard/sources/blitz_api_bridge_source.dart` — wraps existing SSE consumer
- `common/lib/src/services/dashboard/dsl/tile_manifest.dart` — manifest model + parser
- `common/lib/src/services/dashboard/dsl/primitives.dart` — `Row`, `StatusRow`, `ProgressBar`, `Section`, `Spacer`, `Footer` typed classes
- `common/lib/src/services/dashboard/dsl/binding_resolver.dart` — `$data`, `$bytes`, `$duration`, `$pct`, `$truncate`, `$format`, `$status` directive evaluation
- `common/lib/src/services/dashboard/bundled/manifests/bitcoin.json`
- `common/lib/src/services/dashboard/bundled/manifests/lightning.json`
- `common/lib/src/services/dashboard/bundled/manifests/hardware.json`
- `common/lib/src/services/dashboard/bundled/manifests/system.json`
- `tui/lib/src/ui/views/dashboard/tile_renderer.dart` — one widget paints any manifest
- `tui/lib/src/ui/views/dashboard/dashboard_chrome.dart` — identity header
- `tui/bin/streamer_main.dart` (or wired into existing `nixblitz.dart` argv dispatch) — `nixblitz streamer <name>` subcommand entry
- `tui/lib/src/streamers/system_stats_streamer.dart` — the procfs/sysfs reader

**Modified:**

- `tui/lib/src/ui/views/dashboard_view.dart` — replace four hardcoded tiles with a
  list-of-manifests + `TileRenderer` per manifest + chrome
- `common/lib/src/providers/dashboard_provider.dart` — replace today's
  `dashboardDataSourceProvider` + four snapshot providers with the wiring shown above
- `tui/bin/nixblitz.dart` — argv dispatch: if `argv[0] == "streamer"`, route to
  `streamer_main.dart` and skip TUI startup
- `common/lib/src/services/blitz_api/` — `BlitzApiClient` and `sse_event.dart` stay;
  the class loses no behaviour, just gains a new caller (`BlitzApiBridgeSource`)

**Deleted:**

- `common/lib/src/services/dashboard/dashboard_data_source.dart` — entire file
  (`DashboardDataSource` interface + `NullDashboardSource`)
- `common/lib/src/services/dashboard/api_dashboard_source.dart` — entire file
  (logic moves into `BlitzApiBridgeSource`, snapshot-class construction goes away)
- `common/lib/src/models/dashboard/snapshots.dart` — entire file (`SystemSnapshot`,
  `HardwareSnapshot`, `BtcSnapshot`, `LnSnapshot` classes)
- `tui/lib/src/ui/views/dashboard/bitcoin_tile.dart`
- `tui/lib/src/ui/views/dashboard/lightning_tile.dart`
- `tui/lib/src/ui/views/dashboard/hardware_tile.dart`
- `tui/lib/src/ui/views/dashboard/system_tile.dart`

## Testing strategy

### DSL tests

- `tile_manifest_test.dart` — parse round-trip for the four bundled manifests, plus
  a corpus of malformed manifests that should produce friendly error messages
- `binding_resolver_test.dart` — every directive (`$data`, `$bytes`, `$duration`,
  `$pct`, `$truncate`, `$format`, `$status`) with hits, misses, type-mismatches
- `primitives_test.dart` — each primitive's args validation; unknown primitive name
  surfaces an in-tile error

### Source tests

- `streamer_subprocess_source_test.dart` — spawn a fixture streamer (small Dart
  program in test/fixtures/) that emits a known sequence of JSON lines; verify
  events match. Verify malformed lines are dropped + logged. Verify SIGTERM on
  dispose.
- `streamer_subprocess_source_restart_test.dart` — fixture streamer that exits after
  N events; verify restart with backoff; verify backoff resets after the first event
  post-restart
- `in_process_adapter_source_test.dart` — register, pump events through a fake
  callback, verify `events` stream + dispose cleanup
- `blitz_api_bridge_source_test.dart` — mock `BlitzApiClient`, pump SSE events,
  verify the right tile events come out

### Renderer / cache tests

- `tile_data_cache_test.dart` — apply events from multiple sources, verify
  per-tileId merge semantics; verify error stickiness
- `tile_renderer_test.dart` (in tui/) — golden tests: take the four bundled
  manifests + a fixed data map, render to a buffer, compare against golden output.
  The golden fixtures double as visual-parity proof against the current tiles.

### Manual smoke

On a Pi 5 install:

- Dashboard renders chrome + four tiles populated within seconds of TUI launch.
- With `blitzApi.enabled = false`: chrome + hardware + system tiles still populate
  from the system-stats streamer; bitcoin + lightning tiles render
  "no data — blitz-api off" footers (their manifests are still loaded; the
  bridge source isn't registered, so their cache entries stay empty).
- `pkill nixblitz-streamer` (or whatever the proc name is) then check the system
  tile's footer transitions through "stale" → "reconnecting" → live within ~30s.
- Edit a bundled manifest, restart TUI, verify changes show.

## Verification

```bash
just test
just analyze
just format
```

Plus a Pi 5 (or VM) smoke test confirming visual parity with today's dashboard.
Capture before/after screenshots into `docs/superpowers/specs/2026-05-05-dashboard-pluggability-design/` for the record.

## Phasing handoff

| Phase | Work | Depends on |
|---|---|---|
| **1** *(this spec)* | DSL + streamer protocol + generic renderer + bundled `system-stats` (subprocess) + bundled `blitz-api-bridge` (in-process) | — |
| 2 | Generalise `NixblitzConfig`: drop typed `blitzApi`, `blitzWeb`, `lnd`, `cln` fields → plugin config | 1 |
| 3 | Generalise `configure_view.dart`: dynamic field rendering from plugin manifests | 2 |
| 4 | Move blitz-api Nix module into a plugin; rip out `InProcessAdapterSource`; ship `blitz-api-bridge` as a real subprocess streamer in the plugin | 1, 2 |
| 5 | Move blitz-web Nix module into a plugin (mostly Nix; almost no Dart-side change) | 2 |
| 6 | Move lnd, cln Nix modules into plugins; install wizard discovers LN-capable plugins | 2, 3, 4 |
| later | `system-stats` streamer becomes a "base-system" plugin (or stays bundled — small judgement call) | 4 |

After Phase 1 alone: dashboard is generic, but blitz-api code still lives in core.
After Phase 4: zero plugin-specific code in core.

## Decisions (locked in 2026-05-05)

1. **Bundled manifests are JSON files**, embedded via the existing `EmbeddedTemplates`
   pattern. Parse cost is paid once at TUI launch and is negligible. Easier for plugin
   authors to copy as a starting point.

2. **`system-stats` takes a `--units` arg**, e.g.
   `"streamer_args": ["--units", "blitz-api,blitz-web,nginx,redis"]` in the bundled
   `system.json`. Phase 2/3 can make this list config-driven once `NixblitzConfig` is
   generalised.

3. **Manifest discovery in Phase 1 is a static `bundledManifests` list** in
   `dashboard/bundled/registry.dart`. Phase 4 expands it to also walk installed-plugin
   manifests at startup. The renderer doesn't care about the source — same
   `TileManifest` either way.

4. **Tiles whose source isn't registered render with a "no data — `<source-id>` not
   running" footer** in `muted` color, body empty. Hiding tiles would shift the
   dashboard layout between configs; we don't want that.

5. **Crash-loop UX**: when a streamer's restart count passes 3 within 60 seconds, all
   tiles fed by it footer to "streamer crash-looping — see log" in `error` color.
   Logged at warn-level (not error), since the user already sees it in the UI.

6. **Hex colours pass through unsanitised.** This is a plugin author's concern; we
   don't ship themes, so authors know what to expect. Document "prefer semantic
   names" in the plugin author guide once we write one.
