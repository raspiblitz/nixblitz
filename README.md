# NixBlitz

A TUI for installing and managing a Bitcoin/Lightning node on
NixOS. Boot any NixOS ISO, run one command, get a configured node
— without touching Nix.

## What it does

NixBlitz guides you through:

1. **Installation** — pick a disk + network + Lightning backend,
   `disko-install` partitions and copies a fresh NixOS onto it.
2. **First-boot setup** — set the admin password, services come
   up under live `nixos-rebuild switch`, dashboard appears.
3. **Ongoing management** — typed config editor, unified-diff
   review before every Apply, plugin system for third-party
   extensions, pull TUI / system / plugin updates from one menu.

`~/nixblitz/config.json` is the single source of truth. NixOS
modules read it via `builtins.fromJSON`. You never edit `.nix`
files — the TUI is a typed editor over that JSON.

## Quick start

Boot a stock NixOS 25.11 ISO, then:

```bash
nix run git+https://forge.f44.fyi/f44/nixblitz_ng \
  --experimental-features "nix-command flakes" \
  --no-write-lock-file --refresh
```

The TUI walks you through disk + network + Lightning choices,
runs the install, reboots into the configured system. Full VM
walkthrough: [docs/getting-started.md](docs/getting-started.md).

## Supported services

| Service     | Description                                                                            |
| ----------- | -------------------------------------------------------------------------------------- |
| bitcoind    | Bitcoin Core (mainnet/regtest, pruned or full)                                         |
| LND         | Lightning Network Daemon                                                               |
| CLN         | Core Lightning                                                                         |
| Blitz API   | RaspiBlitz API                                                                         |
| Blitz Web   | RaspiBlitz Web UI                                                                      |
| **Plugins** | Tailscale, LNBits — extend with your own ([authoring guide](docs/plugin-authoring.md)) |

## Supported platforms

- x86_64 (bare metal, Proxmox, qemu, libvirt) — boot a stock
  NixOS ISO, run the bootstrap, the TUI takes over.
- Raspberry Pi 5 — boot the upstream
  [`nvmd/nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi)
  installer image, run the same bootstrap. NixBlitz layers on
  the upstream's vendor kernel + matched firmware.
  [Walkthrough](docs/getting-started.md#raspberry-pi-5).

## Documentation

For developers and contributors:

- **[Getting started](docs/getting-started.md)** — VM walkthrough
  (Proxmox / qemu), bootstrap, install, first-boot.
- **[Architecture](docs/architecture.md)** — repo tour, the
  config-as-source-of-truth model, plugin two-stage ABI, Nix
  concepts cheat-sheet.
- **[Dev loop](docs/dev-loop.md)** — `just` targets, where
  artifacts land, edit / test / iterate workflow.
- **[Plugin authoring](docs/plugin-authoring.md)** — manifest
  reference, companion-script pattern, worked examples.
- **[Decisions](docs/decisions/plugins.md)** — load-bearing
  architectural decisions (D1-D18). Read before proposing changes
  to the plugin or sudo posture.

## License

MIT
