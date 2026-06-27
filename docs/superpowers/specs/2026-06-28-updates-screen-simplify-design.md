# Simplify the Updates (Check) screen — design

Date: 2026-06-28
Status: approved (design)

## Goal

Make the System update screen understandable to a non-NixOS operator. Today it
presents three Nix-jargon categories — "flake inputs" (disko / nixblitz /
nixos-raspberrypi / nixpkgs), "plugins", "system closure: N need compile" — each
with per-row timestamps and rev tracking. Replace that with the operator's real
mental model: **two things can update — NixBlitz and Plugins — and applying may
take a while.** All the per-input/per-package detail stays, one drill-down away.

This is a **presentation change**. The check service, the `CheckResult` data
model, the staging/Apply flow, and the daily background check are unchanged — we
re-present existing data.

## Current vs new

Of everything shown today, only two things are operator-actionable:

- `nixblitz` — the node software, pulled from the forge.
- plugins — the installed plugins.

The other inputs (`disko`, `nixos-raspberrypi`, `nixpkgs`) are project-pinned
infra (`nixos-raspberrypi` is tag-locked; `nixpkgs`/`disko` follow it), so an
operator can't update them independently — they move only when a NixBlitz update
bumps them. And "system closure: N need compile" is not a thing that can be
"ahead" — it's a _"this rebuild will be slow"_ warning about the net effect of
applying.

## The new Updates panel

Sidebar entry **`Check` → `Updates`**; drop the "read-only probes" subtitle.

**Up to date:**

```
Updates                                          checked just now

  NixBlitz   ✓ up to date
  Plugins    ✓ up to date

  ▸ Check for updates
```

**Updates available (compile needed):**

```
Updates                                          checked just now

  NixBlitz   ↑ update available
  Plugins    ✓ up to date

  Applying builds 12 packages on the node first — can be slow on a Pi.

  ▸ Check for updates
  ▸ What's changing…
```

### Row semantics (computed from the existing `CheckResult`)

- **NixBlitz** rolls up _all non-plugin inputs_ (`inputsAhead`): `↑ update
available` when `inputsAhead.isNotEmpty`, else `✓ up to date`. The individual
  infra inputs are not shown on this screen. (`nixblitz` being ahead, or any
  infra input being ahead, both read as "the node software has an update".)
- **Plugins** uses `pluginsAhead`: `✓ up to date` when empty, else `↑ N update(s)
available`. (Unchanged logic; just relocated.)
- **The "when you apply" note** replaces the "system closure" row. It describes
  the _net effect_ of applying (not attributed to a group, because the closure
  reflects inputs **and** plugins together):
  - `compileNeeded` (`wouldBuild` non-empty) → `"Applying builds N packages on
the node first — can be slow on a Pi."` (N = `wouldBuild.length`; singular
    "1 package").
  - changes pending, no compile (`!noChanges && diffText` non-empty) →
    `"Applying downloads prebuilt packages (no local build)."`
  - `noChanges` **and** nothing ahead → no note (the two `✓` rows already say it).
  - `noChanges` but an input/plugin rev moved → `"Inputs moved but the built
system is unchanged — applying re-pins, nothing rebuilds."`
- **One top-of-panel timestamp** (`checked <age>`) replaces the three per-section
  `(just now)` stamps — all sections are probed in one check.

### Actions

- **`Check for updates`** — unchanged behaviour (`runCheckSubprocess`).
- **`What's changing…`** — shown only when there is something to show
  (`inputsAhead` non-empty OR `pluginsAhead` non-empty OR `wouldBuild` non-empty
  OR a non-empty `diffText`). Opens the consolidated details view below.
- The current separate `View package diff` / `View packages to compile` actions
  are removed from this panel (folded into `What's changing…`).

### Error / not-yet-checked states

- No check has run yet → the two rows show a dim `— not checked yet` (or the
  existing "unknown" treatment), and only `Check for updates` is offered.
- `CheckResult.ok == false` (probe failed) → a one-line plain-language error
  (`"Couldn't check for updates — <error>"`) above `Check for updates`; rows show
  the last-known/unknown state. (Reuse the existing error string from
  `CheckResult.error`.)

## The "What's changing…" details view

One screen consolidating what are today three things (the per-input rows, the
would-build list, the nvd diff). Reuses the existing package-diff view
(`cached_package_diff.dart` / `AppView.packageDiff`), extended with a leading
"Inputs that moved" section:

```
What's changing                                  checked just now

  Updated software
    nixblitz (the NixBlitz software)   abc1234 → def5678
    nixos-raspberrypi                  …            (only inputs that moved)
    <plugin-id>                        v0.2.0 → v0.3.0   (from pluginsAhead)

  Builds on the node (12)              ← only when wouldBuild non-empty
    rustc-1.87.0
    …

  Package changes                      ← only when diffText non-empty (nvd diff)
    [U] foo 1.2 → 1.3
    [A] bar 0.9
    [R] baz 2.0
    Closure size: …
```

- **Updated software** = `inputsAhead` (with `nixblitz` labelled "(the NixBlitz
  software)") + `pluginsAhead` (id + version/rev delta). This is where the infra
  input detail (disko/raspberrypi) lives for power users. Short revs (7-char).
- **Builds on the node** = `wouldBuild` short derivation names (existing
  "packages to compile" content).
- **Package changes** = the existing colorized `nvd diff` (`[U]/[A]/[R]` + closure
  size), unchanged.
- Sections render only when they have content; an empty details view can't be
  reached (the action is gated).

## Components touched

- `tui/lib/src/ui/views/system_view.dart` — `_CheckStatusPanel` rewrite (rows,
  note, timestamp, gated actions) + the sidebar label `Check → Updates`.
- The package-diff / details view (`tui/lib/src/ui/views/cached_package_diff.dart`
  or a renamed/extended "what's changing" view) — add the "Updated software"
  section; keep the would-build + nvd-diff sections.
- A small presentation helper in `common` (pure, testable) that maps a
  `CheckResult` to the panel's display model: NixBlitz status, Plugins status +
  count, the "when you apply" note string, and whether `What's changing…` is
  available. Keeps the branching logic out of the nocterm view and unit-testable.

## Not changing

- `UpdateCheckService.runCheck`, the network probe, the dry-run/compile-bail, the
  staging mechanism, and the daily systemd check.
- `CheckResult` / `InputAhead` / `PluginAhead` / `StagedChanges` models.
- The Apply screen and how staged updates are committed + rebuilt.
- The `[c]` check hotkey behaviour (only the sidebar label text changes).

## Testing

- **common unit** — the `CheckResult → display model` mapper: up-to-date (no
  note, no details action); input ahead → NixBlitz `↑`; plugins ahead → count +
  pluralization; compile-needed → the build warning with N; no-changes-but-rev-
  moved → the re-pin note; details-available gating across each combination.
- **Manual** — run a check with the TUI/system input ahead → screen reads
  "NixBlitz ↑ update available" + the compile note; `What's changing…` lists the
  moved inputs + builds + diff; an up-to-date node shows two `✓` rows and only
  `Check for updates`.

## Out of scope

- Reworking the Check↔Apply split itself (the "find updates here / install in
  Apply" two-step stays).
- Changing what the daily background check probes or stages.
- Any change to plugin/infra update _detection_ logic (versions, SHA fallback,
  the nixos-raspberrypi tag pin).
