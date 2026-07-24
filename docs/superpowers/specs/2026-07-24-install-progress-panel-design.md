# Install Progress Panel (nom-inspired) — Design

**Status:** Approved design, ready for implementation planning.
**Date:** 2026-07-24
**Scope:** First slice of "nicer build/rebuild output across NixBlitz screens."

---

## 1. Purpose & scope

Replace the install screen's currently-silent, frozen-looking output with a
live **progress panel**: the phase the installer is in, a **copy-progress bar**
for the long store-copy phase, elapsed time, and a tail of recent log lines —
with the full scrollable log one keypress away.

### Why the install screen is a special case (the finding that shaped this)

The original idea was to integrate [nix-output-monitor](https://github.com/maralorn/nix-output-monitor)
(`nom`). Two facts made a literal nom integration the wrong tool here:

1. **nom can't render inside a nocterm widget.** nom is a full-screen,
   cursor-redrawing renderer; nocterm already owns the alternate screen + raw
   mode. They can't share the terminal, and nocterm has no suspend/resume API.
2. **The install's heavy phase isn't a nix operation.** Reading the real
   `disko-install` (v1.12.0): on a blank target disk it copies the pre-built
   closure with a plain **`xargs cp --recursive`**, then `nix-store --load-db`,
   then a tail `nixos-install`. The `cp` is silent — no nix `internal-json`, no
   parseable progress — during the exact phase (minutes of copying ~GB to disk)
   that currently makes the log look hung. `disko-install` also exposes no
   `--log-format` passthrough.

So this slice makes the install screen nicer with a **heuristic** progress source
(phase markers + a byte-progress bar), **not** nom/internal-json. The panel and
its data model are built source-agnostic so a future `internal-json` source (for
the `nixos-rebuild switch` screens, where nom genuinely fits) can feed the _same_
widget without rework.

### In scope

- The **install screen only** (`install_view` → `InstallService.diskoInstall`).
- A source-agnostic **`InstallProgress` model** + a **`BuildProgressPanel`**
  nocterm widget.
- A **heuristic install source**: phase detection from disko-install's plain
  output + a copy-progress bar from filesystem byte counts.

### Global constraints

- `common` does all IO / `Process` work; `tui` is UI only (CLAUDE.md).
- Nocterm pitfalls: no `StateProvider` write mid-key-handler before sync work;
  full-body `try/catch` in handlers; synchronous IO in handlers; no `IOSink`.
- **The progress UI must never block, slow, or fail the install.** Every
  progress-derivation failure degrades silently (drop the bar, keep phase + log);
  the existing exit-code handling and `[r]` retry are preserved unchanged.
- **No new runtime dependency** — no `nix-output-monitor` in the closure. The
  heuristic uses `du`/`df` (coreutils, already present) only.

### Out of scope (deferred to later branches)

The `internal-json`/nom source · the `nixos-rebuild switch` screens
(setup/apply/update/migration) · the Pi 5 install path (same mechanism should
apply, but validate separately) · any change to `disko-install` itself.

---

## 2. The heuristic mechanism

### 2.1 Phases

```
InstallPhase: preparing → building → partitioning → copying → loadingDb → installing → done → failed
```

`preparing` is the initial state before any marker; `failed` is entered by the
view on a non-zero exit (not by a line marker).

### 2.2 Phase markers (from disko-install's plain lines)

A pure matcher maps a line to a phase transition (first match wins; unmatched
lines don't change phase):

| Substring in the line                                                             | Phase          |
| --------------------------------------------------------------------------------- | -------------- |
| `nix build` / `building '` / `evaluating`                                         | `building`     |
| disko format lines — `mkfs`, `Creating`, `wipefs`, `zpool`, `Formatting`          | `partitioning` |
| **`Copying store paths`**                                                         | `copying`      |
| **`Loading nix database`**                                                        | `loadingDb`    |
| `nixos-install`, `installing the boot loader`, `setting up /etc`, `updating GRUB` | `installing`   |
| `disko-install succeeded`                                                         | `done`         |

The two bold markers are emitted verbatim by disko-install and are the load-bearing
signals; the rest are best-effort phase colour and may miss without harm.

### 2.3 Copy-progress bar

The `copying` phase is the long one and emits no progress of its own, so we derive
it from the filesystem:

- **Total (computed once, at install start):** `du -sb /nix/store` on the live ISO
  — the closure being copied is (a subset of) the ISO's store. A superset by the
  installer's own extra paths, so raw bytes top out ~85–95%; see the snap rule.
- **Current (polled every ~2 s while in `copying`):** bytes used on the target
  mount — `df -B1 --output=used <mountPoint>` (cheap, monotonic). `<mountPoint>`
  is disko-install's default `/mnt/disko-install-root` (NixBlitz passes no
  `--root`); the tracker takes it as a parameter.
- **Fraction:** `min(0.99, current / total)` while copying.
- **Snap rule:** when the `Loading nix database` marker arrives, the copy bar is
  forced to `1.0` — that marker is ground truth that the `cp` finished, and it
  corrects the superset-driven undershoot.

Phases other than `copying` render as indeterminate (spinner + phase label), no
bar.

### 2.4 What the panel shows

```
 Installing NixBlitz
 ⠋ Copying store paths   [██████████████░░░░░]  73%   4m12s
   … last ~6 log lines …
 [l] full log   [↑/↓ scroll when log open]
```

Phase label + (bar when `copying`, else spinner) + elapsed + a short tail of
recent lines. `[l]` toggles the full existing `ScrollableLog` (kept intact for
errors and debugging). On `failed`, the panel yields to the current failure
screen (full log + retry) unchanged.

---

## 3. Architecture & components

### 3.1 `common`

**`common/lib/src/services/install/install_phase.dart`** (pure)

- `enum InstallPhase { preparing, building, partitioning, copying, loadingDb, installing, done, failed }`
- `InstallPhase? installPhaseForLine(String line)` — the §2.2 matcher; returns
  null when a line implies no transition. Pure, fully unit-testable.

**`common/lib/src/services/install/install_progress_tracker.dart`**

- `class InstallProgress { final InstallPhase phase; final double? copyFraction; // null unless copying; final int elapsedSeconds; }`
- `class InstallProgressTracker` — consumes the `diskoInstall` line stream and
  drives an `InstallProgress` stream/notifier:
  - holds current phase; updates it via `installPhaseForLine`;
  - on entering `copying`, starts a periodic (~2 s) poll of the injected
    byte-reader against the precomputed total, emitting `copyFraction`;
  - applies the snap rule on `loadingDb`;
  - the byte-reader and total-reader are injected
    (`Future<int> Function(String path)` / `Future<int> Function()`) so tests
    supply fakes — no real `du`/`df` in unit tests.
- A small IO helper (in `common`, using `Process.run`) provides the real
  `du -sb` / `df` readers; failures return null → tracker degrades to phase-only.

### 3.2 `tui`

**`tui/lib/src/ui/widgets/build_progress_panel.dart`**

- `BuildProgressPanel` — renders phase label, a progress bar (when
  `copyFraction != null`) or a `Spinner`, elapsed, and a tail of recent lines.
  Source-agnostic: takes an `InstallProgress` + the recent-lines list + an
  `onToggleLog` callback. (Named `Build…` not `Install…` deliberately — the same
  widget will serve the rebuild screens' future json source.)

**`tui/lib/src/ui/views/install_view.dart`** (modify)

- In `_startInstall`, feed the existing `diskoInstall` line stream into an
  `InstallProgressTracker` (in addition to the current log-append), compute the
  total-size reader at start, and render `_buildInstalling` via
  `BuildProgressPanel` with an `[l]` toggle back to the full `ScrollableLog`.
  The elapsed timer, exit-code → complete/failed routing, and `[r]` retry are
  unchanged.

---

## 4. Data flow

```
diskoInstall() line stream ─┬─► existing log list (unchanged; shown on [l]/failure)
                            └─► InstallProgressTracker
                                  ├─ installPhaseForLine(line) → phase
                                  ├─ on `copying`: poll df(target) / du(source) → copyFraction
                                  └─ on `loadingDb`: copyFraction := 1.0
                                        │
                                        ▼
                                  InstallProgress stream ─► BuildProgressPanel
exit code ─► InstallStep.complete / failed (unchanged)
```

---

## 5. Error handling / degradation

- `du`/`df` reader throws or returns ≤ 0 → `copyFraction` stays null → panel shows
  spinner + phase, never a broken bar. Logged once at debug, not surfaced.
- Total-size computation fails at start → copying phase renders indeterminate.
- Unrecognized line → no phase change (stays in the last known phase).
- Poller is cancelled on leaving `copying`, on `dispose`, and on stream done — no
  leaked timers (mirror `install_view`'s existing `_elapsedTimer`/`_outputSub`
  lifecycle).
- Nothing in the tracker or panel can throw into the install's control flow; the
  install proceeds identically whether or not the panel renders.

---

## 6. Testing

- **`install_phase` (pure):** each marker line → expected phase; non-marker lines
  → null; ordering/first-match; the two verbatim disko markers.
- **`InstallProgressTracker`:** feed a scripted line stream + a fake byte-reader
  (returning a rising sequence) + fake total → assert the emitted
  `InstallProgress` sequence: phase transitions, `copyFraction` rising and
  clamped ≤ 0.99, and the snap-to-1.0 on `loadingDb`. Assert the poller stops
  after `copying`.
- **`BuildProgressPanel`:** nocterm test-binding render assertions — bar rendered
  with a given fraction; spinner + phase label when fraction null; tail lines
  shown; `[l]` hint present.
- **Manual VM (acceptance):** run a real install in the VM; confirm the phases
  advance, the copy bar rises during the `cp` and snaps to done at
  `Loading nix database`, elapsed ticks, `[l]` reveals the full log, and a forced
  failure still lands on the retry screen. Verify `df`/`du` costs are negligible
  at the 2 s cadence.

---

## 7. Future (explicitly out of this slice)

- An `internal-json` progress source (parse nix's `@nix {…}` events into the same
  `InstallProgress`-shaped model, reconstructing human log lines from `msg`
  events) feeding `BuildProgressPanel` on the `nixos-rebuild switch` screens
  (setup / apply / update / migration). The model + widget here are built to
  admit it without rework.
- Pi 5 install validation.
