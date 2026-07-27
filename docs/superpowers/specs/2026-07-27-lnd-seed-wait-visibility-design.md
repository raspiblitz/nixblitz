# LND Seed-Wait Visibility — Design

**Date:** 2026-07-27
**Status:** Approved
**Branch:** `feat/seed-wait-visibility` (stacked on `fix/update-check-observability`)

## Problem

During the wizard's `initLightning` step the operator sees only a spinner
("Waiting for LND to create wallet seed") while, in the background, the view
polls every 2 s: acquire sudo → `test -f /mnt/data/lnd/lnd-seed-mnemonic` →
`cat` it once LND's preStart drops the file. Three black-box symptoms:

1. Nothing shows whether LND is even starting, still activating, or failed.
2. The sudo popup fires on the very first poll tick — before LND exists —
   with no on-screen explanation of why root is suddenly needed.
3. If anything goes wrong there is no way to see the LND journal without
   leaving the TUI.

## Goals

- Replace the opaque spinner with a live sub-step checklist.
- Defer the sudo prompt until it is actually needed, and announce it on
  screen before it appears.
- Provide an on-demand scrollable LND journal popup (`[l]`) for the full
  picture, on both the happy path and failures.

## Non-goals

- `waitBitcoind` gets no treatment in this change (can adopt the pattern
  later once proven).
- No change to seed handling/reveal: `_lndSeedWords` stays instance state,
  the show/skip choice gate stays as is.
- No streaming `journalctl -f` child process — polling only.

## Design

### 1. `LndSeedWaitService` (common package)

New file `common/lib/src/services/lnd_seed_wait_service.dart`.

```dart
enum SeedWaitPhase { startingService, waitingForSeedFile, readingSeed, done, failed }

class SeedWaitStatus {
  final SeedWaitPhase phase;
  final ServiceState lndState; // reuses ServiceState from system_service.dart
  final String? error;         // set when phase == failed
  final List<String>? seedWords; // set when phase == done (24 words)
}
```

`poll()` — one short-lived pass per call, invoked from the view's existing
2 s timer:

1. **Unprivileged first:** `systemctl show lnd --property=ActiveState,SubState`
   via the existing `SystemService.parseServiceStatus`. No sudo.
   - `failed` → return `SeedWaitPhase.failed` with a message pointing at the
     `[l]` log toggle.
   - not yet `active` → return `startingService`. **No sudo call happens in
     this phase** — this is the fix for the surprise popup.
2. **Once active:** `ensureFresh()` on the injected `SudoSession`, then the
   same `test -f` probe as today. File absent → `waitingForSeedFile`.
3. **File present:** `cat`, whitespace-split, expect exactly 24 words →
   `done` with `seedWords`; wrong count or read failure → `failed` with the
   existing error messages.
4. Sudo cancelled → `failed` ("Sudo authorization cancelled.") exactly as
   today.

Dependencies are injected (`SudoSession`-like interface + a
`Future<ProcessResult> Function(String, List<String>)` runner for the
unprivileged systemctl call) so unit tests run without a live system.

The view keeps ownership of the timer, of stopping the poll on terminal
phases, and of moving `seedWords` into its `_lndSeedWords` instance state
(then discarding the status object) — the service never persists the seed.

### 2. Checklist UI (`_buildLndSeedWaiting` rewrite)

`_buildLndSeedWaiting` becomes a pure render of the latest `SeedWaitStatus`
(held in instance state, updated via `setState` from the poll callback):

```
Lightning Wallet Setup

  ✓ LND service started
  ⠋ Waiting for LND to create the wallet seed
  ○ Read seed file (will ask for sudo)

  [l] show LND log
```

- Item states: done `✓` (green), current = `Spinner`, pending `○` (dim),
  failed `✗` (red) + error text underneath + `[l]` hint.
- The three items map to `startingService` / `waitingForSeedFile` /
  `readingSeed`; `done` advances to the existing choice prompt, unchanged.
- Line-building is extracted as a pure function
  `List<String> seedWaitChecklistLines(SeedWaitStatus)` (or equivalent
  component-free structure) so it is testable without nocterm.

`_tryLoadLndSeed` shrinks to: call `service.poll()`, `setState` the status,
stop the timer + populate `_lndSeedWords`/`_lndSeedError` on terminal
phases. Existing guards (`_lndSeedLoading`, full try/catch, sync-safe
handlers) stay.

### 3. LND journal popup (tui)

New `tui/lib/src/ui/widgets/lnd_journal_popup.dart`, mirroring
`UpdateCheckLogPopup`: `PopupChrome` + `ScrollableLog(ignoreModalGate: true)`,
Esc closes.

- Opened with `[l]` from the waiting/error screens (key handled in the same
  Focusable that already handles this step's keys; guarded by an instance
  bool, popup mounted as a sub-overlay inside the setup view's subtree —
  same pattern as the view's other sub-overlays, no `modalActiveProvider`
  wiring needed).
- Content: `sudo journalctl -u lnd -n 150 --no-pager` via
  `SudoSession.runOneShot`, refreshed by a 2 s timer that runs **only while
  the popup is open** (created on open, cancelled on close/dispose). Each
  tick is a short-lived subprocess; no `-f` streams, no IOSink.
- If the journal fetch fails, the popup shows the fetch error as its
  content — never crashes the wizard.
- The seed never appears in the LND journal (nix-bitcoin writes it straight
  to the seed file), so no filtering is required.

### 4. Error handling

- Every poll/key/timer callback body is wrapped in try/catch →
  `LogService.error` (nocterm zone rules).
- `SeedWaitPhase.failed` keeps the retry affordance the current error
  screen has ("[r] retry" resets status + restarts the poll) and adds the
  `[l]` toggle so the operator can diagnose before retrying.
- The wizard can never be blocked by the visibility layer: any exception in
  checklist rendering or the popup degrades to the current behavior
  (error text + retry).

## Testing

- **common** (`lnd_seed_wait_service_test.dart`): fake sudo session +
  injected systemctl runner. Cases: inactive → `startingService` with **zero
  sudo calls**; activating → `startingService`; unit failed → `failed`;
  active + file absent → `waitingForSeedFile`; active + file present + 24
  words → `done`; wrong word count → `failed`; sudo cancelled → `failed`;
  cat non-zero exit → `failed`.
- **tui**: pure test of `seedWaitChecklistLines` for each phase (glyphs,
  sudo announcement present, error line on `failed`).
- Manual gate: full wizard run in the offline VM — checklist advances, sudo
  prompt appears only after "LND service started" is checked, `[l]` shows a
  live journal, Esc returns, seed flow completes unchanged.
