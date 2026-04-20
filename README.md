# NixBlitz

A TUI for installing and managing a Bitcoin/Lightning node on NixOS. Boot any NixOS ISO, run one command, and get a fully configured node — without touching Nix.

## What It Does

NixBlitz guides you through:

1. **Installation** — Select a disk, partition it, and install NixOS with Bitcoin/Lightning services
2. **First Boot Setup** — Set your SSH password, wait for services to start, initialize wallets
3. **Ongoing Management** — Enable/disable services, change network settings, apply config changes

All configuration is stored in a single `config.json` file, tracked by git for automatic rollback. NixOS modules read this file directly — you never edit `.nix` files.

## Supported Services

| Service | Description |
|---------|-------------|
| bitcoind | Bitcoin Core daemon (mainnet/testnet/signet, pruned or full) |
| LND | Lightning Network Daemon |
| CLN | Core Lightning |
| Blitz API | RaspiBlitz API |
| Blitz Web | RaspiBlitz Web UI |

## Supported Platforms

- Raspberry Pi 4
- Raspberry Pi 5
- x86_64
- QEMU VM

## Quick Start

### Install on a New Machine

Boot a NixOS ISO (any recent 25.11 image), then:

```bash
# nix run github:fusion44/nixblitz --experimental-features "nix-command flakes" --no-write-lock-file
nix run git+https://forge.f44.fyi/f44/nixblitz_ng --experimental-features "nix-command flakes" --no-write-lock-file --refresh
```

The TUI walks you through disk selection, initial configuration, and installation. After reboot, SSH in and run `nixblitz` to complete setup.

### Manage an Existing System

```bash
nixblitz
```

The dashboard shows service status. Press `c` to configure, then apply changes with a single keypress. Every change is git-committed and applied via `nixos-rebuild switch`.

## How It Works

```
+---------------------------------+
|     Dart TUI (nixblitz)         |
|  nocterm + Riverpod, over SSH   |
+----------------+----------------+
                 |
        common package API
                 |
                 v
+---------------------------------+
|    Business Logic (common)      |
|  Config, Git, System, Install   |
+--------+-----------+------------+
         |           |
   Process.start()   |
         |           |
    +---------+  +----------+
    | disko   |  | nixos-   |
    | lsblk   |  | rebuild  |
    | git     |  | systemctl|
    +---------+  +----------+
         |           |
         v           v
+---------------------------------+
|     ~/nixblitz/ (git repo)      |
|  config.json + NixOS modules    |
+---------------------------------+
```

The TUI is a thin UI layer. All business logic lives in the `common` package, which is the only code that calls system commands. This separation means a web UI can reuse the same logic later.

The `~/nixblitz/` directory on the target machine is a Nix flake with [dendritic module auto-discovery](https://forge.f44.fyi/f44/nixblitz_ng/blob/main/templates/flake.nix) — adding a new service module is just dropping a `.nix` file in `modules/apps/`.

## Development

### Prerequisites

- Dart SDK 3.11+ (provided by `devenv` or `nix develop`)
- `just` task runner
- `nu` (nushell) for justfile scripts

Enter the dev shell:

```bash
devenv shell
# or
nix develop
```

### Common Commands

```bash
just test          # Run all tests
just analyze       # Dart analyze both packages
just format        # Dart format all code
just run           # Run the TUI locally
just gen-locks     # Regenerate Nix lock files (after dart pub get)
```

### Project Structure

```
nixblitz/
|-- pubspec.yaml              # Dart workspace root
|-- common/                   # Shared business logic (no UI)
|   |-- lib/src/models/       # NixblitzConfig, ServiceStatus, InstallState
|   |-- lib/src/services/     # ConfigService, GitService, SystemService, InstallService
|   |-- lib/src/providers/    # Riverpod providers
|   +-- test/                 # Unit tests (29 tests)
|-- tui/                      # Terminal UI (nocterm + Riverpod)
|   |-- bin/nixblitz.dart     # Entry point
|   +-- lib/src/ui/           # Views and widgets
|-- templates/                # NixOS flake scaffolded to ~/nixblitz/ at install time
|   |-- flake.nix             # Dendritic module auto-discovery
|   |-- hosts/default.nix     # Reads config.json, maps to features.*
|   |-- modules/apps/         # bitcoind, lnd, cln, blitz-api, blitz-web
|   |-- modules/system/       # Base system config
|   +-- hardware/             # pi4, pi5, x86, vm
|-- nix/                      # Nix build files for the TUI package
|-- scripts/                  # Lock file generation scripts
+-- flake.nix                 # Builds the TUI, provides nix run
```

**Key design rule:** The `tui` package never calls system commands directly. All system interaction goes through `common`'s service layer. This is what makes the code reusable for a future web UI.

### Running Tests

```bash
just test
```

All tests are in `common/test/`. They cover config serialization, JSON round-tripping, git operations, systemctl output parsing, lsblk parsing, platform detection, and file scaffolding.

To run a single test file:

```bash
cd common && dart test test/services/config_service_test.dart
```

### Testing in a VM

The justfile includes QEMU commands for end-to-end testing:

```bash
# Boot a NixOS ISO in QEMU (creates a 32GB virtio disk)
just vm-boot

# In another terminal, SSH into the live ISO
just vm-ssh-installer

# Inside the VM, run the TUI installer:
nix run git+https://forge.f44.fyi/f44/nixblitz_ng
# Or from a local checkout:
nix run /path/to/nixblitz

# After installation and reboot, boot the installed system:
just vm-run

# SSH into the installed system:
just vm-ssh

# Start fresh (delete disk image):
just vm-clean
```

The VM uses KVM acceleration, 8GB RAM, 4 cores, and forwards SSH on port 10022.

### Nix Build

The TUI is packaged as a Nix flake. Building requires a [custom nixpkgs fork](https://github.com/fusion44/nixpkgs/tree/dart-workspace-member-filter) with Dart workspace support (pending upstream merge).

```bash
nix build .#nixblitz
```

After changing Dart dependencies (`dart pub get`), regenerate the Nix lock files:

```bash
just gen-locks
```

## Config Format

The `config.json` at `~/nixblitz/config.json` is the single source of truth:

```json
{
  "initialized": true,
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

The TUI exposes only high-impact options. Advanced users can edit this file directly — the TUI picks up external changes on next launch. Unknown fields are preserved across TUI edits.

## License

MIT
