# Plugin teardown hook — design

Date: 2026-06-26
Status: approved (design)

## Goal

Give plugins a teardown that runs on the live system **before** the rebuild
that removes them, so disabling or uninstalling a plugin that owns system-level
networking returns the node to a clean state. The motivating failure: a Pi 5
`nixos-rebuild` hung silently for minutes because Tailscale was still active and
its MagicDNS had taken over the resolver — every substituter/flake-fetch DNS
lookup stalled. Disabling the Tailscale plugin should have run `tailscale down`
first; today nothing runs before the rebuild rips the module out.

The mechanism is generic (any plugin that hijacks DNS/routes — Tailscale,
NetBird, future WireGuard) and applied to Tailscale and NetBird.

## Context

Current state (from tracing the plugin lifecycle):

- Disabling a plugin flips its marker `disabled` flag
  (`PluginService.disable` → `_setDisabled` in
  `common/lib/src/services/plugin_service.dart`) and regenerates
  `plugins.list` (`plugin_list_regen.dart`), which **drops** disabled/uninstalled
  plugins so their module is no longer imported on the next rebuild. Uninstall
  tombstones the marker (`uninstalled_at`) with the same drop-from-list effect.
- **No lifecycle hook exists** — nothing runs on the live system between the
  state change and the rebuild.
- The Apply flow (`tui/lib/src/ui/views/apply_view.dart` `_continueApply`) runs,
  in order: template auto-rewrite → promote staged updates → `git add -A &&
git commit` → `nix flake lock --update-input nixblitz` → `nixos-rebuild
switch` (via `SystemService.rebuild`). The first two are local; the flake-lock
  and rebuild are the network-heavy steps.
- Actions run through `PluginActionRunner.run(action, {inputs})`
  (`common/lib/src/services/plugin_action_runner.dart`): `unit:` actions via
  `sudo systemctl start --wait`, `command:` actions via `bash -c` as admin, both
  returning `({Stream<String> output, Future<int> exitCode})` with a timeout.
- `PluginManifest` (`common/lib/src/models/plugin/plugin_manifest.dart`) parses
  `actions` into `PluginAction` (`plugin_action.dart`): `label`, `description`,
  `command?`/`unit?`, `confirm`, `timeoutSeconds`, `inputs`.

## Design decisions

- **Pre-rebuild hook (not systemd `ExecStopPost`, not disable-time).**
  `ExecStopPost` fires during switch-to-configuration — after eval + the
  substituter-query phase — so it would clean up _after_ the rebuild already
  hung. Disable-time execution fires before the operator commits to applying and
  the daemon revives until the rebuild anyway. Only a hook in the Apply flow,
  before the network steps, fixes both the dirty state and the hang.
- **Teardown verb is non-destructive (`tailscale down` / `netbird down`).**
  Disconnect and restore DNS but keep the node identity, so re-enabling
  reconnects without a fresh key. A disable may be temporary; `logout`/forget
  stays the manual destructive verb.
- **Declare teardown by referencing an existing action**, not an inline
  command — DRY, and reuses `PluginActionRunner` wholesale.

## Components

### 1. Manifest schema (`common`)

Add an optional top-level manifest field `teardown` (string) = the id of an
action in the same manifest to auto-run when the plugin is removed.

- `PluginManifest`: parse `final String? teardown;` from json `teardown`.
- Validation at parse time (fail loud, `FormatException`):
  - if set, `teardown` must be a key in `actions`;
  - the referenced action's `inputs` must be empty (Apply runs
    non-interactively and cannot prompt).
- The referenced action's `confirm` is **ignored** for auto-teardown — the
  disable/uninstall + Apply is the consent.

### 2. Removal detection (`common`)

A plugin is "being removed" this Apply iff its id is in the **committed**
`plugins.list` (HEAD) but **not** in the current on-disk `plugins.list`. This
edge covers both disable and uninstall and fires exactly once.

- Read committed list via `GitService.readCommittedFile('plugins.list')`,
  current via the on-disk file; the removed set is the difference.
- **Must be captured at the start of `_continueApply`, before the "Apply
  pending changes" commit** — after the commit, HEAD equals the on-disk list and
  the diff vanishes.
- New common helper (e.g. `plugin_teardown.dart`) computes the ordered list of
  `(id, PluginAction)` teardowns to run: for each removed id, read the on-disk
  `plugins/<id>/plugin.json`, and if it declares `teardown`, resolve the action.
  Skip (non-fatal) if the plugin files are already gone or the action is
  unresolvable.

### 3. Apply wiring (`tui` orchestrates, `common` executes)

In `_continueApply`:

1. At the start (before the commit), capture the removed-plugin set and resolve
   their teardown actions via the common helper.
2. After `git commit` and **before `nix flake lock --update-input nixblitz`**,
   run each teardown via `PluginActionRunner.run(action)` (no inputs), streaming
   `> tearing down <id>: <action.label>` and the unit/command output into the
   Apply log.
3. **Failure is non-fatal:** a missing action, non-zero exit, or timeout logs a
   warning and continues to the lock + rebuild. The rebuild removes the module
   regardless, and `tailscale down` on an already-down node is harmless.

The teardown unit (e.g. `tailscale-down.service`) is defined by the plugin
module and is still loaded on the _old_ system at this point, so
`systemctl start --wait` resolves it; after the rebuild it's gone, which is fine.

Business logic (detection + running) lives in `common`; `apply_view.dart` only
orchestrates and renders the streamed output, consistent with the package split.

### 4. Plugin changes (`nixblitz_official_plugins`)

- **Tailscale** (`tailscale/`):
  - `plugin.nix`: add a `tailscale-down.service` oneshot running
    `tailscale down`.
  - `plugin.json`: add a `down` action (`unit:
tailscale-down.service`, `confirm: false`, no inputs, label "Disconnect")
    and `"teardown": "down"`. `privileged_units` gains
    `tailscale-down.service`. Keep the existing `leave` (logout) action as the
    manual destructive verb.
- **NetBird** (`netbird/`):
  - `plugin.json`: add `"teardown": "disconnect"` — reuses the existing
    `netbird-down.service` / `disconnect` action. No new unit.

## Data flow

1. Operator disables (or uninstalls) Tailscale → marker flips, `plugins.list`
   regenerated (id dropped). Config/markers not yet committed.
2. Operator runs Apply. `_continueApply` captures `{tailscale}` as removed
   (in committed list, not in current list) and resolves its teardown → the
   `down` action.
3. After the commit, before the flake-lock fetch, Apply runs
   `tailscale-down.service` on the live system: `tailscale down` disconnects and
   restores DNS.
4. `nix flake lock --update-input nixblitz` and `nixos-rebuild switch` proceed
   with a clean resolver; the rebuild removes the Tailscale module for good.

## Error handling

- Manifest with `teardown` referencing an unknown action or an action with
  inputs → `FormatException` at parse time (caught when the plugin is installed
  / its manifest loaded), surfaced to the operator.
- Teardown at Apply time is best-effort: plugin files gone, action missing,
  non-zero exit, or timeout → log + continue. Never blocks the rebuild.

## Testing

- `common` unit tests:
  - manifest parse: valid `teardown` ref; unknown ref → `FormatException`;
    ref to an action with inputs → `FormatException`; absent `teardown` → null.
  - removal diff: committed-minus-current `plugins.list` yields the right set;
    no removals → empty; uninstall and disable both detected.
- Plugin-side: eval that `tailscale-down.service` builds (mirrors the NetBird
  eval check already done).
- Manual: disable Tailscale → Apply → observe `> tearing down tailscale:
Disconnect` and `tailscale down` running before the lock/rebuild → rebuild no
  longer hangs.

## Repos touched

- **Main repo:** `PluginManifest.teardown` + validation, the removal-diff /
  teardown-resolution helper, Apply wiring, tests.
- **`nixblitz_official_plugins`:** Tailscale `down` action + unit + `teardown`;
  NetBird `teardown`.

## Out of scope

- Surfacing the `disabled` state in the Configure view (separate gap noted in the
  lifecycle map; not required for teardown).
- A generic "run any action on any lifecycle event" framework — only the
  removal-edge teardown is built.
- Ordering/dependencies between multiple plugins' teardowns beyond a stable
  deterministic order.
