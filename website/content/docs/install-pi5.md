---
title: Install on Pi 5 - NixBlitz
---

<!-- install-pi5.md and install-x86.md share their wizard / first-boot / verify sections — edit both. -->

# Install on Raspberry Pi 5

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

Flash the prebuilt image to a microSD card or USB stick, boot the
Pi 5, and walk a
short wizard. Reboot and you have a working node running
bitcoind + LND — no Nix or NixOS background required.

## What you need

- **Pi 5 8 GB.** The 4 GB will boot but is tight alongside indexing
  tools (electrs, etc.).
- **NVMe via the official M.2 HAT** is the supported storage config.
  SD-only works for evaluation; not recommended for a long-running
  node.
- **A microSD card or USB stick** (≥4 GB) to boot the live image
  from. SD is the classic Pi route and the field-tested one; USB
  works the same way.
- **Active cooling required.** Initial chain sync pegs the CPU at
  100% for days; passive heatsinks throttle hard and the box runs
  uncomfortably hot. The official Active Cooler (or any fan-equipped
  case) is the safe choice for any node that will actually sync
  mainnet.

## 1. Download the image

Download
[`260728_01_nixblitz-pi5-installer.img.zst`](https://zipline.f44.fyi/u/260728_01_nixblitz-pi5-installer.img.zst).
It carries the TUI and a full offline install closure baked in —
nothing is fetched during install.

Verify the download before flashing:

```bash
sha256sum 260728_01_nixblitz-pi5-installer.img.zst
# 4949252870915f5a3ce440f2f56326d95e2b122245cb38d75e2647423da6e420
```

## 2. Flash it

The friendliest route is
[caligula](https://github.com/ifd3f/caligula): it lists removable
drives interactively (no `/dev/sdX` guessing), decompresses the
`.img.zst` on the fly, and verifies the write afterwards:

```bash
nix run nixpkgs#caligula -- burn 260728_01_nixblitz-pi5-installer.img.zst \
  -s sha256-4949252870915f5a3ce440f2f56326d95e2b122245cb38d75e2647423da6e420
```

(The `-s` flag makes caligula verify the download hash before it
touches any disk. When it asks whether the hash is for the
compressed or uncompressed file, answer **compressed** — the hash
above is of the `.img.zst` exactly as downloaded.)

Plain `dd` works too (the image is zstd-compressed):

```bash
zstd -dc 260728_01_nixblitz-pi5-installer.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with your card/stick's actual device (check with
`lsblk` first) — the wrong device wipes a disk. Raspberry Pi Imager
flashes `.img.zst` natively too, if you'd rather point-and-click.

## 3. Boot

Insert the card or stick. If you're installing onto NVMe via the
M.2 HAT, make sure the NVMe drive is also seated. Power on — the
Pi 5 boots the live medium. The TUI auto-launches on the console.
(Booting from **USB** with an already-bootable NVMe in place? The
default firmware boot order picks the NVMe first — see the EEPROM
appendix at the end of this page.)

> The prebuilt NixBlitz media ship a known live login — user `nixos`, password
> `nixblitz` — so `ssh nixos@<ip>` works immediately (sudo is
> passwordless on the live system). It evaporates after install +
> reboot; the installed system uses the admin password you set
> during first-boot setup.

Find the Pi's IP from the local console if you want to SSH in
instead:

```bash
ip -4 addr
```

## 4. The install wizard

One decision here: the **disk**. The wizard shows size + model so
you can't get it wrong. On a Pi 5 that's typically `nvme0n1` for
NVMe (or `mmcblk0` for SD).

Everything else — Bitcoin network, Lightning backend, node alias —
is asked during first-boot setup (§6), after the reboot.

Confirm. The installer runs `disko-install`:

- Partitions and formats the disk via the disko module.
- Builds a minimal NixOS system (services off — `initialized: false`
  in `~/nixblitz/config.json` keeps the build small enough to fit in
  tmpfs).
- Copies the system to disk, installs the bootloader.

Before any output appears you'll sit on a quiet **"Evaluating
system configuration"** phase — this can take several minutes on a
Pi 5 and is normal; Nix's evaluator is doing real CPU work (single-threaded, and slow on the Pi's SoC) on
comparatively modest hardware. Once evaluation finishes, the TUI
streams disko's output live: partitioning, copying store paths,
installing the bootloader. Takes roughly 5-10 minutes on a Pi 5. The whole
install runs fully offline — nothing is fetched over the network.

When done, the TUI offers **Reboot**. Hit Enter.

## 5. Reboot

Power off, then **pull the installer card/stick** — left in, the
Pi 5 boots the live medium again instead of your fresh install.
Power back on. The Pi 5 boots into the freshly installed
`nixblitz-pi5` system from the NVMe.

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

## Appendix: build the live image yourself

NixOS upstream doesn't ship Pi 5 firmware / vendor kernel / matched
bootloader, so there's no vanilla NixOS Pi 5 medium and no
"official" image to just download. If you'd rather not use the
prebuilt image — building from source, or auditing what's baked
in — NixBlitz layers on the third-party
[`nvmd/nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi)
flake and needs a live image you build yourself, then bootstraps the
TUI over the network on first run.

Upstream maintains a Cachix binary cache for the heavy bits (vendor
kernel, firmware, installer closure). **Enable it before
building** — otherwise `nix build` tries to compile the kernel
locally, which on x86 means cross-compilation or qemu emulation and
a multi-hour wait.

```bash
nix --experimental-features "nix-command flakes" run nixpkgs#cachix \
  -- use nixos-raspberrypi
```

Then build the image (an `x86_64-linux` build machine works fine —
the closure substitutes from the Cachix):

```bash
nix --experimental-features "nix-command flakes" build \
  github:nvmd/nixos-raspberrypi/v1.20260707.1#installerImages.rpi5
```

First run downloads ~500 MB. The result is a
`result/sd-image/<name>.img.zst` symlink — flash it the same way as
§2 above.

Boot it, and you land as **`root`** with SSH enabled but no
authorized keys — a rough edge of the upstream image NixBlitz
doesn't paper over. The image prints a random root password during
first boot, but other boot chatter often garbles the printout —
don't squint at it; just set a password on the local console
(`passwd`), find the IP (`ip -4 addr`), and SSH in as `root`.

The upstream image also has no `git` on `PATH`, which the bootstrap
command below needs (`nix run` against a `git+https://…` URL):

```bash
nix-shell -p git
```

Then, from inside that shell, bootstrap the TUI. This needs
network — ≥ 8 GB RAM is fine on every current Pi 5 model:

```bash
nix run \
  --extra-substituters "https://nixos-raspberrypi.cachix.org" \
  --extra-trusted-public-keys "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" \
  --experimental-features "nix-command flakes" \
  --no-write-lock-file --refresh \
  git+https://forge.f44.fyi/f44/nixblitz_ng
```

The `--extra-substituters` / `--extra-trusted-public-keys` flags
matter: the Pi 5 vendor kernel needs 16K-aligned aarch64 binaries,
which only the upstream Cachix bucket has. Without them `nix run`
can SIGBUS mid-fetch pulling 4K-aligned binaries from
cache.nixos.org.

First run takes 5-30 minutes depending on which closures the Cachix
has pre-built (the Dart workspace bits are NixBlitz-specific and
always build locally on the Pi). The TUI launches into **install
mode** (it detects tmpfs root) — from here the wizard is identical
to §4-§7 above.

For building and releasing the NixBlitz image itself, see
`docs/releasing-installer-images.md`.

## Appendix: USB boot vs. the EEPROM boot order

The Pi 5's firmware tries boot devices in the order its EEPROM
config lists them — factory default is `BOOT_ORDER=0xf461`, which
reads **right to left**: SD first, then NVMe, then USB. Two
consequences:

- Installing onto a **blank** NVMe works from either medium: the
  empty NVMe has nothing to boot, so the firmware falls through to
  your card or stick.
- **Re**installing from USB on a Pi whose NVMe already boots (say,
  an existing NixBlitz) silently boots the NVMe system instead —
  the stick never gets a turn. SD doesn't have this problem; it
  outranks the NVMe by default.

To let USB outrank the NVMe, edit the EEPROM from the running
system. NixOS doesn't ship the tool, but nixpkgs has it:

```bash
nix shell nixpkgs#raspberrypi-eeprom

# read the current config:
sudo env "PATH=$PATH" rpi-eeprom-config

# edit — set BOOT_ORDER=0xf641 (right to left: SD → USB → NVMe):
sudo env "PATH=$PATH" EDITOR=nano rpi-eeprom-config --edit

sudo reboot   # the staged update applies during the reset
```

The `env "PATH=$PATH"` keeps the nix-shell tool visible under
sudo's `secure_path`. After the reboot, re-run the read command to
confirm the new order took. With `0xf641` an inserted SD still
wins, USB is tried next, and the NVMe system remains the fallback
— so a plugged-in installer stick takes precedence exactly when
you want it to.
