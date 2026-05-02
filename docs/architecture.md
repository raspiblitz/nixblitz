# Architecture

> Operator-facing version lives at `website/content/docs/architecture.md`;
> keep them in sync when editing. The website version drops dev-internal
> sections (Riverpod providers, Dart workspace).

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
│  Dart TUI  (common/ + tui/)                                 │
│  - Renders dashboard / configure / apply / update           │
│  - Reads + writes ~/nixblitz/config.json                    │
│  - Runs `nixos-rebuild switch` to deploy changes            │
└────────────────────────────┬────────────────────────────────┘
                             │ produces / consumes
┌────────────────────────────▼────────────────────────────────┐
│  ~/nixblitz/config.json   (single source of truth)          │
│  - Plain JSON, git-tracked, human-editable                  │
│  - Schema versioned (v14 today; migrations in code)         │
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

## Repo layout

```
nixblitz/
├── pubspec.yaml             # Dart workspace root
├── flake.nix                # Nix package + dev-shell + apps
├── justfile                 # `just <target>` task runner
├── docs/                    # what you're reading
├── common/                  # Pure Dart business logic
│   ├── lib/src/
│   │   ├── models/          # NixblitzConfig, ServiceStatus, Plugin*
│   │   ├── services/        # ConfigService, GitService, SystemService,
│   │   │                    # SudoSession, PluginService, …
│   │   └── providers/       # Riverpod providers
│   └── test/
├── tui/                     # nocterm UI on top of common/
│   ├── bin/nixblitz.dart    # Production entry point
│   ├── bin/nixblitz_dev.dart# Dev entry (widget previews)
│   └── lib/src/ui/          # Views + widgets
├── templates/               # NixOS modules + host configs
│   ├── flake.nix            # The flake the TUI installs onto disk
│   ├── hosts/installer.nix  # Live-ISO host config
│   ├── hosts/installed.nix  # Post-install host config
│   ├── modules/system/      # base, disko, operator, test-lnd, update-check
│   └── modules/apps/        # bitcoind, lnd, cln, blitz-api, blitz-web
├── scripts/                 # Codegen helpers
│   └── gen_embedded_templates.dart
└── examples_redesign/       # Vendored references (gitignored)
```

The strict rule: only `common/` calls `Process.start` or
`Process.runSync`. The `tui/` package has zero direct system
access — it goes through services in `common/`. Makes the TUI
easy to preview-test (no real services needed) and the services
unit-testable (no nocterm / Riverpod entanglement).

## The Dart workspace

`pubspec.yaml` at the repo root declares a workspace; `common/`
and `tui/` are member packages. They share resolved versions but
are imported separately. `tui` depends on `common`; `common`
depends only on third-party packages (`riverpod`, `path`, `http`).

Running tests:

```bash
just test          # walks both packages
```

Running the TUI:

```bash
just run           # production binary
just run-dev       # widget previews — see dev-loop.md
```

## How `config.json` becomes a NixOS configuration

```
              templates/                 ┌─ embedded into binary
              ├─ flake.nix       ───────►│  via gen_embedded_
              ├─ hosts/                  │  templates.dart at
              ├─ modules/                │  build time
              └─ ...                     │
                                         ▼
                              ┌─ EmbeddedTemplates.getAll()
   user runs                  │  in common/lib/src/services/
   `nixblitz`                 │  embedded_templates.g.dart
   first time           ─────►│
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
`Update → Refresh Nix templates`. No manual file edits.

`config.json` lives at `~/nixblitz/config.json` and is the
single thing the operator changes. The flake's host config calls
`builtins.fromJSON (builtins.readFile ./config.json)` and threads
the result into every module's `enable` flag and option set.

## The Apply transaction

When the operator hits `[a]` Apply:

1. **Diff**: the TUI shows `git diff` of `~/nixblitz/`. Both
   `config.json` edits and any auto-applied template refreshes
   appear as a unified diff.
2. **Authorize**: `SudoSession.ensureFresh()` — modal prompt if
   the cached sudo timestamp lapsed; silent otherwise.
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

## State management: Riverpod

The TUI uses [Riverpod](https://riverpod.dev) for reactive state.
A handful of providers do the heavy lifting:

| Provider                                                         | What                                                                                                                                                                  |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `configProvider`                                                 | The `NixblitzConfig` from `~/nixblitz/config.json`                                                                                                                    |
| `pendingChangesProvider`                                         | git-diff lines for the dashboard's "pending" banner                                                                                                                   |
| `templatesDriftProvider`                                         | Snapshot of `EmbeddedTemplates` vs `~/nixblitz/`; populated at TUI launch, drives the dashboard's "[r] refresh" banner                                                |
| `gitServiceProvider`                                             | Wraps `git` for diff + commit + reset                                                                                                                                 |
| `systemServiceProvider`                                          | nixos-rebuild + service-status queries                                                                                                                                |
| `pluginServiceProvider`                                          | `plugin add/remove/refresh` machinery                                                                                                                                 |
| `pluginConfigProvider(dir)`                                      | Per-plugin `config.json` (one per active plugin)                                                                                                                      |
| `pluginDashboardServiceProvider` / `pluginTileSnapshotsProvider` | Plugin tile pollers + snapshots                                                                                                                                       |
| `dashboardDataSourceProvider`                                    | Picks the SSE / null source for built-in tiles. Forwards last-known snapshots across recreates via an internal cache so config-change rebuilds don't blank the tiles. |
| `sudoSessionProvider`                                            | Singleton SudoSession (auth state + keepalive)                                                                                                                        |

All UI components watch via `context.watch(provider)`; one-shot
reads use `context.read(provider)`.

### Dashboard tile freshness

Built-in tiles (System, Hardware, Bitcoin, Lightning) are seeded
from two sources to avoid the "waiting for event…" flash:

- **REST prime on data-source startup.** `ApiDashboardSource`
  fires fire-and-forget GETs against `/bitcoin/btc-info`,
  `/lightning/get-info`, `/lightning/get-balance`,
  `/system/get-system-info`, `/system/hardware-info` and feeds
  responses through the same `_dispatchEvent` parser SSE uses.
  First render usually has data within a few hundred ms even on
  a cold start.
- **Process-lifetime snapshot cache.** `dashboardDataSourceProvider`
  watches `configProvider`; any config change recomputes it and
  spins up a fresh data source. Without help, this would blank
  every tile back to "loading". The provider keeps a private
  `_SnapshotCache` for the ProviderScope lifetime; subscriptions
  on the active source's broadcast streams keep the cache fresh,
  and each recreate seeds the new source from it.

### Templates drift detection

`detectTemplatesDrift(baseDir)` compares the binary's
`EmbeddedTemplates.getAll()` against the on-disk
`~/nixblitz/templates/` per-key. Computed once at launch and
stashed in `templatesDriftProvider`. When non-empty, the
dashboard surfaces a yellow banner and the footer adds `[r]:
Refresh templates`; pressing `[r]` runs `refreshTemplatesSync()`
and routes to the apply view so the operator reviews the diff
before committing.

This is intentionally separate from config-schema migrations
(which run via `_autoMigrateConfig` on launch when
`config.json`'s `version` field is older than the binary
expects). The two checks are orthogonal — a templates-only
release lands without a schema bump, and the drift detector
catches it.

### Footer hints

The footer text is computed by `_footerHint(view, hasPending,
hasDrift)`. Some keybinds only appear when their action is
actually applicable: `[a]: Apply` only when there are pending
changes, `[r]: Refresh templates` only when drift is detected.
This keeps the footer terse and prevents operators from being
told about shortcuts that would no-op.

## SudoSession (sudo posture)

The installed system uses NixOS's default
`security.sudo.wheelNeedsPassword = true`. The TUI authenticates
via `SudoSession`:

- First time the operator triggers a privileged action, a modal
  prompt opens. `sudo -S -v` consumes the password, cached
  timestamp is valid for ~5 min (NixOS default).
- A keepalive `Timer.periodic` runs `sudo -n -v` every ~10 min
  in the background — silent, never prompts.
- All privileged calls (`nixos-rebuild`, `chpasswd`, plugin
  unit-actions) prepend `-n`; they reuse the cached timestamp.

The full design is in `docs/decisions/plugins.md` D18. Live ISO
keeps `wheelNeedsPassword = false` via a separate host module
(`templates/hosts/installer.nix`), since install runs before any
admin password could exist.

## Periodic update checks

Two systemd timers run on the installed system to surface "X
updates available" on the dashboard without the operator having to
trigger an Update flow:

| Timer                        | Cadence | What it does                                                                                                                           |
| ---------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `nixblitz-check-light.timer` | daily   | Calls each flake input's upstream API (GitHub / Forgejo) for the branch HEAD; compares to our locked rev. ~5 HTTP calls, ~kB transfer. |
| `nixblitz-check-heavy.timer` | weekly  | Copies `~/nixblitz/` to a tmpdir, runs `nix flake update` + `nix eval` + `nvd diff` there. ~125 MB tarball fetch + 30-60s eval.        |

Both run as `User=admin` and write to
`/var/lib/nixblitz-tui/update-status.json` (created with
`admin:users` ownership by `systemd.tmpfiles`). The TUI dashboard
reads this file on every render and shows a banner above the tile
grid; absence of the file (fresh install) means no banner.

Module: `templates/modules/system/update-check.nix`. Service:
`common/lib/src/services/update_check_service.dart`. CLI invocations
the timer wraps: `nixblitz check light` and `nixblitz check heavy`.

## Plugin model

Plugins are NixOS modules + a JSON manifest, living at
`~/nixblitz/plugins/<id>/`. The manifest declares what the user
sees in Configure → plugins → `<id>`; the `plugin.nix` declares
what NixOS does at rebuild time.

The two-stage `plugin.nix` ABI is the part that catches every new
plugin author:

```nix
{ pluginCfg ? {} }: { config, lib, pkgs, ... }: {
  # ...your plugin module...
}
```

The **outer** function receives `pluginCfg` (the plugin's own
`config.json`) via closure; the **inner** function is a normal
NixOS module. The reason it's two-stage: NixOS's module system
silently routes every named arg through `_module.args.<name>`,
which is a global namespace. Two plugins both declaring
`pluginCfg` as a module arg would collide with
`_module.args.pluginCfg' is defined multiple times`. The
two-stage shape isolates each plugin's config in a closure.

For everything else plugin-related — manifest reference, the
companion-script pattern, tile state protocol, cross-service
integration — see [plugin-authoring.md](plugin-authoring.md).

## Nix concepts cheat-sheet

You don't need to learn Nix the language to be productive on
NixBlitz, but a few terms come up often:

- **Flake** — a project that declares its inputs (other flakes
  it depends on, like `nixpkgs`) and outputs (packages, NixOS
  configurations, dev shells). Identified by `flake.nix` at the
  repo root. NixBlitz has two: the TUI flake (`./flake.nix`) and
  the templated flake the operator gets installed (`templates/flake.nix`).

- **Derivation** — a build recipe. Pure inputs (a Bash script,
  some source files, dependency derivations) → reproducible
  output. Identified by a hash. You usually don't write
  derivations directly; you call helpers like `mkDerivation`,
  `writeShellScriptBin`, `buildPythonPackage`.

- **Store** — `/nix/store/`. Every built derivation lives here
  under a hash-prefixed path. Garbage-collected, immutable.
  `which nixblitz` on a NixBlitz VM points into the store.

- **NixOS configuration** — a flake output of type
  `nixosConfigurations.<name>`. Built by `nixos-rebuild switch
--flake .#<name>`. NixBlitz has two:
  `nixosConfigurations.nixblitz` (the installed system) and
  `nixosConfigurations.nixblitz-installer` (the live-ISO context;
  passwordless sudo).

- **`nixos-rebuild switch`** — build the configuration, swap
  the running system to it. Atomic: services are reloaded in a
  single transaction. If activation fails, NixOS rolls back to
  the previous generation on next boot automatically.

- **Generation** — a snapshot of "this is the active system at
  this moment." `nix-env --list-generations --profile
/nix/var/nix/profiles/system` lists them; GRUB's boot menu
  shows a few back. Cheap because the store is content-addressed:
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

- [getting-started.md](getting-started.md) — install + first-boot
  walkthrough.
- [dev-loop.md](dev-loop.md) — `just` targets, where artifacts
  land, how to iterate.
- [plugin-authoring.md](plugin-authoring.md) — for porting a
  RaspiBlitz feature into a NixBlitz plugin.
- [decisions/plugins.md](decisions/plugins.md) — load-bearing
  architectural decisions (D1 through D18). Read this before
  proposing a redesign of the plugin system.
