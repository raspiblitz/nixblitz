# Pre-rebuild package-version preview in Update flow

## Context

When the user runs **Update entire system** today, the TUI streams
`nix flake update` and then `nixos-rebuild switch` output, but
there's no human-readable answer to _"what versions am I about to
deploy?"_ — by the time the rebuild starts the operator has
already committed to the change.

The Nix-side primitives to surface this exist:

- `nix build --dry-run --print-out-paths --flake .#…system.build.toplevel`
  evaluates a config without fetching or building, prints the new
  toplevel store path. ~30-60s after a `nix flake update` (eval
  cache invalidated by the new lock); fast on warm cache.
- `nvd diff /run/current-system <new-toplevel>` — Nix Version Diff,
  packaged in nixpkgs 25.11. Output is human-readable:
  ```
  [U.]  bitcoind   27.1, 27.2
  [U.]  lnd        0.18.0, 0.18.1
  Closure size: 1234.5MiB → 1235.0MiB (+0.5MiB).
  ```

We slot the preview between _"flake.lock has new pins"_ and
_"start the rebuild"_. The user reviews; on `[a]` we proceed; on
`[d]` we revert the lock commit and bail.

## Recommended approach

### Split `_updateAndRebuild` into ordered, separately-callable phases

`common/lib/src/services/system_service.dart` currently runs
flake-update → lock-changed-check → commit → rebuild as one big
async block (`_updateAndRebuild`, lines 75-133). Pull the
phases apart so the Update view can interpose UI between them.

New SystemService methods:

```dart
/// Runs `nix flake update [input]` + the lock-changed gate +
/// `git commit flake.lock`. Returns the streaming record AND a
/// future that resolves to `LockUpdateResult` once the commit
/// completes (or `noop` if nothing changed).
({
  Stream<String> output,
  Future<LockUpdateResult> result,
}) updateLock({
  required String flakePath,
  required List<String> updateArgs,
  required String commitMessage,
});

class LockUpdateResult {
  final bool committed;       // false → no inputs changed; skip rest
  final int? exitCode;        // non-zero on flake-update failure
}

/// Dry-eval the new system to find the toplevel store path, then
/// runs `nvd diff /run/current-system <new-toplevel>`. Streams
/// progress (the dry-eval is the slow bit) and resolves with the
/// formatted nvd output.
({
  Stream<String> output,
  Future<PackageDiffResult> result,
}) previewPackageDiff({required String flakePath});

class PackageDiffResult {
  final int exitCode;
  final String diffText;       // empty if eval failed
  final String? newToplevel;   // null on failure
  final bool noChanges;        // nvd reported empty diff
}

/// Existing `rebuild()` stays as-is — switches to the already-
/// evaluated toplevel.

/// Rolls back the flake-update commit if the user backs out.
/// Idempotent.
Future<bool> revertLastFlakeCommit({required String flakePath});
```

`updateAll` / `updateInput` stay as thin wrappers over these
phases for callers that want the all-in-one (legacy single-stream
output). The Update view uses the split form.

### Update view state machine

Extend `_UpdateMode` in `tui/lib/src/ui/views/update_view.dart:13`:

```
selectMode  → user picks "TUI only" / "entire system" / "refresh templates"
running     → streams flake update + commit + dry-build + nvd
previewing  → shows the nvd diff; [a] confirm, [d] discard
applying    → streams the actual rebuild
done        → outcome classifier + (new) embedded package diff
```

Transitions:

- `selectMode` → `running`: existing entry points (`_startUpdate`,
  `_refreshTemplates`).
- `running` → `previewing`: when `LockUpdateResult.committed`
  - `PackageDiffResult.noChanges == false`. Empty-diff case
    short-circuits straight to `applying` (nothing to review).
- `previewing` → `applying`: user pressed `[a]`.
- `previewing` → `selectMode`: user pressed `[d]`. Service runs
  `revertLastFlakeCommit`; output appended; state resets.
- `applying` → `done`: rebuild exit.

The `selectMode → running` transition for **TUI-only** updates can
keep the same shape — even with one input changing, surfacing the
package diff is useful.

The **Refresh Nix templates** path (`_refreshTemplates`) doesn't
involve a flake-input change — it rewrites local templates and
rebuilds. Pre-rebuild package diff is still meaningful (templates
can pull in new modules / rebuild differently); reuse the same
preview/applying split.

### Preview screen

Add a `_previewDiffProvider = StateProvider<String?>((ref) => null)`
that the `previewing` view watches. Reuse `ScrollableLog` (already
used in apply/update views) to render the diff with line coloring:

- `[U.]` lines → orange (version change)
- `[A.]` lines → green (added)
- `[R.]` lines → red (removed)
- `Closure size:` → cyan footer

Footer: `[a] Apply  [d] Discard  [Esc] Back  — preview only`.

### Add `nvd` to system packages

`templates/modules/system/base.nix:21-29` already declares
`environment.systemPackages`. Add `nvd` there. It's small (~MB),
generally useful, and we need it on PATH for the dry-build wrapper
to find.

### After-rebuild echo (small bonus)

When `applying → done`, also embed the same diff text in the done
screen (cached from the preview). User has the record on the same
screen as the rebuild outcome. No extra eval cost — we already
computed it.

## Files to modify

- `common/lib/src/services/system_service.dart` — split
  `_updateAndRebuild`; add `updateLock`, `previewPackageDiff`,
  `revertLastFlakeCommit`; keep `updateAll`/`updateInput` as
  back-compat wrappers (used today only by update_view.dart, so
  could also be removed).
- `tui/lib/src/ui/views/update_view.dart` — add `previewing`
  - `applying` modes; rewire `_startUpdate` /
    `_refreshPluginsThenUpdate` / `_startSystemUpdate` /
    `_refreshTemplates` into the new flow.
- `templates/modules/system/base.nix` — add `pkgs.nvd` to
  `environment.systemPackages`.
- `common/lib/src/models/rebuild_outcome.dart` — optional, only if
  we want the diff to live next to outcome classification (we
  don't need it there for v1; keep it as a separate state field).

## Verification

1. **`just analyze && just test`** — clean. The
   service split needs unit tests for `updateLock`'s
   "no changes" early-return path and `previewPackageDiff`'s
   parsing of `nix build --print-out-paths` output. Use
   `Process.runSync`-style mocking only where unavoidable.
2. **VM smoke test:**
   - On the installed VM, run **Update entire system**.
   - Wait for flake update + dry-build to finish (~1-2 min on x86,
     longer on Pi).
   - Confirm the `previewing` screen renders an `nvd`-style diff.
   - Hit `[d]` Discard; confirm the flake.lock commit gets reverted
     (`git log -1 ~/nixblitz` shows the prior commit).
   - Re-run; this time hit `[a]` Apply; confirm the rebuild starts
     and the same diff text shows on the done screen after.
3. **Empty-diff path:** run **Update NixBlitz TUI only** when the
   pinned commit hasn't actually moved (rare but possible). Expect
   a one-line "no package changes — proceeding to rebuild" log
   and a direct transition to `applying`.

## Out of scope (separate tickets)

- **Apply view preview.** The Apply flow's current diff is the
  user's _config_ changes; package diffs are usually a no-op for
  Apply (config flips don't change pinned versions). Adding the
  preview there is straightforward later but lower value.
- **Per-generation SBOM CSV history.** `nvd`-based diffing answers
  the "what did this rebuild change" question without producing a
  tracked artifact. If the operator wants persistent
  generation-by-generation history later, `nix-env --list-
generations --profile /nix/var/nix/profiles/system` plus
  pairwise nvd-diff produces it on demand.
- **Pre-eval cache invalidation hint.** When the user runs
  `nix flake update`, we know the eval will be slow; could surface
  a "this will take ~30-60s the first time" line in the running
  log to set expectation. Polish; defer.

## Risks / things to watch

- **Eval failure mid-preview.** If `nix build --dry-run` fails
  (e.g., a plugin's `plugin.nix` has an assertion miss), the
  preview transitions into a "preview failed — rebuild would also
  fail with this error" state. Same flake-revert option applies;
  user fixes the underlying issue then retries.
- **`nvd diff` exit code.** `nvd` exits non-zero if neither input
  is a valid system path. Treat exit ≠ 0 as a soft failure: log,
  show raw store-path comparison fallback, let the user proceed
  if they want.
- **Slow eval on Pi 4 / 5.** First post-flake-update eval can be
  several minutes. Set the user's expectation in the spinner
  caption ("evaluating new system… first run after a flake bump
  is slow"). No way to make this materially faster.
