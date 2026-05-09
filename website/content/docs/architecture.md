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
│  - Renders dashboard / configure / apply / update / debug   │
│  - Reads + writes ~/nixblitz/config.json                    │
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
streamed to the TUI's Apply view — the operator sees what's
changing.

The big architectural difference vs. RaspiBlitz: there's no
"current state" to read off the system to make a decision. The
config is the truth, the system follows. To change anything, you
edit `config.json` and run `nixos-rebuild switch`. NixOS handles
the rest: starting / stopping units, regenerating configs in
`/etc`, opening firewall ports, creating users, mounting disks.

## How `config.json` becomes a NixOS configuration

```
              templates/                 ┌─ embedded into binary
              ├─ flake.nix       ───────►│  at build time
              ├─ hosts/                  │
              ├─ modules/                │
              └─ ...                     │
                                         ▼
   user runs                ┌─ EmbeddedTemplates.getAll()
   `nixblitz`               │
   first time         ─────►│
                            ▼
                    ScaffoldService.refreshTemplatesSync(baseDir)
                            ▼
                    ~/nixblitz/  (mirror of templates/ on disk)
                    + ~/nixblitz/config.json (user's values)
                            ▼
        nixos-rebuild switch --flake ~/nixblitz#nixblitz
                            ▼
                    NixOS reads config.json via fromJSON,
                    builds derivations, swaps active generation
```

The flake on disk is a verbatim copy of the embedded templates;
upgrading the TUI lets you propagate template changes via
`Update → Refresh templates`. No manual file edits.

`config.json` lives at `~/nixblitz/config.json` and is the
single thing the operator changes. The flake's host config calls
`builtins.fromJSON (builtins.readFile ./config.json)` and threads
the result into every module's `enable` flag and option set.

## The Apply transaction

When the operator hits `[a]` Apply:

1. **Diff**: the TUI shows `git diff` of `~/nixblitz/`. Both
   `config.json` edits and any auto-applied template refreshes
   appear as a unified diff.
2. **Authorize**: a sudo modal prompt opens if the cached sudo
   timestamp lapsed; silent otherwise.
3. **Commit**: `git add -A && git commit -m "Apply settings"` —
   creates a recoverable point.
4. **Rebuild**: `sudo nixos-rebuild switch --flake ~/nixblitz#nixblitz`
   streams output line-by-line to the Apply view.
5. **Classify**: a regex-based outcome classifier reads the rebuild
   output and reports success / partial (some units failed but
   activation finished) / failure.

Rollback: `git revert <apply-commit>` then re-Apply. NixOS
generations also stick around — `sudo nixos-rebuild switch
--rollback` reverts to the previous one even without the TUI.

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

## Periodic update checks

Two systemd timers run on the installed system to surface "X
updates available" on the dashboard without the operator having to
trigger an Update flow:

| Timer                        | Cadence | What it does                                                                                                                           |
| ---------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `nixblitz-check-light.timer` | daily   | Calls each flake input's upstream API (GitHub / Forgejo) for the branch HEAD; compares to our locked rev. ~5 HTTP calls, ~kB transfer. |
| `nixblitz-check-heavy.timer` | weekly  | Copies `~/nixblitz/` to a tmpdir, runs `nix flake update` + `nix eval` + `nvd diff` there. ~125 MB tarball fetch + 30-60s eval.        |

Both run as `User=admin` and write to
`/var/lib/nixblitz-tui/update-status.json`. The TUI dashboard
reads this file on every render and shows a banner above the tile
grid; absence of the file (fresh install) means no banner.

CLI invocations the timer wraps: `nixblitz check light` and
`nixblitz check heavy`.

## Templates drift detection

The TUI compares its embedded templates against `~/nixblitz/`
per-key on launch. When drift is detected, it folds into the
dashboard's NodeTile `system updates` row alongside any
flake-input bumps — the operator sees a single "X to apply"
indicator rather than a separate banner. Apply (`[a]`) and Update
(`[u]`) both auto-rewrite the drifted files as a preflight before
running `nixos-rebuild`, so drift never has its own operator-facing
concept or keybind to learn.

This is intentionally separate from config-schema migrations
(which run on launch when `config.json`'s `version` field is older
than the binary expects). The two checks are orthogonal — a
templates-only release lands without a schema bump, and the drift
detector catches it.

## Plugin model

Plugins are NixOS modules + a JSON manifest, living at
`~/nixblitz/plugins/<id>/`. The manifest declares what the user
sees in Configure → plugins → `<id>`; the `plugin.nix` declares
what NixOS does at rebuild time.

For everything plugin-related — manifest reference, the two-stage
`plugin.nix` ABI, the companion-script pattern, tile state
protocol, cross-service integration — see
[the plugin authoring docs](/docs/plugins).

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

- [Installation](/docs/installation) — install + first-boot
  walkthrough.
- [Plugins](/docs/plugins) — write a plugin to wrap a service
  or extension.
