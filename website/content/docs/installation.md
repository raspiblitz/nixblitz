---
title: Installation - NixBlitz
---

# Installation

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

Boot a live image, pick your disk, walk a short wizard,
reboot into a working node with bitcoind + LND. The install wizard
auto-detects the platform once it runs, and after install the same
flake on disk handles runtime + updates on both platforms — the
guides differ only in how you get onto the box the first time. Pick
the one that matches your hardware:

| Platform | When to use                                                                                  | Live-image source                                                                                                                                                                                                                                                                                           |
| -------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **x86**  | Evaluating in a VM (Proxmox / qemu / libvirt) or running on a NUC, server, or repurposed PC. | [**Prebuilt NixBlitz ISO**](https://zipline.f44.fyi/u/260728_01_nixblitz_x86_installer.iso) (offline, TUI baked in) — best for VMs and lower-RAM boxes; or the stock NixOS 25.11 minimal ISO from [nixos.org/download](https://nixos.org/download/) + a network bootstrap on machines with ≥ 8 GB RAM.      |
| **Pi 5** | Production node on dedicated hardware. Pi 5 8 GB recommended, NVMe via the official M.2 HAT. | [**Prebuilt NixBlitz Pi 5 image**](https://zipline.f44.fyi/u/260728_01_nixblitz-pi5-installer.img.zst) (offline, download-and-flash); or build & flash the third-party `nvmd/nixos-raspberrypi` image + network bootstrap (NixOS upstream doesn't ship Pi 5 firmware / vendor kernel / matched bootloader). |

[**Install on Raspberry Pi 5 →**](/docs/install-pi5)

[**Install on x86 →**](/docs/install-x86)
