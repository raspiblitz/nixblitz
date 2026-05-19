# Dev loop

This is the cheat-sheet for hacking on NixBlitz: which `just`
target gets you what, where the artifacts land, and how to test
your change without paving over a real install. Pairs with
[architecture.md](architecture.md) for _what_ you're editing.

## What to install on your host

Minimum:

- **Nix** with flakes enabled. On non-NixOS, the
  [Determinate installer](https://determinate.systems/posts/determinate-nix-installer)
  is the smoothest path; vanilla nix works too.
- **`just`** — the task runner the repo standardizes on. `nix
shell nixpkgs#just` if you don't want to install it permanently.
- **`qemu`** + **`qemu-img`** — for `just vm-boot`. NixOS hosts
  get this for free; on Debian: `apt install qemu-system-x86 qemu-utils`.

That's it. Dart, the workspace deps, every plugin's nixpkgs pin —
all of it is fetched into the Nix store on first build.

If you'd rather edit Dart from a regular IDE: `nix develop` opens
a shell with `dart` + tooling on `PATH`. Optional; everything below
still works without it.

## The three loops

The fastest way to see your change matters by what you changed:

| Change                             | Loop                                | Round-trip                          |
| ---------------------------------- | ----------------------------------- | ----------------------------------- |
| Widget / UI                        | `just run-dev`                      | seconds                             |
| Service / config / TUI integration | `just run` against a local checkout | seconds (Dart) but no real services |
| End-to-end                         | `just vm-boot` → `just vm-deploy`   | minutes                             |

### Loop 1 — `just run-dev`

```bash
just run-dev
```

Launches `bin/nixblitz_dev.dart` — a separate entry point with no
`config.json` requirement, no SSE connection, no NixOS dependency.
You get a menu of widget previews:

- Log demo (scrollable log + multi-line entries)
- Password input
- Confirm prompt, select popup, spinner
- Option editors (bool / select / number / text)
- Service card
- Help popup
- Dashboard layout (with realistic tile content sizes)

This is where you iterate on rendering, key handlers, layout
constraints. `Ctrl+C` to exit. Add new previews in
`tui/lib/src/dev/views/` and wire them into
`tui/lib/src/dev/dev_app.dart`.

### Loop 2 — `just run`

```bash
just run
```

Runs the full TUI binary against `~/nixblitz/config.json` — same
binary your VM uses. On a non-NixOS host, services aren't running
so the dashboard tiles will show empty / failed states; that's
expected. Use this loop for changes that touch the **TUI's
internals** (config service, plugin service, git plumbing) rather
than the rendered UI.

### Loop 3 — Full VM

The truth-test for anything that hits NixOS:

```bash
# First time: provision the VM + walk the install wizard.
just vm-boot
```

`vm-boot` boots the NixOS ISO from
`~/Downloads/nixos-minimal-25.11.*.iso` (edit the path in the
justfile if yours differs) inside qemu, with port 22 forwarded to
host port 10022. Walk the install wizard inside the VM exactly
like a real Proxmox install (see
[getting-started.md](getting-started.md)).

After install completes, the VM reboots. Subsequent boots use the
same disk image:

```bash
just vm-run                 # boot existing disk image
just vm-ssh                 # SSH into the installed system (admin@)
just vm-ssh-installer       # SSH into the live ISO context (nixos@)
just vm-clean               # delete the disk image, start over
```

For fast iteration on the binary without a full rebuild:

```bash
just vm-deploy
```

This builds the new binary via `nix build .#nixblitz-unwrapped`,
scp's it to `/tmp/nixblitz` on the VM, and replaces the running
binary in-place. Works for any pure-Dart change; **picks up
template / Nix-module changes too** because the new binary
embeds the latest `templates/` and the TUI auto-detects drift
on launch — the dashboard shows a yellow `[r] Refresh templates`
banner. Press `[r]` to write the binary's templates over disk,
then `[a]` to review the diff and apply. (Pre-drift detection
this required a manual "Refresh Nix templates" action; that's
gone now.)

### Trying the debug menu

`Shift-D` from the dashboard opens the Debug menu. Most entries
are gated on regtest (`features.apps.bitcoind.network = "regtest"`):

- **Generate regtest blocks.** Numeric input (digits append,
  Backspace trims, `↑/↓` switch field). `[g]` to mine. Useful
  for quick "advance the chain by N" testing.
- **Regtest auto-miner (background).** Starts a transient
  systemd unit (`nixblitz-regtest-automine.service`) that mines
  one block on a random `[min, max]` second cadence. Survives
  TUI exit; dies on reboot. Verify with
  `systemctl status nixblitz-regtest-automine.service` from a
  shell or `bitcoin-cli -regtest getblockcount` for the
  end-to-end check.
- **Test LN: status / fund / channel / pay.** Driven against
  the auto-spawned `lnd-test` instance (regtest-only). See
  `templates/modules/system/test-lnd.nix` for the unit
  definition.

## Test, analyze, format

```bash
just test          # all Dart tests across common/ + tui/
just test -t       # same with --enable-asserts (verbose stack traces)
just analyze       # dart analyze across both packages
just format        # dart format across the workspace
```

Tests live in `common/test/`. There are no widget tests for `tui/`
today — UI is exercised manually via `just run-dev` or on the VM.

## Generating embedded templates

When you edit anything under `templates/`, regenerate the embedded
artifact:

```bash
dart run scripts/gen_embedded_templates.dart
# or:
just gen-templates
```

This rewrites `common/lib/src/services/embedded_templates.g.dart`
— a string-literal map of every template file's content. The TUI
ships every template embedded in its binary so a fresh install
doesn't need network access for the Nix files.

If you forget, the binary keeps using the old embedded copy and
you'll wonder why your template change has no effect. **First
debugging step when a Nix change "isn't taking":** check that
`embedded_templates.g.dart` was regenerated.

## Lock files

After changing Dart dependencies (`pubspec.yaml` in the workspace
root or in either package):

```bash
dart pub get               # update pubspec.lock
just gen-locks             # regenerate Nix-side workspace locks
```

`gen-locks` produces JSON the Nix build reads — required for
`nix build .#nixblitz` to find packages.

## Where artifacts land

| Path                                       | What                                                                             |
| ------------------------------------------ | -------------------------------------------------------------------------------- |
| `~/nixblitz/config.json`                   | Single source of truth for the installed system                                  |
| `~/nixblitz/flake.nix`                     | Reads `config.json`, builds the NixOS configuration                              |
| `~/nixblitz/hosts/installed.nix`           | Host config (lives next to the user's settings)                                  |
| `~/nixblitz/plugins/<id>/`                 | Each installed plugin's tree (manifest + plugin.nix + config.json)               |
| `~/nixblitz.log`                           | The TUI's own log (synchronous file append; no IOSink)                           |
| `/run/current-system/sw/bin/nixblitz`      | The system-installed TUI binary (current generation)                             |
| `/var/lib/nixblitz-tui/update-status.json` | Periodic update-checker output; backs the dashboard's "updates available" banner |

The whole `~/nixblitz/` tree is a git repo. Apply commits there;
old generations are recoverable via `git revert`.

## Manual update checks

A daily systemd timer seeds the dashboard banner (see
[architecture.md](architecture.md) → "Periodic update checks"). To
trigger it on demand from a shell:

```bash
nixblitz check     # probe upstream + nix flake update + nvd diff in tmpdir
                   # ~125 MB tarball traffic, 1-10 min on Pi 5
```

For dev runs on a non-NixOS host where `/var/lib/nixblitz-tui/` is
unwritable, redirect both the status file and the staging dir:

```bash
NIXBLITZ_UPDATE_STATUS_PATH=/tmp/nbz-status.json \
NIXBLITZ_STAGING_PATH=/tmp/nbz-staging \
  nixblitz check
cat /tmp/nbz-status.json | jq
ls /tmp/nbz-staging
```

The systemd unit (on the installed system) is
`nixblitz-check.{service,timer}` and can be inspected the usual
way: `systemctl status nixblitz-check`, `systemctl start
nixblitz-check`, `journalctl -u nixblitz-check`.

## Build-host bootstrap

For setting up a workstation that builds nixblitz closures (e.g.
populating an Attic cache via `nix build .#nixosConfigurations.X
.config.system.build.toplevel`) without going through the install
wizard:

```bash
nixblitz init --platform x86  # or --platform pi5
```

Writes the embedded templates + a minimal `config.json` into
`~/nixblitz/` and exits — no TUI launch, no rebuild. Useful for
cachepop hosts and CI runners where the full install flow isn't
appropriate.

## Targeted one-shot updates

`nixblitz update <target>` skips the TUI for the common case where
you already know exactly what you want to roll forward. Three
targets:

```bash
nixblitz update tui       # bump nixblitz flake input + rebuild
nixblitz update plugins   # refresh every auto-update plugin + rebuild
nixblitz update system    # bump every flake input + rebuild
```

All three share the same shape:

1. **Bump:** `nix flake update` (scoped to the target) or
   `PluginService.refreshAll` for `plugins`.
2. **Commit:** the lock bump or plugin marker writes go in as one
   recoverable commit, separable from any later Apply.
3. **Rebuild:** `sudo nixos-rebuild switch` with stdio inherited
   so sudo prompts on your terminal and the rebuild output
   streams through.
4. **Cleanup:** on success, wipes `update-status.json` + `staging/`
   so the next TUI launch reflects current state.

Each refuses if `~/nixblitz/` has uncommitted changes — that
path goes through the TUI's Apply view so the dirty config edit
gets reviewed alongside the bump rather than landing as a side
effect. Operators with a normal mix of pending changes should
keep using Apply (`[a]` from the dashboard); the multi-section
review screen is the safety net.

`update plugins` treats per-plugin failures as non-fatal: pinned
plugins are skipped, and a network failure on one plugin doesn't
sink the rebuild for the others. Exit code reflects whether any
plugin failed, so CI / scripts can branch on success.

## Working with `jj`

The repo uses [Jujutsu](https://github.com/martinvonz/jj) on top
of git. New files are auto-tracked, the working copy is itself a
commit, and `jj split` is way nicer than `git add -p` for
reorganizing diffs.

If you'd rather use plain git, that works too — `jj` interoperates
cleanly. After plain-git operations run `jj git import` to refresh
JJ's view.

A few `jj` cheats:

```bash
jj log             # show commit graph
jj status          # working copy diff vs parent
jj describe        # set commit message
jj split           # split current commit; opens diff editor
jj split <FILES>   # non-interactive: listed files go into the new parent
```

The repo's CLAUDE.md captures one constraint: _new files have to
be committed before `nix build` can see them_ (Nix evaluates
against a snapshot, JJ's auto-tracking doesn't propagate until
commit). If a `nix build` fails with "file not found" right after
you created a new file, that's the cause.

## Submitting changes

The repo lives at `forge.f44.fyi/f44/nixblitz_ng`. Issues + PRs
both go there.

Before pushing:

1. `just analyze && just test` — clean.
2. If you touched anything under `templates/`: `just gen-templates`.
3. If you touched any `pubspec.yaml`: `just gen-locks`.
4. **Commit message style**: imperative subject, short summary,
   reference issue numbers when relevant. See `git log --oneline
-20` for the existing voice.

Commits straight to `main` are the norm for the solo / small-team
phase; expect a PR review process to land later.

## Common gotchas

- **Nocterm doesn't like `StateProvider` updates mid-key-handler.**
  Setting a Riverpod state value triggers a synchronous rebuild;
  the rest of the handler doesn't execute. CLAUDE.md has the long
  version. Short version: do all sync work first, set state last.
- **Async lambdas in key handlers may never run.** Use
  `Process.runSync`, `writeAsStringSync`. Or schedule via `.then()`
  on a future you've already kicked off (the `.then()` callback
  fires after the handler returns; that pattern works).
- **`Expanded` widgets and `const` constructors don't always
  agree.** If you get `const_with_non_const`, drop the `const`.
- **Tests pass locally but fail in CI:** check that you ran
  `just gen-locks` and `just gen-templates` and committed the
  output. The Nix build refuses to consult uncommitted files.
