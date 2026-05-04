# System Update menu redesign

## Context

The current System Update menu (`tui/lib/src/ui/views/update_view.dart`,
`_buildSelectMode`) is a flat action list of five items, oblivious to
what actually has updates pending. It does not surface plugin drift,
forces the operator to run `nixblitz check {light,heavy}` from a shell
to get fresh data, and exposes "Refresh Nix templates" as a routine
action even though template drift in steady state is a bug, not a
workflow.

We want a menu where:

- **Cache state drives what's shown.** Each action's enabled/disabled
  state and subtitle reads from
  `/var/lib/nixblitz-tui/update-status.json` (the file the periodic
  systemd timers populate).
- **Manual checks are first-class.** `[c]` re-runs the lightweight
  check (~3–5s); `[C]` re-runs the heavy check (~1–10 min, with
  confirmation).
- **Templates self-heal.** Drop "Refresh Nix templates" from the
  routine menu; auto-rewrite at the end of every Update flow that
  bumps the TUI binary. The dashboard drift banner stays as a
  fail-safe — if it fires in steady state, that's a bug.
- **Plugins are out of System Update entirely.** A pointer row
  ("plugin updates available — open [p] plugins menu") replaces the
  inlined "Refresh plugins only" action. Plugin updates are a
  separate workflow.

## Goals

1. Surface what we know (cache) and what makes sense to do (gated
   actions) in one screen.
2. Stop forcing the operator to choose actions whose effect they
   can't preview from the menu.
3. Make plugin drift discoverable from the System Update screen
   without coupling its workflow to system rebuilds.
4. Make heavy checks runnable from the TUI so the operator doesn't
   have to wait up to a week for the next scheduled run.

## Non-goals

- Renaming or restructuring the underlying `UpdateCheckService`
  (light/heavy split stays as-is).
- Changing how `~/nixblitz/` is structured or where the lock files
  live.
- Moving plugin update mechanics — `nixblitz plugin refresh` and the
  plugins menu stay unchanged.
- A separate notifications feed / message inbox / changelog view.

## Architecture

The screen is two stacked panels rendered in `selectMode`:

```
┌── Status ─────────────────────────────── [c] check now  [C] full check ─┐
│                                                                          │
│   flake inputs    nixpkgs, disko ahead         (light 9h ago)            │
│   system closure  14 changes pending           (heavy 7d ago)            │
│   TUI binary      ahead by 3 commits           (light 9h ago)            │
│                                                                          │
│   ! plugin updates available — open [p] plugins menu                     │
└──────────────────────────────────────────────────────────────────────────┘
┌── Actions ───────────────────────────────────────────────────────────────┐
│                                                                          │
│ > Update NixBlitz TUI only        ahead by 3 commits                     │
│   Update entire system            14 changes pending                     │
│   Cancel                                                                 │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

(The chrome above is illustrative — actual rendering uses the existing
`Column` / `Text` layout, no box-drawing.)

### Status panel

Reads `readUpdateStatus()` (synchronous, file-backed) on every
rebuild; cheap. Rows render conditionally:

| Row              | Source                                                                                                     | Hides when                                                             |
| ---------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `flake inputs`   | `light.inputsAhead`, filtered by `filterStillAhead` against live `flake.lock`, **excluding** the TUI input | filtered list empty AND no light error                                 |
| `system closure` | `heavy.diffText` + `heavy.noChanges`                                                                       | `heavy` is null (never run) — replaced with a "no full check yet" line |
| `TUI binary`     | `light.inputsAhead` filtered to the single input that pins the TUI binary                                  | TUI input not ahead AND no light error                                 |
| plugin pointer   | `light.pluginsAhead` (new field — see "Cache schema changes")                                              | empty                                                                  |

Each row's right-hand suffix (`(light 9h ago)`, `(heavy 7d ago)`)
uses muted grey; the row gets a leading `!` and a yellow tinge when
the corresponding check is **stale** — light older than 2 days,
heavy older than 14 days.

When the status file is missing entirely (fresh install), the panel
collapses to a single line: "no cached check yet — runs daily".

### Action panel

Three items: `Update NixBlitz TUI only`, `Update entire system`,
`Cancel`. Each non-cancel row has:

- **Subtitle** — one-line summary derived from the same cache the
  status panel reads. E.g. `ahead by 3 commits`, `14 changes
pending`, `up to date`, `no full check yet`.
- **Enabled state** — driven by cache:
  - `Update NixBlitz TUI only` — enabled iff the TUI flake input is
    in `light.inputsAhead`. Disabled-but-present otherwise.
  - `Update entire system` — enabled iff `heavy.diffText` is
    non-empty AND `!heavy.noChanges`. **Special case:** if heavy is
    stale (>14d) and `light.inputsAhead` is non-empty, treat as
    enabled with subtitle "may have changes — heavy check stale".

**Soft-disabled** behavior: a disabled row is rendered in dim grey
with subtitle "no changes pending". First `Enter` on it shows a
muted message in place of the subtitle — "no changes — press Enter
again to rebuild anyway". Second consecutive `Enter` confirms and
runs the action. The "first Enter" state resets if the operator
moves selection (`j`/`k`) away. Override-confirmation tracking is a
private state flag inside `_UpdateViewState`, not a Riverpod
provider — purely transient UI state.

### Manual check triggers

- `[c]` — fires `UpdateCheckService.runLightweight()` in-process.
  Renders a one-line spinner above the status panel; cache repaints
  on completion. ~3–5s typical. No confirmation.
- `[C]` — shows a confirmation prompt overlay first (`Run full
check? Takes 1–10 minutes, downloads ~125 MB to /tmp. [y/N]`). On
  yes, transitions into a new `_UpdateMode.runningCheck` that reuses
  the `_buildRunning` chrome (spinner + scrollable log) but kicks off
  the heavy check. On completion, transitions back to `selectMode`;
  the cache repaints with fresh data.

The check service is currently invoked by systemd timers running as
`admin` with `User=admin` in the unit, and the status directory is
`admin:users 0755` per the systemd-tmpfiles rule. Files admin writes
inside it land at 0644 admin-owned — so the TUI process can only
overwrite the status file when it runs as `admin` (the standard
NixBlitz install). For broader user safety we shell `[C]` out via
`systemctl start nixblitz-check-heavy.service` rather than running
`runHeavy()` in-process — same env / user as the scheduled run, no
permission surprises. `[c]` may run in-process iff the running user
matches the file owner; otherwise it falls back to the analogous
`systemctl start nixblitz-check-light.service`. **To verify in
implementation:** confirm the standard install runs the TUI as
`admin` (the README implies it does). If yes, `[c]` can stay
in-process for snappier turnaround; `[C]` always shells out.

### Template auto-rewrite

The body of the existing `_refreshTemplates` action is extracted
into a reusable helper that can be invoked without entering
`selectMode`. After every successful Update of either kind
(`Update NixBlitz TUI only` or `Update entire system`), the
post-success path checks `templatesDriftProvider`. If it reports
drift, the helper runs implicitly: rewrite embedded templates over
disk, scoped commit ("Refresh Nix templates after $reason"), no
operator interaction. **To verify in implementation:** the exact
post-success hook in `_UpdateViewState` (`_completeWithSuccess` or
the function that transitions to `_UpdateMode.done`).

The dashboard drift banner stays in `dashboard_view.dart`. Steady
state: it never fires. If it does, the operator presses `[r]` as
today and the standard refresh-then-apply path runs. We don't drop
that escape hatch even though we expect not to need it.

### Plugin-drift signal (lightweight extension)

Add to `LightCheck`:

```dart
final List<PluginAhead> pluginsAhead;
```

```dart
class PluginAhead {
  final String dirName;     // matches NixblitzConfig.plugins[].dirName
  final String currentRev;
  final String upstreamRev;
  final String url;
}
```

`runLightweight()` after the existing flake-inputs walk:

1. Load `NixblitzConfig` via the same path the dashboard does
   (`config.json`).
2. For each `plugin` in `config.plugins` where
   `enabled && autoUpdate && pinnedRev == null && uninstalledAt == null`:
   - Read its locked rev. **To verify in implementation:** the field
     name in `NixblitzConfig.plugins[].lockedRev` (or wherever
     `PluginService` keeps the per-plugin pin).
   - Translate the plugin's source URL into the same `LockedInput`
     shape `_queryUpstreamRev` consumes (github / forgejo / git
     transports), or fall through with a per-plugin "unsupported
     transport" error.
   - Compare upstream HEAD; if ahead, append a `PluginAhead`.
3. Errors accumulate into the same `errors` list flake-input errors
   already use; the lightweight run still exits 0.

Pinned plugins (`pinnedRev != null`) are intentionally skipped — the
operator pinned them, drift is theirs to manage.

### Cache schema changes

`update-status.json` gains one optional field on the `lightweight`
section:

```json
{
  "lightweight": {
    "checked_at": "...",
    "ok": true,
    "inputs_ahead": [...],
    "plugins_ahead": [
      {
        "dir_name": "mempool",
        "current_rev": "abc123...",
        "upstream_rev": "def456...",
        "url": "https://github.com/..."
      }
    ]
  },
  "heavy": {...}
}
```

`fromJson` treats absent `plugins_ahead` as empty list — old status
files keep parsing.

## Data flow

```
flake.lock + config.json + GitHub/Forgejo APIs
                    │
                    ▼
       UpdateCheckService.runLightweight()
                    │
                    ▼
        update-status.json (LightCheck +
                          pluginsAhead field)
                    │
                    ▼
            readUpdateStatus()
                    │
       ┌────────────┼─────────────┐
       ▼            ▼             ▼
  dashboard      Status        Action
  banner         panel         panel
                                (gating)
```

The TUI never writes `update-status.json` from inside `selectMode` —
only the lightweight/heavy CLI paths do. `[c]` / `[C]` from the menu
shells into the same service and writes the same file. Cache is the
single source of truth; the menu is a view onto it.

## Error handling

- **Status file missing.** Status panel shows "no cached check yet —
  runs daily". Action subtitles read "no full check yet". Both
  actions remain selectable; soft-disable behavior unchanged
  (override flow available).
- **Lightweight check fails (network, parse).** Status row for the
  affected check renders in red: `flake inputs    error: <message>
(light 9h ago)`. Other rows render normally. `[c]` retry available.
- **Heavy check fails (eval error).** Same pattern: `system closure
error: eval failed (heavy 7d ago)`. `[C]` retry available.
- **Per-plugin error during `runLightweight()`.** Pointer row
  reads "plugin updates: M ahead, K errors — open [p] plugins menu".
  The plugins menu surfaces per-plugin errors in detail (out of
  scope for this design).
- **Manual `[c]` / `[C]` while a check is running.** Block. The
  spinner stays put; pressing again does nothing. Status panel only
  refreshes after the active run completes.
- **Cache stale beyond timer cadence.** Light older than 2 days OR
  heavy older than 14 days — the affected row gets the leading `!`
  - yellow tinge described in the Status panel section. Actions
    still gated on the cached values; the operator can `[c]` / `[C]`
    to refresh before deciding.

## Testing

Unit:

- `LightCheck.fromJson` parses the new `plugins_ahead` field; absent
  field → empty list.
- `UpdateCheckService.runLightweight()` writes `pluginsAhead`
  entries for `auto_update` non-pinned active plugins whose upstream
  has moved.
- `runLightweight()` skips pinned plugins.
- `runLightweight()` skips uninstalled (tombstoned) plugins.
- Action-gating logic (extracted into a pure function) returns the
  right `(enabled, subtitle)` tuple for each cache permutation:
  - heavy null
  - `heavy.noChanges == true`
  - `heavy.diffText` non-empty
  - heavy stale + light has hits (the "may have changes" path)
  - light TUI input ahead vs not.

Integration (TUI):

- Dashboard drift banner still fires when `templatesDriftProvider`
  has drift (regression: post-Update auto-rewrite must not regress
  the banner's behavior outside the auto-rewrite window).
- Disabled action: first Enter shows override prompt, second runs.
  Selection change resets the prompt.
- `[c]` round-trip — fire, await, status repaints with new
  `checkedAt`.
- Plugin pointer row chord — `[p]` from System Update navigates to
  the plugins view.

## Open verification items

These are intentionally left for the implementation pass; they don't
change the design but need a quick check before touching code:

1. **TUI flake input name.** Which input in `flake.nix` pins the
   running TUI binary? Filtering "TUI binary" out of the `flake
inputs` row depends on the answer. (Likely the self-input
   `nixblitz`, but verify.)
2. **Where the per-plugin locked rev lives.** Field on
   `NixblitzConfig.plugins[]`, or a separate file under `~/nixblitz/
plugins/<dir>/.locked-rev`, or computed from `config.plugins[].url
#revision`? `PluginService` knows; reading its source is enough.
3. **Heavy check from the TUI.** Confirm the operator user has write
   access to `/var/lib/nixblitz-tui/update-status.json` (file is
   `admin:users` mode 0755 per the systemd-tmpfiles rule; operator
   should be in `users` group). If not, fall back to
   `systemctl start nixblitz-check-heavy.service` so the timer's
   `User=admin` env applies.

## Out of scope

- A separate notifications / message log view.
- Reworking how the heavy check stages its tmpdir build (still
  `cp -aT ~/nixblitz/ /tmp/nixblitz-check-heavy-XXXXXX/` + `nix
flake update` there).
- Caching the result of "what would Update entire system actually
  do" beyond what the heavy check already records — future work
  could memoize per `flake.lock` rev so the menu's "14 changes
  pending" subtitle stays accurate after a `nix flake update` even
  before the next heavy run, but that's not in this pass.
- Changing dashboard chrome beyond the previous-pass drop of the
  "preview ($ago):" line.
