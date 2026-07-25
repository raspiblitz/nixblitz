# Releasing installer images (x86 + Pi 5)

How to build, flash, and release the NixBlitz installer media, and which
medium to point a given user at. Two artifacts:

| Platform                 | Flake output                                   | Recipe           | Artifact                                         |
| ------------------------ | ---------------------------------------------- | ---------------- | ------------------------------------------------ |
| x86_64                   | `.#installer-iso`                              | `just iso-build` | `result/iso/nixblitz-installer.iso`              |
| Raspberry Pi 5 (aarch64) | `.#packages.aarch64-linux.pi5-installer-image` | `just pi5-image` | `result/sd-image/nixblitz-pi5-installer.img.zst` |

Both carry the nixblitz TUI, auto-launch it on the live console, and **bake an
offline install closure** so `disko-install` runs with no substituter. They are
dev/release artifacts built on a build machine / CI — not shipped to nodes.
Builders: `nix/iso.nix` and `nix/installer-system.nix` (x86);
`nix/pi5-image.nix` and `nix/pi5-installer-system.nix` (Pi 5).

## Which medium? (route by RAM + use-case)

The prebuilt images bake the whole install closure, so a **low-RAM or offline**
target never does a memory-heavy on-device build. A capable machine on the
network can instead take the lighter **official image + `nix run`** path (the
TUI bootstraps over the network on first run).

| Target                       | When                         | Medium                                                        | How                                                                                              |
| ---------------------------- | ---------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| x86 VM                       | testing / eval               | **Prebuilt NixBlitz ISO**                                     | `just vm-boot`, or attach `nixblitz-installer.iso`                                               |
| x86 bare metal               | < 8 GB RAM, or offline       | **Prebuilt NixBlitz ISO**                                     | flash `nixblitz-installer.iso`, boot                                                             |
| x86 bare metal               | ≥ 8 GB RAM + network         | Official NixOS minimal ISO + `nix run`                        | download the stock ISO from nixos.org, boot, `nix run git+https://forge.f44.fyi/f44/nixblitz_ng` |
| Pi 5 (all models are ≥ 8 GB) | network install              | Upstream `nixos-raspberrypi#installerImages.rpi5` + `nix run` | build & flash the upstream image (below), then `nix run`                                         |
| Pi 5                         | offline / download-and-flash | **Prebuilt NixBlitz Pi 5 image**                              | flash `nixblitz-pi5-installer.img.zst`                                                           |

Note the asymmetry: x86's "official image" is a direct download from nixos.org;
Pi 5 has **no** downloadable official image — you `nix build` the
nixos-raspberrypi one (there's no vanilla NixOS Pi 5 medium: it needs the vendor
kernel, matched firmware, and 16K-page userland). That's exactly why we also
build and host a NixBlitz Pi 5 image.

## Build

### x86 ISO

```bash
just iso-build          # → result/iso/nixblitz-installer.iso
```

Self-contained; no special substituters. Boot it in QEMU with `just vm-boot`.

### Pi 5 image

```bash
just pi5-image          # → result/sd-image/nixblitz-pi5-installer.img.zst
```

**Prerequisites (not runnable on a pure-x86 host):**

- **aarch64 build capability** — either a remote aarch64 builder in
  `nix.buildMachines` / `--builders`, or binfmt emulation on the builder host
  (`boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`). The Dart TUI and any
  cache miss build under this.
- **Substituters** (the root flake carries no `nixConfig`, deliberately — supply
  out-of-band in `/etc/nix/nix.conf` or via `--option`):

  ```
  extra-substituters = https://nixos-raspberrypi.cachix.org https://attic.f44.fyi/nixblitz
  extra-trusted-public-keys = nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=
  ```

  Without `nixos-raspberrypi.cachix.org` the vendor kernel + 16K jemalloc rebuild
  locally (multi-hour under qemu) and you risk pulling 4K-aligned aarch64
  substitutes → SIGBUS. `attic.f44.fyi/nixblitz` carries the nixblitz-specific
  Pi 5 leaves (issue #24 jemalloc) for a fast offline-closure resolve.

The `nixos-raspberrypi` input is **tag-pinned** (`v1.20260707.1`) with no
`follows` — the Pi 5 image must build against nvmd's own nixpkgs (the rev their
cachix is built against). Never bump it via a blind `nix flake update`; see
CLAUDE.md → Flake input rules.

### Upstream Pi 5 image (the `nix run` path for capable Pi 5s)

For users who take the official-image + `nix run` route, build and flash the
vanilla nixos-raspberrypi image (documented in
`website/content/docs/installation.md`):

```bash
nix run nixpkgs#cachix -- use nixos-raspberrypi        # one-time, on the build machine
nix build github:nvmd/nixos-raspberrypi/v1.20260707.1#installerImages.rpi5
zstd -dc result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

## Flash

- **x86 ISO** → USB stick:
  ```bash
  sudo dd if=result/iso/nixblitz-installer.iso of=/dev/sdX bs=4M conv=fsync status=progress
  ```
- **Pi 5 image** → USB / SD (the `.img.zst` is zstd-compressed):
  ```bash
  zstd -dc result/sd-image/nixblitz-pi5-installer.img.zst \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
  ```
  Raspberry Pi Imager also flashes `.img.zst` natively.

Replace `/dev/sdX` with the real device (`lsblk`); the wrong device wipes a disk.

## Release

```bash
just release <version>     # e.g. just release v0.1.0
```

Builds both artifacts, stages them under `release/<version>/`, and writes
`SHA256SUMS` over them. The Pi 5 leg needs the aarch64 builder above. Then,
manually:

1. **Sign** the checksums (optional but recommended):
   ```bash
   minisign -Sm release/<version>/SHA256SUMS
   ```
   Keep the signing key out of the repo; publish the public key once.
2. **Publish** to a Forgejo release on `forge.f44.fyi/f44/nixblitz_ng`:
   ```bash
   fj release create <version> release/<version>/*
   ```

## Offline behavior

Both artifacts bake a fully offline install closure — no substituter, no flake
fetch, no forge lookup during `disko-install`. What's baked into the image
store:

- The installer's own system closure (TUI, toplevel, dependencies).
- The `diskoScript` derivation for the target layout.
- **All flake input sources** referenced by the installed config (nixpkgs,
  templates, and every plugin/service input the base config can reach) — the
  raw source trees, not just the eval result.
- A **path-locked** `flake.lock` at `/etc/nixblitz/offline-flake.lock`: every
  input resolves to a `path:` entry pointing at the baked store source instead
  of a `github:`/`git+https:` URL, so evaluating the installed config never
  needs the network.

### Acceptance test

```bash
just vm-clean && just vm-boot-offline
```

Run the installer wizard and complete a full install on a blank disk with
**zero internet** (`vm-boot-offline` uses QEMU user networking with
`restrict=on`: the guest has a NIC and DHCP but slirp drops all routed
traffic, so there's no path out even if something tried — while the explicit
SSH `hostfwd` keeps `just vm-ssh-installer` working for mid-install
inspection). The install must complete end to end. Check the install log for
the absence of both:

- `copying path … from https://…` (a substituter fetch)
- `Added input '…' to the lock file` (a flake input re-fetch)

Either line means something escaped the offline closure and the acceptance
gate fails.

### ISO size

Baking the input sources adds roughly **+400-500 MB** to the ISO compared to
an installer that only carries the eval result. This is the cost of §4.2's
closure guarantee (closure baked == closure evaluated) — accepted so the
installer never needs connectivity.

Installed nodes keep their own pinned input sources on disk too (roughly
**+250-300 MB**), so config rebuilds and rollbacks evaluate offline; only an
explicit update re-locks from the forge and re-fetches.

## Verify

- **x86:** `just iso-build` → `just vm-boot` boots the ISO, the TUI auto-launches
  on tty1, the wizard's `disko-install` completes **offline**; `just vm-run`
  boots the installed system, `just vm-ssh` logs in.
- **Pi 5:** `just pi5-image` → flash to USB/SD → boot a real Pi 5 → confirm the
  TUI auto-launches → the wizard runs `disko-install --flake
~/nixblitz#nixblitz-pi5-installer` offline → reboot into the installed
  `nixblitz-pi5`. (The 16K-page hardware run is the validation the x86 QEMU path
  can't cover.)
- **Release:** `sha256sum -c SHA256SUMS` in `release/<version>/` passes.
