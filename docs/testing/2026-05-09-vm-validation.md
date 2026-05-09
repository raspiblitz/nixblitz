# VM validation — post NodeTile + plugin extraction

Manual checklist for validating the x86 install + runtime flow
after the most recent session's changes:

- blitz-api / blitz-web extracted to plugins (no longer built-in apps,
  no longer flake inputs in `templates/flake.nix`)
- NodeTile replaces the dashboard's four-block header (chrome strip,
  pending banner, updates banner, drift banner)
- `[r] Refresh templates` keybind removed; drift folds into the
  NodeTile's `system updates` row, auto-rewrite stays on Apply / Update
  preflight
- CLAUDE.md flake-input rule grew a `nixos-raspberrypi` exception
  (Pi 5 only — not exercised here)
- cooling_fan dtparam in `installed-pi5.nix` (Pi 5 only — not
  exercised here)

VM only. Tick items as you go. On any failure, grab `~/nixblitz.log`
before retrying. The known-broken paths in §H are expected to fail
the way they're described — note discrepancies, don't try to fix
mid-test.

---

## A. Pre-flight

- [x] Hypervisor available (qemu via `just vm-boot` is fastest).
- [x] **NixOS 25.11 minimal ISO** downloaded.
- [x] Working tree is on the rev under test; `just gen-templates`
      run if any template was edited locally.
- [x] `just vm-clean` to drop any prior disk image.

## B. Live boot + bootstrap

- [x] `just vm-boot` — VM boots from ISO, lands at the live `nixos@`
      shell.
- [x] `just vm-ssh-installer` — SSH lands cleanly.
- [ ] `nix run github:fusion44/nixblitz_ng` (or your local
      `nixblitz-installer` invocation) — the TUI launches inside the
      live ISO without hitting `~/nixblitz.log` errors.

## C. Install wizard

- [ ] Welcome screen renders, `[Enter]` advances.
- [ ] Operator-name + hostname accepted; defaults work.
- [ ] Disk picker shows the VM's `/dev/vda` and accepts it.
- [ ] LND seed flow runs (regtest), `[A]` reveals seed grid, `[Y]`
      confirms.
- [ ] Final summary screen lists `bitcoind` and `lnd`.
      **Should NOT list blitz-api or blitz-web** — those are plugins
      now.
- [ ] `[Enter]` reboots into the installed system.

## D. First boot dashboard (the NodeTile validation)

`just vm-ssh` to the installed VM, run `nixblitz`.

- [ ] Top-right strip still shows `<alias> | <platform> | all applied`
      — that's the existing chrome via `app.dart:_statusSegments`,
      unchanged.
- [ ] Below the strip, **the four-block banner stack from the old
      dashboard is gone**. Specifically: no separate `~ all applied —
last apply Xm ago` line, no `! N pending changes — press [a] to
review` block, no `updates available: ...` line, no `! N
template files differ — TUI was upgraded` line.
- [ ] First tile in the grid is the **NodeTile**, titled with the
      hostname. Status label reads `all applied` in green.
- [ ] NodeTile rows present: `uptime`, `last apply`, `system updates`
      (value `0`), `config changes` (value `0`).
      **No per-row coloring on a clean tile** — values are plain
      white. The status label in the title bar is the only colored
      element.
- [ ] Other tiles render alongside (Bitcoin, Lightning, Hardware,
      System).
- [ ] Footer shows `[c]: Configure  [u]: Update  [D]: Debug  [?]:
Help  [q]: Quit`. **`[a]: Apply` is hidden** (no pending
      changes).
- [ ] `[?]` Help opens; `[Esc]` dismisses.

## E. Configure → produce pending state

- [ ] `[c]` Configure opens. Toggle `lnd.alias` to a new value.
- [ ] Back on the dashboard:
  - [ ] NodeTile status label reads `1 to apply` (orange).
  - [ ] `config changes` row shows `1 (lnd)` in plain white (not
        colored).
  - [ ] Above the grid: a single dim line reading
        `review pending edits before applying — an external process
may have modified the tracked tree`.
  - [ ] Footer now includes `[a]: Apply`.
- [ ] Toggle two more apps (e.g. enable `cln`, change a `bitcoind`
      option). Tile updates: status `3 to apply`, `config changes`
      shows `3 (bitcoind, cln, lnd)`.

## F. Apply

- [ ] `[a]` Apply opens. Diff lists the edits.
- [ ] `[a]` triggers sudo password prompt (first time this session).
      Provide it.
- [ ] `nixos-rebuild switch` streams output, exits cleanly.
- [ ] Returns to dashboard. NodeTile status label flips back to
      `all applied`. `last apply` row shows `Xs ago` or `1m ago`.
      Caveat line above the grid disappears.

## G. Plugin install — blitz-api + blitz-web

- [ ] `[c]` Configure → Plugins.
- [ ] `[i]` install: paste
      `forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/blitz-api`.
- [ ] Manifest review screen renders. `[Enter]` to confirm.
- [ ] After install, plugin appears in the list with `enabled = false`.
- [ ] Toggle to `enabled = true`.
- [ ] Repeat for blitz-web (same forge URL pattern, swap `blitz-api`
      → `blitz-web`).
- [ ] Back on the dashboard, NodeTile shows `2 to apply` —
      enabling the plugins is a config change.
- [ ] `[a]` Apply runs, picks up the upstream NixOS modules via
      `getFlake` (visible in the rebuild output: nix fetches
      `github:fusion44/blitz_api/<rev>` and
      `github:fusion44/raspiblitz-web/<rev>`).
- [ ] Once applied, `systemctl status blitz-api` is active,
      `systemctl status raspiblitz-web` is active, `systemctl status
nginx` is active.
- [ ] Curl from inside the VM:
      `curl -s http://localhost/api/healthz` returns 200.
      `curl -s http://localhost/` returns the SPA.

## H. Templates drift simulation

Simulate an upgraded TUI binary noticing the operator's on-disk
templates are stale.

- [ ] Edit `~/nixblitz/modules/system/base.nix` to change a comment
      (any change). Commit it: `cd ~/nixblitz && git commit -am
"test drift"`.
- [ ] Re-launch the TUI. On the dashboard, NodeTile's `system
updates` row shows `1` (drift contributes +1, no name).
- [ ] `[u]` Update opens. The drift-rewrite preflight overwrites
      your edited file back to what the binary embeds. Visible in
      the diff that flashes during the preflight.
- [ ] Update completes, NodeTile returns to `all applied`.
- [ ] `cd ~/nixblitz && git diff modules/system/base.nix` — empty;
      the rewrite reverted your test edit.

## I. Known broken paths — verify they're still broken

These are tracked-but-unfixed bugs from this session's debugging.
Test that they fail in the documented way (so we know our
expectations are stable):

- [ ] **Drift-only Apply short-circuit.** With NodeTile showing
      `system updates: 1` (drift only) and `config changes: 0`,
      `[a]` Apply should refuse / report "no pending changes" and
      NOT run the rewrite preflight. (Failing-as-expected: Apply
      gates on `pendingCount > 0`.) `[u]` Update is the only path
      that clears drift today.
- [ ] **Update discard cascade.** Force a build failure during
      `[u]` Update (e.g. inject a syntax error into a plugin's
      `plugin.nix` for one apply, then revert). On failure, the
      Update flow's `git reset --hard HEAD~1` reverts the templates
      rewrite alongside the lock update — leaving on-disk templates
      stale relative to the binary. (Failing-as-expected: rewrite
      and lock update are committed together.)
- [ ] **Orphan template files survive binary updates.** Touch a
      `~/nixblitz/modules/apps/foo.nix` file that the binary doesn't
      embed. Run `[u]` Update through to success. Confirm the orphan
      file is **still on disk** afterward — `refreshTemplatesSync`
      writes embedded keys but never deletes orphans.

## J. Logs + cleanup

- [ ] `~/nixblitz.log` is well under 1 MB (no spam loops).
- [ ] No `BlitzApi SSE error` log spam at 30s cadence — the bounded
      retry from the earlier auth fix should keep the log quiet
      when blitz-api is up.
- [ ] `journalctl -b -p err` has no nixblitz-related entries.
- [ ] `just vm-clean` to drop the disk image when done.

---

## Notes

- This plan exercises **x86 only**. Pi 5 paths (cooling_fan dtparam,
  cachix substitution from `nixos-raspberrypi.cachix.org`, the
  no-follows nixpkgs change for the vendor kernel) need a separate
  Pi 5 validation run.
- The `getFlake` plugin pattern means an internet connection is
  required during Apply / Update, even on otherwise-cached builds —
  the upstream blitz-api / raspiblitz-web revs get fetched on every
  module-eval. Worth noting for offline-VM testing.
- If anything fails outside §H, capture `~/nixblitz.log` plus the
  full TUI screen output and file an issue.
