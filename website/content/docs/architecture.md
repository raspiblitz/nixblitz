---
title: Architecture - NixBlitz
---

# Architecture

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

A short tour of how NixBlitz is laid out, why, and how the pieces
fit together. Aimed at someone arriving from RaspiBlitz or a
similar imperative node-management project, where the mental model
is "scripts that touch the system." NixBlitz is declarative —
the same change shape, but expressed differently.

## The mental model

Three layers, each with one job:

```
┌─────────────────────────────────────────────────────────────┐
│  Dart TUI                                                   │
│  - Renders dashboard / configure / system / debug           │
│    (system splits Updates / Apply / Power on a sidebar)     │
│  - Reads + writes ~/nixblitz/config.json                    │
│  - Carries the NixOS templates embedded in the binary;      │
│    scaffolds ~/nixblitz and rewrites drift after updates    │
│  - Runs `nixos-rebuild switch` to deploy changes            │
└────────────────────────────┬────────────────────────────────┘
                             │ produces / consumes
┌────────────────────────────▼────────────────────────────────┐
│  ~/nixblitz/config.json   (single source of truth)          │
│  - Plain JSON, git-tracked, human-editable                  │
│  - Schema versioned                                         │
└────────────────────────────┬────────────────────────────────┘
                             │ consumed by
┌────────────────────────────▼────────────────────────────────┐
│  NixOS modules  (templates/modules/* + templates/hosts/*)   │
│  - Read config.json via builtins.fromJSON                   │
│  - Declarative service configuration                        │
│  - Rebuild applies them atomically                          │
└─────────────────────────────────────────────────────────────┘
```

The TUI never touches systemd, never edits service config files
on disk, never writes to `/var`. It writes JSON; NixOS turns the
JSON into a system. If the JSON says `bitcoind.enabled = true`,
NixOS makes sure bitcoind is running; if it says `false`, NixOS
stops the unit and removes the on-disk presence. Rebuild output is
streamed to the TUI's **System → Apply** pane — the operator sees
what's changing.

The big architectural difference vs. RaspiBlitz: there's no
"current state" to read off the system to make a decision. The
config is the truth, the system follows. To change anything, you
edit `config.json` and run `nixos-rebuild switch`. NixOS handles
the rest: starting / stopping units, regenerating configs in
`/etc`, opening firewall ports, creating users, mounting disks.

## How `config.json` becomes a NixOS configuration

```
   templates/  (flake.nix, hosts/, modules/, …)
       │
       │  embedded into the nixblitz binary at build time
       ▼
   EmbeddedTemplates.getAll()
       │
       │  first run:           scaffold everything
       │  after a TUI update:  rewrite drifted files
       │  (preflight of every System → Apply rebuild)
       ▼
   ~/nixblitz/          mirror of templates/ on disk
   + config.json        the operator's values (git-tracked)
       │
       ▼
   nixos-rebuild switch --flake ~/nixblitz#nixblitz
       │
       ▼
   NixOS reads config.json via builtins.fromJSON,
   builds derivations, swaps the active generation
```

The flake on disk is a verbatim copy of the embedded templates;
upgrading the TUI propagates template changes by auto-rewriting any
drifted files as a preflight inside **System → Apply**. The
operator never has to trigger a separate "refresh templates" step —
drift just lands in the Apply review alongside their own edits. No
manual file edits.

`config.json` lives at `~/nixblitz/config.json` and is the
single thing the operator changes. The flake's host config calls
`builtins.fromJSON (builtins.readFile ./config.json)` and threads
the result into every module's `enable` flag and option set.

## The Apply transaction

When the operator hits `[a]` Apply (or picks **System → Apply →
Apply pending changes**):

1. **Review**: the TUI shows everything queued for the next
   generation, by category — the `git diff` of `config.json`
   edits, staged upstream pin updates, plugin updates, and any
   auto-applied template refreshes.
2. **Authorize**: a sudo modal prompt opens if the cached sudo
   timestamp lapsed; silent otherwise.
3. **Commit**: `git add -A` + `git commit` (message
   `Apply pending changes`) — creates a recoverable point.
4. **Rebuild**: `sudo nixos-rebuild switch --flake ~/nixblitz#nixblitz`
   streams output line-by-line into the Apply pane.
5. **Classify**: a regex-based outcome classifier reads the rebuild
   output and reports success / partial (some units failed but
   activation finished) / failure.

Rollback: `git revert <apply-commit>` then re-Apply. NixOS
generations also stick around — `sudo nixos-rebuild switch
--rollback` reverts to the previous one even without the TUI.

### Tracking "committed but not applied"

Apply commits before the rebuild runs (so the rebuild has a stable
commit to point at). If the operator quits between the commit and
`nixos-rebuild` exit-0 — `q` instead of `a`, OOM mid-build, SSH
drop — HEAD ends up one commit past `/run/current-system` with no
breadcrumb in the working tree.

To make that state visible:

- After every successful rebuild, the TUI writes
  `~/.local/state/nixblitz/last-applied.json` (HEAD sha + active
  toplevel + flake attr).
- On launch, the dashboard compares that record against
  `git rev-parse HEAD`. When they differ, the node tile sprouts
  an `unapplied rebuild` row + the badge counts it as pending.
  Opening **System → Apply** + hitting `[a]` resolves it (nothing
  to commit, just a rebuild).
- During an in-flight Apply / Update, the global `[q]` quit
  shortcut arms a 3-second window and shows a banner instead of
  exiting immediately. Second `q` quits; any other key cancels
  the arm. Prevents the original fat-finger that motivated the
  whole tracking story.

## Sudo posture

The installed system uses NixOS's default
`security.sudo.wheelNeedsPassword = true`. The TUI authenticates
once per session via a sudo modal:

- First privileged action of a session: modal prompt,
  `sudo -S -v` consumes the password, cached timestamp valid for
  ~5 min (NixOS default).
- A keepalive `Timer.periodic` runs `sudo -n -v` every ~10 min
  in the background — silent, never prompts.
- All privileged calls (`nixos-rebuild`, `chpasswd`, plugin
  unit-actions) prepend `-n`; they reuse the cached timestamp.

Live-ISO context keeps `wheelNeedsPassword = false` via a separate
host module, since install runs before any admin password could
exist.

## The update model

> For the day-to-day operator flow ("which key do I press, what do
> I see, what if it breaks?"), read [Updates](/docs/updates). This
> section is the under-the-hood story for readers who want the
> Nix-shaped model.

The verb "update" covers two things that are fused on Debian-shaped
distros but stay separate here:

```
   upstream HEAD ──┐
                   │ check probes + stages (read-only)
                   ▼
              flake.lock ──┐
                           │ Apply commits + realises
                           ▼
                   /run/current-system
```

- **Check** — re-lock a scratch copy of the flake against upstream
  and compare input **content hashes**, not lock-file bytes
  (offline installs pin inputs as `path:` entries, so a re-lock
  always rewrites the bytes even when nothing moved). When an
  input's content actually moved, the candidate `flake.lock` is
  **staged** under `/var/lib/nixblitz-tui/staging/` — nothing in
  `~/nixblitz/` or on the running system changes yet.
- **Apply** — the single deploy path. Consumes everything queued
  (config edits, the staged lock, plugin updates), commits, and
  runs `nixos-rebuild switch` against the result.

Either half can lag the other:

| What lags                         | Detected by                   | Resolved by              |
| --------------------------------- | ----------------------------- | ------------------------ |
| Working tree dirty (config edits) | `git status` on launch        | Apply                    |
| Upstream moved past `flake.lock`  | Check (stages candidate lock) | Apply                    |
| `/run/current-system` behind HEAD | `last-applied.json` diff      | Apply (no commit needed) |

The `X to apply` badge sums all three. The check never mutates the
running system — it stages a candidate and writes status JSON;
Apply is the only verb that touches anything.

One check, two phases: the **probe** answers _"has upstream
moved?"_ (rev + content-hash comparison per input). The **dry-run**
answers _"what would change if we rebuilt now?"_ via `nix build
--dry-run` against the candidate toplevel — emitting either an
`nvd diff` of package version changes (fast path, every store path
substitutable) or a would-build list of derivations that aren't
(slow path, would compile locally). Both land in the
**What's changing…** viewer on System → Updates.

## Periodic update checks

One systemd timer surfaces pending upstream bumps on the dashboard
without the operator having to trigger a check by hand:
`nixblitz-check.timer` runs `nixblitz check` daily as `User=admin`,
with up to six hours of randomized delay (so a fleet of nodes
doesn't hit the caches in the same minute) and a 30-minute cap (so
a stuck run can't wedge the timer). Each run copies `~/nixblitz/`
to a tmpdir, re-locks it, compares input content hashes, stages the
candidate lock if anything moved, and probes the cache with
`nix build --dry-run`.

The check writes `/var/lib/nixblitz-tui/update-status.json`. The
TUI's node tile reads this file on every render and folds the
result into the `system updates` row + the `<n> to apply` status
badge — no separate banner, just one count that means "there's
stuff to deploy."

The check's dry-run-first shape is a load-bearing refinement:
realising the toplevel just to render a diff used to peg all 4
cores on the Pi 5 for hours when a single derivation was cache-miss
(rustc storms with `page-size-16k` jemalloc rebuilds were the worst
offender). The check bails out before that happens, records the
would-build derivation names, and the Updates panel warns
"Applying builds N packages on the node first" with the full list
inside **What's changing…** — the operator picks the moment to
start the actual compile via Apply.

The CLI verb the timer wraps is exposed for ad-hoc use:
`nixblitz check`. Granular update verbs also survive on the CLI for
scripting (`nixblitz update`, `nixblitz update tui`, `nixblitz
update plugins`); in the TUI they all fold into the check → Apply
pair. **System → Updates → Check for updates** runs the same check
inline and refreshes the panel on exit.

## Templates drift detection

The TUI compares its embedded templates against `~/nixblitz/`
per-key on launch. When drift is detected, it folds into the node
tile's `system updates` row alongside any flake-input bumps — the
operator sees a single "X to apply" indicator rather than a
separate banner. The single Apply path (**System → Apply → Apply
pending changes**) auto-rewrites the drifted files as a preflight
before running `nixos-rebuild`, so drift never has its own
operator-facing concept or keybind to learn.

This is intentionally separate from config-schema migrations
(which run on launch when `config.json`'s `version` field is older
than the binary expects). The two checks are orthogonal — a
templates-only release lands without a schema bump, and the drift
detector catches it.

## Plugin model

Plugins live at `~/nixblitz/plugins/<id>/`, driven by a JSON
manifest, and come in two kinds. A **NixOS-module plugin** pairs the
manifest with a `plugin.nix` that runs as a peer NixOS module at
rebuild time — installing one is a root grant. A **sandboxed WASM
plugin** (schema v5) has no `plugin.nix`: its actions and dashboard
tile run a `wasm32-wasip1` guest inside a wasmtime sandbox (fuel +
wall-clock + WASI, no filesystem or network) that reaches the node
only through one host call gated by a manifest allowlist, so its
blast radius is bounded by what the manifest declares. In both cases
the manifest declares what the operator sees in Configure → plugins →
`<id>`.

For everything plugin-related — manifest reference, the two-stage
`plugin.nix` ABI, the sandboxed WASM actions + tile, the
companion-script pattern, tile state protocol, cross-service
integration — see [the plugin authoring docs](/docs/plugins).

## Nix concepts cheat-sheet

You don't need to learn Nix the language to be productive on
NixBlitz, but a few terms come up often:

- **Flake** — a project that declares its inputs (other flakes
  it depends on, like `nixpkgs`) and outputs (packages, NixOS
  configurations, dev shells). Identified by `flake.nix` at the
  repo root. NixBlitz has two: the TUI flake and the templated
  flake the operator gets installed.
- **Derivation** — a build recipe. Pure inputs (a Bash script,
  some source files, dependency derivations) → reproducible
  output. Identified by a hash. You usually don't write
  derivations directly; you call helpers like `mkDerivation`,
  `writeShellScriptBin`, `buildPythonPackage`.
- **Store** — `/nix/store/`. Every built derivation lives here
  under a hash-prefixed path. Garbage-collected, immutable.
  `which nixblitz` on a NixBlitz VM points into the store.
- **NixOS configuration** — a flake output of type
  `nixosConfigurations.<name>`. Built by
  `nixos-rebuild switch --flake .#<name>`. NixBlitz has two:
  the installed system and the live-ISO context (passwordless
  sudo).
- **`nixos-rebuild switch`** — build the configuration, swap
  the running system to it. Atomic: services are reloaded in a
  single transaction. If activation fails, NixOS rolls back to
  the previous generation on next boot automatically.
- **Generation** — a snapshot of "this is the active system at
  this moment." Cheap because the store is content-addressed:
  generations share unchanged store paths.
- **Module** — a `.nix` file (or `.nix` value) that contributes
  options + config to a NixOS configuration. NixBlitz organizes
  its modules under `templates/modules/` per service.

That's the working set. You'll occasionally hit terms like
"overlay" (replace a package in nixpkgs with a custom version)
and "fixed-output derivation" (a derivation whose output hash you
declare upfront, to allow network access during build); both are
escape hatches you usually don't need.

## What to read next

- [Installation](/docs/installation) — platform install guides
  (Pi 5 / x86).
- [Plugins](/docs/plugins) — write a plugin to wrap a service
  or extension.
