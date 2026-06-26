# Disable plugin → all functionality halted — design

Date: 2026-06-27
Status: approved (design)

## Goal

When an operator sets a plugin's `enabled = false` (the Configure toggle) and
applies, the plugin is **fully halted**: its daemon stops, its network state is
cleanly torn down _first_ (DNS/routes released, so the rebuild's own network
steps don't hang), its dashboard tile disappears, and its actions are no longer
offered — on **every** rebuild path. Re-enabling (toggle back to `true` + apply)
restores it. Applies to the network plugins that ship a teardown today
(Tailscale, NetBird); the mechanism is general and other plugins can opt in with
a one-line gate.

## Context — what obeys `enabled` today

The Configure `enabled` bool writes `config.json` `app_configs.<id>.enabled`
(`configure_view.dart` Enter-on-bool → `setAppOption`; persisted on Apply). But
almost nothing honors it, so "disable" is currently a near-no-op:

| Surface                   | Obeys `enabled=false`? | Where                                                                         |
| ------------------------- | ---------------------- | ----------------------------------------------------------------------------- |
| Config write              | ✅                     | `nixblitz_config.dart` `setAppOption` / `isAppEnabled`                        |
| Dashboard **streamers**   | ✅                     | `dashboard_provider.dart:46-78` skips `!config.isAppEnabled(id)`              |
| **Service/daemon**        | ❌                     | tailscale/netbird `plugin.nix` set `services.X.enable = true` unconditionally |
| Dashboard **tile poller** | ❌                     | `plugin_dashboard_service.dart` `_reconcile()` skips only `marker.disabled`   |
| **Actions** menu          | ❌                     | `configure_view.dart` `_actionsFor` returns all actions regardless            |
| **Teardown** (`down`)     | ❌                     | fires only on the uninstall edge (plugins.list diff), and only via Apply      |

Precedent for making it real: the wizard apps gate on
`appEnabled = initialized && (app_configs.<id>.enabled or false)`
(`templates/hosts/installed.nix:16-29`), e.g.
`features.system.testLnd.enable = (appEnabled "bitcoind") && …`. Plugins already
receive their config slice as the outer-stage closure arg `pluginCfg` (so
`pluginCfg.enabled` is available; `templates/flake.nix:132-147`), and also as
`config.nixblitz.appConfigs.<id>.enabled`.

## Design decisions

- **Halt by gating `services.X.enable` on config** (not by dropping from
  `plugins.list`). The plugin stays installed (config preserved), the rebuild
  stops the daemon, re-enable is a toggle flip. This makes the existing
  `enabled` field authoritative — the wizard-app model — instead of vestigial.
- **Full halt:** service stop + teardown-on-disable across all rebuild paths +
  tile poller stop + actions hidden.
- Teardown still runs the daemon's **non-destructive** verb
  (`tailscale down` / `netbird down`) _before_ the rebuild, so the resolver is
  released gracefully rather than killed mid-rebuild.

## Components

### 1. Gate the service on `enabled` (`nixblitz_official_plugins` — tailscale, netbird)

- `tailscale/plugin.nix`: `services.tailscale.enable = pluginCfg.enabled or false;`
  (was unconditional `true`). Keep `useRoutingFeatures` logic.
- `netbird/plugin.nix`: `services.netbird.enable = pluginCfg.enabled or false;`
  (was unconditional `true`).
- Leave the connect/down/leave units and the tile/version scripts defined
  unconditionally — they are inert oneshots when the daemon is off, and the
  `*-down.service` unit must stay present so the pre-rebuild teardown can run it
  on the still-live old system.

**Behavior change (intended):** `enabled` defaults to `false` in each plugin's
`config_schema`, so after this a freshly-installed VPN plugin is **off until the
operator enables it** (opt-in). Document in each plugin's README.

### 2. Disable-edge detection (`common`)

Add to `plugin_teardown.dart` a pure detector:

```dart
Set<String> disabledPluginIds({
  required NixblitzConfig? committed,
  required NixblitzConfig? current,
});
```

Returns ids enabled in `committed` (`isAppEnabled` true) but not in `current`.
Null-safe (either null → empty set). The pre-rebuild step teardown set is
`removedPluginIds(...) ∪ disabledPluginIds(...)`, deduped. Both edges resolve the
teardown from the **committed** manifest (uniform: uninstall hard-deletes the
on-disk copy; disable keeps it — committed works for both).

### 3. Shared pre-rebuild teardown step (`common` orchestrator; `tui` + `cli` call sites)

Lift the detect→resolve→run logic out of `apply_view._continueApply` into a
common orchestrator so every rebuild path runs it:

```dart
// common/lib/src/services/plugin/plugin_teardown_runner.dart
class PluginTeardownRunner {
  PluginTeardownRunner({required this.git, required this.runner});
  final GitService git;
  final PluginActionRunner runner;

  /// Detect plugins removed-from-list ∪ toggled-disabled this rebuild,
  /// resolve their teardown actions from the committed manifests, and run
  /// each on the live system. Best-effort: any failure is emitted + logged
  /// and never throws. [emit] receives human-readable progress/output lines
  /// (apply → _append; cli → stdout.writeln).
  Future<void> runPending({
    required String baseDir,
    required void Function(String line) emit,
  }) async { … }
}
```

Internally it reads, via `git` + the working tree under `baseDir`:
committed/current `plugins.list`, committed/current `config.json` (parsed to
`NixblitzConfig`), and each removed-or-disabled plugin's committed
`plugins/<id>/plugin.json`. It reuses the existing `resolveTeardowns(readManifest)`
shape (manifest source = `git.readCommittedFile`).

Call sites:

- `apply_view._continueApply`: replace the inline teardown block with
  `await PluginTeardownRunner(...).runPending(baseDir: …, emit: _append)`, in the
  same slot — **before** the "Apply pending changes" commit's network steps.
  (Capture-before-commit still holds: the orchestrator reads HEAD, so it must run
  before `git.commitAll`.)
- `update_cli._runRebuild`: call `runPending(baseDir, emit: stdout.writeln)`
  before `Process.start('sudo', ['nixos-rebuild', …])`. The CLI path never
  commits, so committed (HEAD) still holds the pre-change list/config for the
  diff.

This closes the `nixblitz update {tui,plugins,system}` bypass and moves business
logic out of the view (architecture split).

### 4. Tile hidden + poller stopped on disable (`tui` + `common`)

The dashboard `PluginTile` (the `dashboard`-field tile) is **rendered** from
`installedPluginsProvider` in `dashboard_view.dart._pluginTiles()` (≈ lines
39-64), which is _not_ gated on `enabled` — so a disabled plugin's tile stays on
screen (showing stale/"loading…") even with its poller stopped. Two changes,
because rendering and polling are separate sources:

- **Hide the tile (the visible change):** in `dashboard_view.dart._pluginTiles()`,
  skip a plugin whose `!config.isAppEnabled(m.id)` (config is already available in
  `build`). The tile disappears entirely. Do **not** gate
  `installedPluginsProvider` itself — it also feeds the Configure view, actions,
  and the registry, so a disabled plugin must stay discoverable there to be
  re-enabled. The filter belongs in the dashboard tile builder only. (The
  `tileManifests` DSL-tile path is already gated on `isAppEnabled` in
  `dashboard_provider.dart:156`, so it needs no change.)
- **Stop the poller (avoid wasted work):** `plugin_dashboard_service.dart`
  `_reconcile()` currently skips only `marker.disabled`; also skip plugins where
  the current config's `isAppEnabled(id)` is false (mirrors the streamer gate).
  The service must observe config — re-reconcile when config changes. This stops
  a poller hammering a daemon NixOS has stopped; the tile's disappearance is done
  by the view filter above.

### 5. Actions hidden when disabled (`tui`)

`configure_view.dart` `_actionsFor(ctx, appId)`: return `const []` when
`!ctx.read(configProvider).value!.isAppEnabled(appId)` (guard for null config →
treat as not-enabled → no actions). No Connect/Down/Leave rows render for a
halted plugin. The teardown `down` action is system-run (orchestrator), not via
this menu, so it is unaffected.

## Data flow (disable Tailscale)

1. Operator toggles Configure → Tailscale → `enabled = false`. `config.json`
   `app_configs.tailscale.enabled = false` (live, persisted).
2. Immediately: the dashboard tile disappears (`_pluginTiles` filter), its poller
   stops (reconcile sees `enabled=false`), streamers were already gated, and the
   actions menu renders empty.
3. Operator Applies (or runs a CLI `update` rebuild).
4. Pre-rebuild step: committed config has `enabled=true`, current `false` →
   `disabledPluginIds = {tailscale}` → resolve `down` from the committed manifest
   → run `tailscale-down.service` (`tailscale down`) on the live system → DNS /
   routes released.
5. Rebuild: `services.tailscale.enable = false` → tailscaled stopped/removed
   cleanly (resolver already clean — no hang).
6. Re-enable: toggle back to `true` + apply → daemon returns; operator runs
   Connect.

## Error handling

- Teardown is best-effort (unchanged): missing/failed/timed-out teardown is
  emitted + logged and never blocks the rebuild.
- Config/list parse failures in detection → treat as "no edge", log, proceed.
- Null current/committed config → empty disable set (fail safe: no spurious
  teardowns).

## Testing

- **common unit** — `disabledPluginIds`: enabled→disabled detected; unchanged →
  empty; newly-enabled (false→true) not flagged; both-null → empty; union with
  `removedPluginIds` dedupes a plugin that is both uninstalled and was enabled.
- **common unit** — `PluginTeardownRunner.runPending` with fakes (fake git
  readers + fake `PluginActionRunner`): runs teardowns for both edges, emits
  lines, is non-fatal when a run fails.
- **plugin eval** — tailscale & netbird: `pluginCfg.enabled = false` →
  `services.X.enable == false`; `= true` → `true` (cross-arch `nix eval`).
- **tui unit** — `_actionsFor` returns `[]` when the plugin is disabled,
  non-empty when enabled.
- **common/tui unit** — `PluginDashboardService` does not register a poller for a
  disabled plugin; `dashboard_view._pluginTiles()` omits a disabled plugin's tile
  (and still includes it when enabled).
- **Manual** — disable Tailscale → Apply → tile gone, actions gone,
  `> tearing down tailscale: Disconnect` + `tailscale down` before the
  flake-lock/rebuild, daemon stopped; repeat via `nixblitz update system` to
  confirm the CLI path also tears down.

## Repos touched

- **Main repo:** `disabledPluginIds` + the `PluginTeardownRunner` orchestrator
  (`common`), the two call-site swaps in `apply_view` + `update_cli` (`tui`),
  the `dashboard_view._pluginTiles()` tile filter (`tui`) +
  `PluginDashboardService` poller gate (`common`), `_actionsFor` gate (`tui`),
  tests.
- **`nixblitz_official_plugins`:** tailscale + netbird `enable` gating + README
  notes.

## Out of scope

- Gating `services.X.enable` on `enabled` for non-network plugins (bitcoind/lnd/
  cln/electrs/lnbits/blitz-\*). The mechanism is general; those adopt the same
  one-line gate when desired.
- The unwired `PluginService.disable()/enable()` marker path and `plugins.list`
  drop-on-disable — superseded by the config-gating model; left as-is.
- `initialized &&` in the plugin enable gate. Plugins are installed post-init;
  `pluginCfg.enabled` alone is the operator control. (Revisit only if a plugin
  must be inert during the install bootstrap.)
