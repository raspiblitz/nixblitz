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
├── wasmtime_dart/           # Pure-Dart FFI bindings to the wasmtime
│                            # C API — the WASM plugin sandbox runtime
├── website/                 # Jaspr docs + marketing site
├── templates/               # NixOS modules + host configs
│   ├── flake.nix            # The flake the TUI installs onto disk
│   ├── hosts/installer.nix  # Live-ISO host config
│   ├── hosts/installed.nix  # Post-install host config
│   ├── modules/system/      # base, disko, operator, test-lnd, update-check
│   └── modules/apps/        # bitcoind, lnd, cln (blitz-api / blitz-web ship as plugins)
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

`pubspec.yaml` at the repo root declares a workspace with four
members: `common/`, `tui/`, `wasmtime_dart/`, and `website/`. They
share resolved versions but are imported separately. `tui` depends on
`common`; `common` depends on `wasmtime_dart` (the WASM sandbox
bindings), third-party packages (`riverpod`, `path`, `http`,
`pub_semver`, `crypto`), and `nocterm` — the last only for its
`Color` value type, not its widget infrastructure, so the "no UI in
common" rule still holds.

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
upgrading the TUI propagates template changes automatically — the
Apply preflight detects drift and rewrites the dirty paths before
the rebuild commits (see "Templates drift detection" below). No
manual file edits required.

`config.json` lives at `~/nixblitz/config.json` and is the
single thing the operator changes. The flake's host config calls
`builtins.fromJSON (builtins.readFile ./config.json)` and threads
the result into every module's `enable` flag and option set.

## The Apply transaction

When the operator hits `[a]` Apply:

1. **Review**: the TUI assembles a single screen listing
   everything queued for the next generation in four sections
   — local config edits (working-tree `git diff`), staged
   upstream pin updates (candidate `flake.lock` from the
   periodic check), staged plugin updates (`plugin-pins.json`),
   and the cached package diff (`nvd diff`). Operator confirms
   with `[a]` or discards with `[d]`.
2. **Authorize**: `SudoSession.ensureFresh()` — modal prompt if
   the cached sudo timestamp lapsed; silent otherwise.
3. **Promote staging**: copy `staging/flake.lock` into the
   working tree; for each entry in `staging/plugin-pins.json`,
   refresh that plugin via `PluginService.refresh` (full clone
   then marker write, signature-checked).
4. **Commit**: `git add -A && git commit -m "Apply pending changes"`
   — captures config edits + lock bump + plugin marker writes
   in one recoverable point.
5. **Rebuild**: `sudo nixos-rebuild switch --flake ~/nixblitz#<attr>`
   streams output line-by-line to the Apply view.
6. **Classify**: a regex-based outcome classifier reads the rebuild
   output and reports success / partial (some units failed but
   activation finished) / failure.
7. **Clear cached state**: on success, the staging dir +
   `update-status.json` get wiped — the cached `CheckResult`
   described a delta we just consumed, so leaving it in place
   would make the dashboard banner lie ("22 packages need
   compile") until the next timer fire.

Rollback: `git revert <apply-commit>` then re-Apply. NixOS
generations also stick around — `sudo nixos-rebuild switch
--rollback` reverts to the previous one even without the TUI.

## State management: Riverpod

The TUI uses [Riverpod](https://riverpod.dev) for reactive state.
A handful of providers do the heavy lifting:

| Provider                                                         | What                                                                                                                                                                                            |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `configProvider`                                                 | The `NixblitzConfig` from `~/nixblitz/config.json`                                                                                                                                              |
| `pendingChangesProvider`                                         | git-diff lines feeding the dashboard's NodeTile `config changes` row                                                                                                                            |
| `templatesDriftProvider`                                         | Snapshot of `EmbeddedTemplates` vs `~/nixblitz/`; populated at TUI launch. Folded into the NodeTile's `system updates` count so drift surfaces as "rebuild needed" alongside flake-input bumps. |
| `gitServiceProvider`                                             | Wraps `git` for diff + commit + reset                                                                                                                                                           |
| `systemServiceProvider`                                          | nixos-rebuild + service-status queries                                                                                                                                                          |
| `pluginServiceProvider`                                          | `plugin add/remove/refresh` machinery                                                                                                                                                           |
| `pluginConfigProvider(dir)`                                      | Per-plugin `config.json` (one per active plugin)                                                                                                                                                |
| `pluginDashboardServiceProvider` / `pluginTileSnapshotsProvider` | Plugin tile pollers + snapshots                                                                                                                                                                 |
| `dashboardDataSourceProvider`                                    | Picks the SSE / null source for built-in tiles. Forwards last-known snapshots across recreates via an internal cache so config-change rebuilds don't blank the tiles.                           |
| `sudoSessionProvider`                                            | Singleton SudoSession (auth state + keepalive)                                                                                                                                                  |

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
`EmbeddedTemplates.getAll()` against `~/nixblitz/` per-key.
Computed once at launch and stashed in `templatesDriftProvider`.
The drift count folds into the NodeTile's `system updates` row
(it bumps the count by 1 with no per-name entry) so the operator
sees a single "X to apply" indicator regardless of whether the
trigger is a flake-input bump, a templates-only release, or both.
Apply auto-rewrites drifted templates as a preflight before
invoking `nixos-rebuild`, so drift never has its own
operator-facing concept or keybind.

This is intentionally separate from config-schema migrations
(which run via `_autoMigrateConfig` on launch when
`config.json`'s `version` field is older than the binary
expects). The two checks are orthogonal — a templates-only
release lands without a schema bump, and the drift detector
catches it.

### Footer hints

The footer text is computed by `_footerHint(view,
{required hasPending})`. `[a]: Apply` only appears when there
are pending changes, keeping the footer terse and preventing
operators from being told about shortcuts that would no-op.

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

A single systemd timer runs on the installed system to surface "X
updates available" on the dashboard and prepare the next Apply
without the operator having to trigger anything:

| Timer                  | Cadence | What it does                                                                                                                                                          |
| ---------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nixblitz-check.timer` | daily   | Probes each flake input + plugin against upstream HEAD, copies `~/nixblitz/` to a tmpdir, runs `nix flake update` + `nix build --dry-run` + `nvd diff`. 1-10 min run. |

Runs as `User=admin` and writes to two locations:

- `/var/lib/nixblitz-tui/update-status.json` — cached `CheckResult`
  (input + plugin movement, nvd diff, would-build list). The TUI
  dashboard reads this on every render and shows a banner above
  the tile grid; absence of the file (fresh install, or wiped
  after a successful Apply) means no banner.
- `/var/lib/nixblitz-tui/staging/` — candidate `flake.lock` +
  `plugin-pins.json` + cached `nvd-diff.txt` + `new-toplevel` +
  `checked-at`. Apply reads these in the review screen and
  promotes them into the working tree as the first step of a
  rebuild. The staging dir is kept independent of the operator's
  flake working tree so a daily timer fire never mutates
  `~/nixblitz/flake.lock` behind the operator's back — the
  "fetched but not yet upgraded" half of an apt-update /
  apt-upgrade split, adapted for nix.

Both paths are created with `admin:users` ownership by
`systemd.tmpfiles` (`templates/modules/system/update-check.nix`).

Module: `templates/modules/system/update-check.nix`. Service:
`common/lib/src/services/update_check_service.dart`. Staging
read/write: `common/lib/src/services/staging_service.dart`. CLI
the timer wraps: `nixblitz check` (no subcommand).

## Plugin model

Plugins live at `~/nixblitz/plugins/<id>/` and come in two kinds,
both driven by a JSON manifest (`plugin.json`):

- **NixOS-module plugins** — a manifest paired with a `plugin.nix`
  that runs as a peer NixOS module at rebuild time. This is the
  original kind (tailscale, lnbits); installing one is a root grant
  (see `docs/decisions/plugins.md` D14).
- **Sandboxed WASM plugins** (schema v5) — logic-only: no
  `plugin.nix`. Their actions and dashboard tile run a `wasm32-wasip1`
  guest inside a wasmtime sandbox (fuel + wall-clock + WASI, no fs /
  network) reaching the node only through one `host_call` import
  gated by a manifest `sandbox` allowlist. The blast radius is
  bounded by the manifest and enforced host-side (D19). `node-summary`
  is the reference; the runtime lives in `wasmtime_dart/` +
  `common/lib/src/services/wasm/`.

For NixOS-module plugins the two-stage `plugin.nix` ABI is the part
that catches every new plugin author:

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

- [getting-started.md](getting-started.md) — contributor dev-VM
  quickstart. For the operator install + first-boot walkthrough see
  `website/content/docs/install-x86.md` /
  `website/content/docs/install-pi5.md`.
- [dev-loop.md](dev-loop.md) — `just` targets, where artifacts
  land, how to iterate.
- [plugin-authoring.md](plugin-authoring.md) — for porting a
  RaspiBlitz feature into a NixBlitz plugin.
- [decisions/plugins.md](decisions/plugins.md) — load-bearing
  architectural decisions (D1 through D18). Read this before
  proposing a redesign of the plugin system.
