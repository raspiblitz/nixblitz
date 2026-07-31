---
title: Install on x86 - NixBlitz
---

<!-- install-pi5.md and install-x86.md share their wizard / first-boot / verify sections — edit both. -->

# Install on x86

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

Attach the prebuilt ISO to a VM (or flash it to a USB stick for bare
metal), boot, and walk a short wizard. Reboot and you have a
working node running bitcoind + LND — no Nix or NixOS background
required.

## What you need

A VM host is the most common setup:

- **Proxmox** — the path most people take. Any recent version.
- **qemu / virt-manager / libvirt** — works the same way.

| Setting    | Value                                     |
| ---------- | ----------------------------------------- |
| CPU        | 4 cores (2 minimum)                       |
| RAM        | 4 GB (3 GB minimum)                       |
| Disk       | 30 GB                                     |
| Firmware   | UEFI                                      |
| Boot order | ISO first                                 |
| Network    | Bridged or NAT — both fine for evaluation |

Bare metal works the same — same minimums, just with real hardware
instead of a hypervisor.

## 1. Download the ISO

Download
[`260728_01_nixblitz_x86_installer.iso`](https://zipline.f44.fyi/u/260728_01_nixblitz_x86_installer.iso).
It carries the TUI and a full offline install closure baked in —
nothing is fetched during install.

Verify the download first:

```bash
sha256sum 260728_01_nixblitz_x86_installer.iso
# 8c0a8f3e85a3a63a1f232d815ef65613135301fa1b19af1f7ab5b312aad432d8
```

## 2. Attach or flash

Attach the ISO to your VM as a virtual CD-ROM (Proxmox: Hardware →
CD/DVD Drive; qemu / virt-manager / libvirt: attach as `-cdrom`). For
bare metal, flash it to a USB stick instead — the friendliest route
is [caligula](https://github.com/ifd3f/caligula), which lists
removable drives interactively (no `/dev/sdX` guessing) and verifies
the write:

```bash
nix run nixpkgs#caligula -- burn 260728_01_nixblitz_x86_installer.iso \
  -s sha256-8c0a8f3e85a3a63a1f232d815ef65613135301fa1b19af1f7ab5b312aad432d8
```

(The `-s` flag makes caligula verify the download hash before it
touches any disk.)

Plain `dd` works too:

```bash
sudo dd if=260728_01_nixblitz_x86_installer.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with your USB stick's actual device (check with
`lsblk` first) — the wrong device wipes a disk.

## 3. Boot

Boot the VM (ISO first in boot order) or the bare-metal box from the
USB stick. The TUI auto-launches on the console.

> The prebuilt NixBlitz media ship a known live login — user `nixos`, password
> `nixblitz` — so `ssh nixos@<ip>` works immediately (sudo is
> passwordless on the live system). It evaporates after install +
> reboot; the installed system uses the admin password you set
> during first-boot setup.

Find the VM's (or box's) IP from the local console if you want to
SSH in instead:

```bash
ip -4 addr
```

## 4. The install wizard

One decision here: the **disk**. The wizard shows size + model so
you can't get it wrong. In a VM that's typically `vda` or `sda`
(bare metal: `nvme0n1` or `sdX`).

Everything else — Bitcoin network, Lightning backend, node alias —
is asked during first-boot setup (§6), after the reboot.

Confirm. The installer runs `disko-install`:

- Partitions and formats the disk via the disko module.
- Builds a minimal NixOS system (services off — `initialized: false`
  in `~/nixblitz/config.json` keeps the build small enough to fit in
  tmpfs).
- Copies the system to disk, installs the bootloader.

A quiet evaluation phase before output starts is normal. Once
evaluation finishes, the TUI streams disko's output live:
partitioning, copying store paths, installing the bootloader. Takes
roughly 2-5 minutes on a typical VM. The whole install runs fully
offline — nothing is fetched over the network.

When done, the TUI offers **Reboot**. Hit Enter.

## 5. Reboot

Detach the ISO from the VM (or pull the USB stick / adjust boot
order for bare metal) so the system doesn't boot back into the
installer. Power back on — GRUB picks up the new generation and
boots into the freshly installed `nixblitz` system.

## 6. First-boot setup

The TUI launches automatically (auto-login on `tty1`) into
**first-boot setup**.

### Set the admin password

NixBlitz uses NixOS's default `wheelNeedsPassword = true`. The TUI
prompts you for sudo authorization the first time you do something
privileged in a session, and caches the timestamp for ~10 min after.
The default admin password from the install is `nixblitz` — type it
when the sudo modal appears.

Then enter a new password. The TUI runs `chpasswd` over the cached
sudo timestamp.

### Pick network, backend, and alias

The wizard then walks the remaining decisions in order:

1. **Bitcoin network** — `mainnet` / `regtest`. (Testnet and signet
   aren't offered: nix-bitcoin upstream only supports the two.) For
   evaluation, pick **regtest** — it lets you exercise the debug
   menu's Lightning helpers (mine blocks, fund wallets, open
   channels). You can rebuild on a different network later without
   reinstalling. For a real node, pick **mainnet**. bitcoind then
   installs as a plugin — a short burst of plugin output is normal.
2. **Lightning backend** — `LND` / `CLN` / `None`. Pick **LND**. On
   regtest, picking LND auto-enables a secondary `lncli-test`
   instance for end-to-end channel + payment testing.
3. **Node alias** — the public name your Lightning node announces.

### Wait for services to come up

The TUI runs `nixos-rebuild switch` to bring services up. Output
streams live. ~5-10 minutes on regtest, mostly bootstrap of:

- bitcoind (regtest is empty so chain sync is instant)
- lnd (waits for bitcoind; reads block 0)

> The FastAPI backend (`blitz-api`) and the React UI (`blitz-web`)
> ship as plugins, not built-in apps. Install them after the wizard
> from Configure → Plugins to get the web frontend.

> If `nixos-rebuild` exits with code 4, the wizard shows a yellow
> "completed with warnings" banner instead of failing outright. The
> new system was activated, just one or more units failed to
> start — most commonly NixOS's `logrotate-checkconf` against
> `/var/log/nginx` on first activation, which is harmless. Press
> `[Enter]` to continue past the warning, or `[R]` to retry.

### Back up the LND wallet seed

Once `lnd` starts, the wizard walks a live checklist instead of a
bare spinner:

```
Lightning Wallet Setup

  ✓ LND service started
  ⠿ Waiting for LND to create the wallet seed
  ○ Read seed file (needs sudo)

  [o] show LND log
```

The sudo prompt only appears once **"LND service started"** is
checked off — reading the seed file needs root, and the TUI warns
you on screen before it asks. Press `[o]` at any point to open a
scrollable popup of the live LND journal, useful if a row stalls.

Once the seed file is read, the wizard asks what to do with the
freshly-generated 24-word aezeed seed:

- `[A]` **Show on screen** — renders the words as a 6×4 numbered
  grid. Best in private. After confirming with `[Y]` the words are
  wiped from process memory; the on-disk file persists for recovery
  via `sudo cat /mnt/data/lnd/lnd-seed-mnemonic`.
- `[B]` **Continue without showing** — for public / livestreamed /
  recorded environments. Same recovery command applies.

Either way, copy the words to durable offline storage. **The seed
restores ON-CHAIN funds only** — Lightning channels also need a
separate Static Channel Backup (`channel.backup`, maintained by
LND).

> The seed is LND aezeed format, not BIP-39. It restores into LND
> only; hardware wallets like Trezor / Ledger won't recognise it.

If you exit the wizard mid-flow (Ctrl+C, SSH drop, power loss), the
next launch picks up at the next undone step automatically — you'll
never re-do something you already finished, and never accidentally
drop to the dashboard with the seed unbacked.

When the summary screen says "Setup Complete!", press `[Enter]` and
you land on the **dashboard**.

## 7. Verify + access

From your host:

```bash
# SSH into the box (admin user, the password you set at first-boot)
ssh admin@<ip>
```

Inside the box you have `bitcoin-cli`, `lncli`, `lightning-cli` on
`PATH` (plus `lncli-test` on regtest for the secondary LND), and
`nixblitz` itself to re-run the TUI any time — same binary, same
config.

Back in the TUI, the dashboard's tile grid summarizes node health: a
**System** tile (uptime + per-service state), a **Hardware** tile
(memory + disk from `/proc`), and a node-identity strip above them
(hostname, uptime, last-apply timestamp, an `<n> to apply` badge).
Bitcoin / Lightning tiles come from the **bitcoind** / **lnd**
plugins the wizard installed.

Global hotkeys work from any view:

- `[c]` Configure — typed-options editor with a sidebar of
  per-service sections
- `[a]` Apply / `[u]` Update — both land on **System**, whose
  sidebar splits read-only **Check** probes, destructive **Apply**
  rebuilds, and **Power** (shutdown / reboot) into three sections
- `[D]` Debug — service health, log tail, regtest helpers
- `[?]` Help
- `[q]` Quit — during an in-flight Apply / Update / sudo prompt, the
  first `q` arms a 3-second confirm window; second `q` actually
  quits

In **System → Check**, `[v]` opens the "packages to compile" viewer
when a Heavy check finds something that would need a local build,
and `[o]` opens the full transcript of the last check in a
scrollable popup — handy when the inline summary truncates a long
`nix` error.

After a few hours the node tile's `system updates` row populates
once the periodic check timer (`nixblitz-check.timer`) has
run, folding into the same `<n> to apply` badge. Trigger a check on
demand from **System → Check** (the **Updates** sidebar entry), or
from any shell with `nixblitz check`.

If something doesn't work, `~/nixblitz.log` on the box is the first
place to look.

## Appendix: stock NixOS ISO + network bootstrap

If you'd rather not use the prebuilt NixBlitz ISO — building from
source, auditing what's baked in, or you just have a stock NixOS ISO
handy — boot a vanilla NixOS live image instead and bootstrap the
TUI over the network. This route wants **≥ 8 GB RAM**: the TUI and
its Dart workspace build locally on first run rather than
substituting from a baked-in closure.

### Get the ISO

Download the **NixOS 25.11 minimal ISO** from
[nixos.org/download](https://nixos.org/download/) (about 1 GB). The
graphical ISO works too if you prefer a graphical console; neither
is "more correct." Attach or flash it the same way as §2 above, and
boot.

### Boot + optionally enable SSH

You land on a NixOS shell as user `nixos`. No password is set on the
live ISO; sudo is passwordless there. (The _installed_ system uses
NixOS's password-required default; we prompt you to set an admin
password during first-boot setup.)

The live ISO ships with `sshd` running but the `nixos` user has no
password set, so SSH login is refused by default. Enabling it takes
one command on the local console — useful so the bootstrap command
below is one paste away from a real terminal instead of a
hand-typed VM console.

1. On the live console (the VM window), set a password for the
   `nixos` user:

   ```bash
   passwd
   ```

   Pick anything. The live ISO is ephemeral; this password is gone
   after install + reboot.

2. Find the VM's IP:

   ```bash
   ip -4 addr | grep inet
   ```

3. From your host, SSH in:

   ```bash
   ssh nixos@<vm-ip>
   ```

The rest of the install wizard runs identically over SSH; the only
difference is you can paste the bootstrap command below instead of
typing it.

### Bootstrap the TUI

From the live ISO shell:

```bash
nix run github:raspiblitz/nixblitz \
  --experimental-features "nix-command flakes" \
  --no-write-lock-file --refresh
```

What this does:

- `nix run` — builds and executes the flake's default app.
- `--experimental-features "nix-command flakes"` — stock NixOS
  still gates flakes behind a feature flag.
- `--no-write-lock-file` / `--refresh` — the live ISO root is tmpfs
  and we don't want stale cache from previous attempts.

First-run takes 30-60 seconds (downloads + builds the TUI binary and
its Dart workspace). The TUI launches into **install mode** because
it detected tmpfs root (live ISO context) — from here the wizard is
identical to §4 above.
