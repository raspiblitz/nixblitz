# NixBlitz Redesign: Dart TUI + Dendritic NixOS Modules

**Date:** 2026-04-20
**Status:** Draft

## Motivation

The current NixBlitz is over-engineered for its purpose. A 6-crate Rust workspace with two WebSocket servers, a Dioxus web UI, and Handlebars template generation is too much machinery for what is fundamentally: help a user install and configure a Bitcoin/Lightning node on NixOS without touching Nix.

Rust compile times slow iteration. The multi-crate architecture adds cognitive overhead. The WebSocket engines solve a problem (decouple UI from backend) that doesn't exist when the TUI runs directly on the target machine.

## Goals

- Let users set up a Bitcoin/Lightning NixOS node via a TUI over SSH
- Configure the system without touching Nix files
- Track every configuration change in git for rollback and audit
- Keep the architecture simple enough that a single developer can maintain it
- Structure the code so a web UI can be added later without rewriting core logic
- Support installation from a stock NixOS ISO via `nix flake run github:user/nixblitz`

## Non-Goals

- Web UI (deferred, but architecture accommodates it)
- Desktop or mobile targets
- Plugin system
- Exposing every possible NixOS option (only high-impact choices; power users edit JSON directly)

## Architecture Overview

The redesigned NixBlitz has two components:

1. **A Dart TUI** — all user interaction, runs system commands directly
2. **A Nix flake** (`~/nixblitz/` on the target machine) — git-tracked config repo with dendritic NixOS modules

No daemons, no WebSocket servers, no Rust.

The TUI never calls system commands directly. All system interaction goes through the `common` package, which provides service abstractions for config management, git operations, installation, and system rebuilds. This separation is what enables a future web UI to reuse the same logic — `common` is the only package that knows about `Process.start()`, `disko`, `nixos-rebuild`, etc.

```
+-------------------------------------+
|         Dart TUI (tui package)      |
|  nocterm + Riverpod, runs over SSH  |
|  UI only — no direct system calls   |
+------------------+------------------+
                   |
          uses common package API
                   |
                   v
+-------------------------------------+
|      Business Logic (common pkg)    |
|  ConfigService, SystemService,      |
|  GitService, InstallService         |
+----------+--+------------+----------+
           |  |            |
    Process.start()   Process.start()
     (install)     (configure/status)
           |  |            |
           v  v            v
  +----------------+  +----------------+
  | disko          |  | nixos-rebuild  |
  | nixos-install  |  | systemctl      |
  | git            |  | git            |
  +----------------+  +----------------+
           |               |
           v               v
  +-------------------------------------+
  |       ~/nixblitz/ (git repo)        |
  |  config.json + flake.nix + modules  |
  |  Dendritic pattern, auto-discovery  |
  +-------------------------------------+
```

### Entry Points

**New installation** (from any NixOS ISO):

```bash
nix flake run github:user/nixblitz
```

**Existing system** (SSH in):

```bash
nixblitz
```

## Dart Workspace Structure

The Dart code is organized as a workspace to allow a future web UI to share core logic. Only `common` and `tui` are built initially.

```
github:user/nixblitz
|-- pubspec.yaml                  # Workspace root
|-- common/                       # Shared logic package
|   |-- pubspec.yaml
|   +-- lib/
|       |-- models/               # NixblitzConfig, ServiceStatus, InstallState
|       |-- services/             # ConfigService, SystemService, GitService
|       +-- providers/            # Riverpod providers for config, services
|-- tui/                          # TUI package (UI only)
|   |-- pubspec.yaml              # depends on: common
|   |-- bin/nixblitz.dart         # Entry point
|   +-- lib/src/
|       |-- ui/                   # Views, widgets (nocterm components)
|       +-- providers/            # UI-specific providers (selection, focus)
|-- templates/                    # Scaffolding for ~/nixblitz/
|   |-- flake.nix                 # Template flake with findModules
|   |-- hosts/default.nix         # Template host config
|   |-- modules/system/           # base.nix, hardware.nix
|   |-- modules/apps/             # bitcoind.nix, lnd.nix, cln.nix, etc.
|   +-- hardware/                 # pi4.nix, pi5.nix, x86.nix, vm.nix
|-- nix/                          # Nix build files
|   |-- tui_pkg.nix
|   |-- workspace_pubspec.lock.json
|   +-- workspace_dependency_graph.json
|-- flake.nix                     # Builds tui, exposes as nix package
+-- docs/
```

**Package responsibilities:**

- **`common`** — all business logic and system interaction. Config model (typed representation of config.json), JSON read/write, git operations, and service abstractions that wrap system commands (`disko`, `nixos-install`, `nixos-rebuild`, `systemctl`). This is the only package that calls `Process.start()`. No TUI dependency. A future web UI server would depend on this same package.
- **`tui`** — nocterm + Riverpod UI layer. All views, widgets, and UI-specific state. Depends on `common`. Never calls system commands directly — all system interaction goes through `common`'s service APIs.

**Nix build note:** requires a custom nixpkgs fork with Dart workspace support until the upstream PR is merged. The flake uses this as an input, following the same pattern as the radrss example.

## TUI Framework & Patterns

Based on the Port Surgeon example (`examples_redesign/port_surgeon/`):

- **TUI framework:** nocterm (component-based terminal rendering)
- **State management:** Riverpod (reactive providers, same as Flutter ecosystem)
- **Navigation:** Vim-style keybindings (j/k, gg/G, Enter, Esc, /)
- **Architecture:** models / services / providers / ui layer separation

### TUI Source Layout

```
tui/lib/src/
|-- models/
|   +-- install_state.dart         # Installer state machine states
|-- providers/
|   +-- ui_state_provider.dart     # Navigation, selection, focus
|-- ui/
|   |-- app.dart                   # Root app, top-level router
|   |-- views/
|   |   |-- dashboard_view.dart    # Service status overview (home screen)
|   |   |-- configure_view.dart    # Edit config options per service
|   |   |-- install_view.dart      # Guided installer
|   |   |-- setup_view.dart        # First boot setup (passwords, seeds)
|   |   +-- apply_view.dart        # Shows nixos-rebuild progress
|   +-- widgets/
|       |-- service_card.dart      # Status indicator for one service
|       |-- option_editor.dart     # Toggle/select/input for config values
|       +-- help_popup.dart        # Contextual help
+-- main.dart
```

### Common Source Layout

```
common/lib/
|-- models/
|   |-- nixblitz_config.dart       # Typed representation of config.json
|   +-- service_status.dart        # systemctl service state
|-- services/
|   |-- config_service.dart        # JSON read/write + git commit
|   |-- system_service.dart        # Runs nixos-rebuild, systemctl, disko
|   +-- git_service.dart           # Git init, commit, revert
+-- providers/
    |-- config_provider.dart       # Reads/writes config.json
    +-- service_status_provider.dart  # Polls systemctl
```

## Config System (`~/nixblitz/`)

Generated during installation, this directory is a git-tracked Nix flake that the TUI manages. The user never edits Nix files — the TUI writes `config.json` and NixOS modules read from it.

### Directory Layout

```
~/nixblitz/
|-- flake.nix              # Auto-discovers modules via findModules
|-- flake.lock
|-- config.json            # The only file the TUI edits
|-- hosts/
|   +-- default.nix        # Reads config.json, sets features.*.enable
|-- modules/
|   |-- system/
|   |   |-- base.nix       # Nix settings, core tools, users
|   |   +-- hardware.nix   # Platform-specific config
|   +-- apps/
|       |-- bitcoind.nix   # features.apps.bitcoind
|       |-- lnd.nix        # features.apps.lnd
|       |-- cln.nix        # features.apps.cln
|       |-- blitz-api.nix  # features.apps.blitz-api
|       +-- blitz-web.nix  # features.apps.blitz-web
+-- hardware/
    |-- pi4.nix
    |-- pi5.nix
    |-- x86.nix
    +-- vm.nix
```

### Dendritic Module Pattern

Adopted from the folio example (`examples_redesign/folio/`). Key properties:

- **Auto-discovery:** `flake.nix` contains a recursive `findModules` function that walks `modules/` and imports every `.nix` file automatically. No manual import lists.
- **Feature namespace:** Each module registers options under `features.<category>.<name>`. Adding a new service = drop a `.nix` file in `modules/apps/`, no flake.nix changes needed.
- **Host config as bridge:** `hosts/default.nix` reads `config.json` and maps values to the feature namespace.

### config.json

Flat, minimal, only high-impact options:

```json
{
  "initialized": false,
  "system": {
    "hostname": "nixblitz",
    "timezone": "Europe/Berlin",
    "platform": "pi4"
  },
  "bitcoind": {
    "enabled": true,
    "network": "mainnet",
    "pruned": true,
    "prune_size_gb": 550
  },
  "lnd": {
    "enabled": true,
    "alias": "my-node"
  },
  "cln": {
    "enabled": false
  },
  "blitz_api": {
    "enabled": true
  },
  "blitz_web": {
    "enabled": true
  }
}
```

Advanced users can edit this file directly. The TUI picks up external changes on next launch.

### How Nix Reads It

`hosts/default.nix` is the bridge between JSON and the module system:

```nix
{ config, lib, pkgs, ... }:
let
  cfg = builtins.fromJSON (builtins.readFile ../config.json);
in {
  features.apps.bitcoind.enable = cfg.bitcoind.enabled;
  features.apps.bitcoind.network = cfg.bitcoind.network;
  features.apps.lnd.enable = cfg.lnd.enabled;
  features.apps.cln.enable = cfg.cln.enabled;
  features.apps.blitz-api.enable = cfg.blitz_api.enabled;
  features.apps.blitz-web.enable = cfg.blitz_web.enabled;
  # system-level options mapped similarly
}
```

Each module is self-contained:

```nix
# modules/apps/bitcoind.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.features.apps.bitcoind;
in {
  options.features.apps.bitcoind = {
    enable = lib.mkEnableOption "Bitcoin daemon";
    network = lib.mkOption { default = "mainnet"; };
  };
  config = lib.mkIf cfg.enable {
    services.bitcoind = {
      enable = true;
      network = cfg.network;
      # sensible defaults for everything else
    };
  };
}
```

### Git Workflow

Every config change is a commit:

1. TUI writes updated `config.json`
2. `git add config.json && git commit -m "bitcoind: switch to mainnet"`
3. `sudo nixos-rebuild switch --flake ~/nixblitz`
4. On failure: `git revert HEAD` restores previous config

Commit messages are auto-generated from what changed.

## TUI Modes of Operation

The TUI has four modes, determined by system state on launch:

### 1. Install Mode

**Triggers when:** booted from live ISO, no `~/nixblitz/` exists.

Steps:

1. **System check** — detect platform (pi4/pi5/x86/vm), RAM, available disks
2. **Disk selection** — user picks target disk, confirms destructive operation
3. **Initial configuration** — hostname, timezone, network (mainnet/testnet), which services to enable
4. **Write config** — scaffold `~/nixblitz/` from templates, write `config.json` with `initialized: false`, `git init` + initial commit
5. **Partition + install** — run `disko`, then `nixos-install --flake ~/nixblitz`, copy `~/nixblitz/` to the same path (`~/nixblitz/`) on the installed system's root filesystem
6. **Reboot** — prompt user to reboot into installed system

All privileged operations are abstracted behind `common`'s service layer (which uses `Process.start()` internally). The user is root or has passwordless sudo on the live ISO.

### 2. First Boot Setup Mode

**Triggers when:** `~/nixblitz/config.json` exists with `initialized: false`.

This runs once after the first boot of the installed system. Services are running but not yet initialized.

Steps:

1. **System password** — set user password for SSH access
2. **Bitcoin wallet** — wait for bitcoind readiness, initialize wallet
3. **Lightning wallet** — generate or restore seed, set unlock password
4. **Blitz API credentials** — generate API keys
5. **Summary** — display credentials, remind user to back up seed
6. **Mark complete** — set `initialized: true` in config.json, git commit

Each step is sequential — LND setup waits for bitcoind to be ready. The TUI shows progress and waits for services between steps.

This is the only time the TUI handles secrets. After initialization, configure mode only touches service configuration.

### 3. Configure Mode

**Triggers when:** user selects "Configure" from dashboard.

```
Select service:  > bitcoind
                   lnd
                   cln
                   blitz-api
                   blitz-web

bitcoind:
  network:  [mainnet v]
  pruned:   [x]
  prune_gb: [550    ]

[Enter] save  [Esc] back
```

On save: write config.json, git commit, run `sudo nixos-rebuild switch --flake ~/nixblitz`. Stream rebuild output in the apply view. On failure: `git revert HEAD`, show error.

### 4. Dashboard Mode (Default)

**Triggers when:** `initialized: true`, normal operation.

```
NixBlitz v0.1.0                        pi4 | mainnet

bitcoind:   * running     lnd:        * running
cln:        - disabled    blitz-api:  * running
blitz-web:  * running

[c]onfigure  [?]help
```

Shows live service status by polling `systemctl`. Vim-style navigation.

## Services in Scope

Feature parity with current Rust implementation, with reduced option exposure:

| Service   | Key Options (TUI)                                                | Everything Else                   |
| --------- | ---------------------------------------------------------------- | --------------------------------- |
| bitcoind  | enabled, network (mainnet/testnet/signet), pruned, prune_size_gb | sensible defaults in NixOS module |
| lnd       | enabled, alias                                                   | sensible defaults                 |
| cln       | enabled                                                          | sensible defaults                 |
| blitz-api | enabled                                                          | sensible defaults                 |
| blitz-web | enabled                                                          | sensible defaults                 |
| system    | hostname, timezone, platform                                     | sensible defaults                 |

Advanced users who need more control edit `config.json` directly. The NixOS modules can expose additional options that aren't surfaced in the TUI.

## Supported Platforms

- Raspberry Pi 4
- Raspberry Pi 5
- x86_64
- VM (QEMU)

Platform is auto-detected during install and stored in `config.json`. Hardware-specific Nix configs live in `templates/hardware/`.

## What Gets Deleted

The entire current Rust codebase:

- `nixblitz-cli/crates/` — all 6 crates (nixblitz_cli, nixblitz_core, nixblitz_system, nixblitz_installer_engine, nixblitz_system_engine, nixblitz_norupo)
- `nixblitz-cli/justfile`, `Cargo.toml`, workspace config
- `nixblitz-installer/` — replaced by the TUI's install mode

## What Gets Kept/Transformed

- **NixOS module logic** — rewritten as dendritic modules in `templates/modules/`, reading from config.json instead of Handlebars output
- **Hardware configs** — moved to `templates/hardware/`
- **nixblitz-docs/** — kept as-is, content updated later
- **Domain knowledge** — the service configuration logic (what options bitcoind/lnd/cln need, how they interact) carries forward into the new NixOS modules and config model

## Future: Adding a Web UI

The workspace structure is designed for this. When the time comes:

```
pubspec.yaml
  workspace:
    - common        # already exists
    - tui           # already exists
    - server        # new: serves API for web UI
    - web           # new: web frontend
```

`server` and `web` depend on `common`, sharing all config/service/git logic. The TUI and web UI become interchangeable frontends to the same data.

## Open Questions

None — all design decisions have been resolved through brainstorming.
