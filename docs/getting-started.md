# Getting started

> Operator-facing version lives at `website/content/docs/installation.md`;
> keep them in sync when editing.

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

Setup a NixBlitz in a VM in under an hour. This guide assumes you
know your way around a Linux terminal but have **no Nix or NixOS
background** — you'll pick up the few concepts that matter as you go.

We'll boot a stock NixOS ISO, run one command to launch the
NixBlitz installer, walk through the wizard, and reboot into a
working node with bitcoind + LND running on regtest.

> **Why regtest?** The demo / dev-loop flows assume regtest because
> the test-LND helpers (open a channel, pay a self-invoice) need a
> network where you can mine blocks on demand. For an evaluation
> install you probably want regtest. For a real node, pick
> mainnet at the wizard step instead.

## What you need

A VM host. Pick the one you have:

- **Proxmox** — the path most contributors take. Any recent
  version. ≥4 GB RAM, ≥30 GB disk, UEFI boot.
- **qemu / virt-manager / libvirt** — works the same way. Same
  resource budget.
- **Cloning the repo for development** — if you also want to hack
  on the TUI itself, run `just vm-boot` from a checkout instead
  (see [dev-loop.md](dev-loop.md)). That gives you the same
  experience in a local qemu VM with port-forwarded SSH.

You don't need Nix on your host. Everything happens inside the VM.

## Get the ISO

Grab the **NixOS 25.11 minimal ISO** from
[nixos.org/download](https://nixos.org/download/) (about 1 GB).
The graphical ISO works too if you prefer a graphical console;
neither is "more correct."

On x86 you have two routes: boot stock NixOS and bootstrap the TUI
from the network on first run (best on ≥ 8 GB machines), or flash the
prebuilt, offline [**NixBlitz ISO**](https://zipline.f44.fyi/u/nixblitz-x86-installer-1.iso)
(TUI + install closure baked in; best for VMs / low-RAM). Either way
the same flake on disk then handles runtime + updates. (Pi 5 is
different — see the Pi 5 section below: NixOS upstream doesn't ship
Pi 5 firmware / vendor kernel / matched bootloader, so the network
route rides the third-party `nvmd/nixos-raspberrypi` live image, or
use the prebuilt
[**NixBlitz Pi 5 image**](https://zipline.f44.fyi/u/nixblitz-pi5-installer-1.img.zst).)
Building & releasing both media is documented in
`docs/releasing-installer-images.md`.

## Create the VM

Whatever your hypervisor:

| Setting    | Value                                     |
| ---------- | ----------------------------------------- |
| CPU        | 4 cores (2 minimum)                       |
| RAM        | 4 GB (3 GB minimum)                       |
| Disk       | 30 GB                                     |
| Firmware   | UEFI                                      |
| Boot order | ISO first                                 |
| Network    | Bridged or NAT — both fine for evaluation |

Boot from the ISO. You land on a NixOS shell as user `nixos`. No
password is set on the live ISO; sudo is passwordless there. (The
_installed_ system uses NixOS's password-required default; we
prompt you to set an admin password during first-boot setup.)

## Optional: SSH from your host

The live ISO ships with `sshd` running but the `nixos` user has no
password set, so SSH login is refused by default. Enabling it
takes one command on the local console — useful so the bootstrap
command below is one paste away from a real terminal instead of a
hand-typed VM console.

1. On the live console (the VM window), set a password for the
   `nixos` user:

   ```bash
   passwd
   ```

   Pick anything. The live ISO is ephemeral; this password is
   gone after install + reboot.

2. Find the VM's IP. On the live console:

   ```bash
   ip -4 addr | grep inet
   ```

   On Proxmox: also visible in the VM's "Summary" pane. On
   libvirt: `virsh domifaddr <vm-name>`.

3. From your host, SSH in:

   ```bash
   ssh nixos@<vm-ip>
   ```

   If you ran `just vm-boot` from a checkout, the qemu invocation
   forwards SSH to host port 10022:

   ```bash
   just vm-ssh-installer
   # or directly: ssh -p 10022 nixos@localhost
   ```

The rest of the install wizard runs identically over SSH; the only
difference is you can paste the bootstrap command in the next
section instead of typing it.

## Bootstrap the NixBlitz TUI

From the live ISO shell:

```bash
nix run git+https://forge.f44.fyi/f44/nixblitz_ng \
  --experimental-features "nix-command flakes" \
  --no-write-lock-file --refresh
```

What this does:

- `nix run` — builds and executes the flake's default app.
- `--experimental-features "nix-command flakes"` — stock NixOS
  still gates flakes behind a feature flag. Set it once.
- `--no-write-lock-file` / `--refresh` — the live ISO root is tmpfs
  and we don't want stale cache from previous attempts.

- First-run takes 30-60 seconds (downloads + builds the TUI binary
  its Dart workspace). Cached afterward.

The TUI launches into **install mode** because it detected tmpfs
root (live ISO context).

## Walk the install wizard

Three decisions, defaults are sane:

1. **Disk** — pick the disk you provisioned for the VM
   (typically `vda` or `sda`). The wizard shows size + model so
   you can't get it wrong.
2. **Network** — `mainnet` / `regtest`. (Testnet and signet
   aren't offered: nix-bitcoin upstream only supports the two
   above.) For evaluation, pick **regtest** — it lets you
   exercise the debug menu's Lightning helpers (mine blocks,
   fund wallets, open channels). You can rebuild on a different
   network later without reinstalling.
3. **Lightning backend** — `LND` / `CLN` / `None`. Pick **LND**.
   On regtest, picking LND auto-enables a secondary `lncli-test`
   instance for end-to-end channel + payment testing.

Confirm. The installer runs `disko-install`:

- Partitions and formats the disk via the disko module.
- Builds a minimal NixOS system (services off — `initialized: false`
  in `~/nixblitz/config.json` keeps the live-ISO build small enough
  to fit in tmpfs).
- Copies the system to disk, installs the bootloader.

Takes 2-5 minutes on a typical VM. The TUI streams disko's output
live; you'll see partitioning, copying store paths, installing
GRUB.

When done, the TUI offers **Reboot**. Hit Enter; the VM reboots
into the freshly installed system.

## First boot

GRUB picks the new generation. NixOS finishes booting. The TUI
launches automatically (auto-login on `tty1`) into **first-boot
setup**.

### Set the admin password

NixBlitz uses NixOS's default `wheelNeedsPassword = true`. The TUI
prompts you for sudo authorization first time you do something
privileged in a session of activity, and caches the timestamp for
~10 min after. The default admin password from the install is
`nixblitz` — type it when the sudo modal appears.

Then enter a new password. The TUI runs `chpasswd` over the cached
sudo timestamp.

> See `docs/decisions/plugins.md` D18 for the rationale on the sudo
> posture. Short version: the TUI stays non-interactive within a
> session, an attacker on a stolen SSH session can no longer
> escalate without the password.

### Wait for services to come up

The TUI runs `nixos-rebuild switch` to bring services up. Output
streams live. ~5-10 minutes on regtest, mostly bootstrap of:

- bitcoind (regtest is empty so chain sync is instant)
- lnd (waits for bitcoind; reads block 0)

> The FastAPI backend (`blitz-api`) and the React UI (`blitz-web`)
> ship as plugins, not built-in apps. Install them after the wizard
> from Configure → Plugins to get the web frontend.

> If `nixos-rebuild` exits with code 4, the wizard shows a yellow
> "completed with warnings" banner instead of failing outright.
> The new system was activated, just one or more units failed to
> start — most commonly NixOS's `logrotate-checkconf` against
> `/var/log/nginx` on first activation, which is harmless. Press
> `[Enter]` to continue past the warning, or `[R]` to retry.

### Back up the LND wallet seed

Once `lnd` has come up, the wizard asks what to do with its
freshly-generated 24-word aezeed seed:

- `[A]` **Show on screen** — renders the words as a 6×4 numbered
  grid. Best in private. After confirming with `[Y]` the words
  are wiped from process memory; the on-disk file persists for
  recovery via `sudo cat /mnt/data/lnd/lnd-seed-mnemonic`.
- `[B]` **Continue without showing** — for public / livestreamed
  / recorded environments. Same recovery command applies.

Either way, copy the words to durable offline storage. **The seed
restores ON-CHAIN funds only** — Lightning channels also need a
separate Static Channel Backup (`channel.backup`, maintained by
LND). Both are tracked under issue #21.

> The seed is LND aezeed format, not BIP-39. It restores into
> LND only; hardware wallets like Trezor / Ledger won't recognise
> it.

### Resume after Ctrl+C

If you exit the wizard mid-flow (Ctrl+C, SSH drop, kernel panic),
the next launch picks up at the next undone step automatically.
NixBlitz tracks the last completed step in `config.json`'s
`setup_step_completed` field — you'll never re-do something you
already finished, and you'll never accidentally drop to the
dashboard with the seed unbacked.

When the summary screen says "Setup Complete!", press `[Enter]`
and you land on the **dashboard**.

## Tour the dashboard

The header strip shows `NIXBLITZ` on the left, `<lnd alias> | <platform>`
in the middle (e.g. `MyNode | Pi 5`), and the build version on the
right. Below that:

| Tile          | What                                                    |
| ------------- | ------------------------------------------------------- |
| **System**    | hostname, network, uptime, key services up / down state |
| **Hardware**  | memory + disk usage from `/proc`                        |
| **Bitcoin**   | sync %, block height, peer count, mempool size          |
| **Lightning** | alias, pubkey, peer + channel counts, balances          |

Installed plugins can add their own tiles. None ship out of the
box; you opt in via `nixblitz plugin add ...`.

Footer hints show shortcuts. Some only appear when relevant:

- `[c]` Configure — open the typed-options editor
- `[a]` Apply — open System tab, review everything queued for
  the next generation (config edits, upstream pin updates,
  plugin updates, package diff), confirm, commit + rebuild as
  one atomic step. The only path that mutates the running
  system.
- `[u]` Update — same destination as `[a]`. Kept as a hotkey
  alias so muscle memory from before the unification still
  works.
- `[r]` Refresh templates — only shown when the binary's
  embedded templates differ from `~/nixblitz/templates/`
  (e.g. you updated the TUI and the new binary ships a fix
  to a NixOS module). Pressing `[r]` rewrites the on-disk
  copy from the binary and routes you to `[a]` Apply to
  review the diff.
- `[D]` Debug — service health, log tail, regtest helpers
  (numeric block-count input, plus a "Regtest auto-miner"
  that runs as a transient systemd unit and survives TUI
  exit)
- `[?]` Help

Tab completion for the `nixblitz` CLI subcommands (plugin / check
/ update / init) is on by default — the package's postInstall
drops completion scripts at the standard NixOS auto-source paths,
so `nixblitz <TAB>` works immediately after a rebuild.

Walk through Configure for a moment. Tab through the service
sections; toggle a value; hit Esc to return. The dashboard now
shows an orange `1 pending change` banner. Press `[a]` to land on
the System tab's Apply pane. The review screen lists everything
queued for the next generation — your config edit at the top,
plus any upstream pin updates / plugin updates / package diff the
periodic check has staged. Confirm and the whole bundle commits +
rebuilds atomically.

That's the loop: edit → review everything that's about to land →
apply.

After installing a plugin or leaving Configure with unsaved edits,
an "Apply now?" prompt offers to jump straight to the Apply review
screen — `[y]` to review + apply, `[n]` to keep working.

A second banner may appear above the tiles after a few hours:
**`updates available: nixpkgs, … — checked Xh ago`**. This is the
periodic update check — a daily timer probes each flake input +
plugin's upstream HEAD, runs `nix flake update` + `nix build
--dry-run` + `nvd diff` in a tmpdir, and stages any lock / pin
moves under `/var/lib/nixblitz-tui/staging/` for the next Apply
to promote. Result lands in
`/var/lib/nixblitz-tui/update-status.json`; the dashboard reads
it each render. Run **`nixblitz check`** at any shell to trigger
it on demand.

## Access the running node

From your host:

```bash
# SSH into the VM (admin user, the password you set at first-boot)
ssh admin@<vm-ip>
```

If you ran `just vm-boot` locally (qemu with port forwarding):

```bash
just vm-ssh
# or directly:
ssh -p 10022 admin@localhost
```

Inside the VM you have:

- `bitcoin-cli`, `lncli`, `lightning-cli` on `PATH` (the operator
  feature in `templates/modules/system/operator.nix` adds the admin
  user to `bitcoin` / `lnd` / `cln` groups).
- On regtest also `lncli-test` for the secondary LND.
- `nixblitz` itself — re-run the TUI any time. Same binary, same
  config.

## Raspberry Pi 5

NixOS upstream doesn't ship Pi 5 firmware / vendor kernel /
matched bootloader, so NixBlitz layers on the third-party
[`nvmd/nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi)
flake (pinned to a specific tag in `templates/flake.nix`). The
end-to-end flow mirrors the x86 walkthrough above — same
bootstrap command, same install wizard — only the live image
and the install target differ.

### Recommended hardware

- **Pi 5 8 GB**. The 4 GB will boot but is tight alongside
  indexing tools (electrs, etc.).
- **NVMe via the official M.2 HAT** is the supported storage
  config. SD-only works for evaluation; not recommended for a
  long-running node (write amplification, no power-loss
  protection).
- **A USB stick** to boot the live image from. ≥4 GB.
- **Active cooling required.** Initial chain sync pegs the CPU at
  100% for days; passive heatsinks throttle hard and the box runs
  uncomfortably hot. The official Active Cooler (or any
  fan-equipped case) is the safe choice for any node that will
  actually sync mainnet.

### 1. Build the live image

The live image is upstream's `installerImages.rpi5` — vanilla
aarch64 NixOS with the Pi 5 vendor kernel + firmware. NixBlitz
isn't baked in; the next step pulls the TUI via `nix run`, same
as x86 boots a stock NixOS ISO.

Upstream doesn't publish pre-built `.img` files, but they do
maintain a Cachix binary cache for the heavy bits (vendor
kernel, firmware, installer closure). **Enable it before
building** — otherwise `nix build` will try to compile the
kernel locally, which on x86 means cross-compilation or qemu
emulation and a multi-hour wait.

```bash
# One-time, on the build machine:
nix --experimental-features "nix-command flakes" run nixpkgs#cachix \
  -- use nixos-raspberrypi
```

(`cachix use` writes to `~/.config/nix/nix.conf` for single-user
installs, or to `/etc/nix/nix.conf` if you have a multi-user Nix
daemon. Re-run with `sudo` if it complains.)

Then build the image. On a machine with Nix installed
(`x86_64-linux` works fine — the closure substitutes from the
Cachix):

```bash
nix --experimental-features "nix-command flakes" build \
  github:nvmd/nixos-raspberrypi/v1.20260707.1#installerImages.rpi5
```

First run downloads ~500 MB. The result is a
`result/sd-image/<name>.img.zst` symlink. Flash it to a USB
stick — Raspberry Pi Imager handles `.img.zst` natively; or
shell out:

```bash
zstd -dc result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

(Replace `/dev/sdX` with your USB stick's path. Triple-check.)

> **About the upstream image's SSH keys**: the upstream's
> `rpi5-installer` config has empty `authorizedKeys.keys`
> placeholders. Either set the root password from the local
> console (see the next section) and SSH in with that, or fork
> the upstream and drop your public key into `custom-user-config`.
> For an on-the-Pi-console install you can skip both.

### 2. Boot the Pi 5

Insert the USB stick. If you're installing onto NVMe via M.2,
make sure the NVMe drive is also seated. Power on. The Pi 5
boots from USB (default boot order priority).

> **Heads up: the upstream live image has a few rough edges
> we don't currently paper over.** None block the install — but
> worth knowing about up front:
>
> 1. **You log in as `root`, not `nixos`.** That's the upstream
>    `sdimage-installer` module's choice; we don't override it.
> 2. **A random root password is printed at first boot, BUT the
>    printout often gets garbled by other boot output racing on
>    the same console.** If you can read it, great — write it
>    down. If you can't, hard-reset once and try again on the
>    second boot when the boot chatter has settled, or just
>    proceed to the next step and set a known password yourself.
> 3. **SSH is enabled by default** with no authorized keys — login
>    requires the root password.
> 4. **`git` is not on PATH.** The bootstrap command in section 3
>    needs it (`nix run` against a `git+https://…` URL); drop
>    into `nix-shell -p git` first. The fully-installed system
>    has git (we add it via `features.system.base`).
> 5. **You MUST add the `nixos-raspberrypi.cachix.org` substituter
>    or the bootstrap SIGBUSes mid-fetch.** The Pi 5 vendor kernel
>    uses 16K pages; cache.nixos.org's standard aarch64 binaries
>    are 4K-aligned. Mmap'ing them on a 16K-page kernel faults
>    with SIGBUS the first time the binary is exercised, and
>    `nix run` crashes hundreds of MB into the closure with
>    `Bus error (core dumped)`. The upstream `nixos-raspberrypi`
>    cachix bucket builds aarch64 closures with 16K alignment;
>    the bootstrap command in section 3 includes the substituter
>    - public key as flags so you don't have to configure it
>      separately.
>
> To skip all of this, use the prebuilt **NixBlitz Pi 5 image** —
> known `nixos` / `nixblitz` login, closure baked in, no network
> bootstrap. This upstream route is for building from source or the
> `nix run` path. See `docs/releasing-installer-images.md`.

To set a known root password on the local console (recommended):

```bash
passwd                     # set a password you'll actually remember
ip -4 addr | grep inet     # find the Pi's IP
```

Then SSH in from your workstation as `root` with that password.

### 3. Bootstrap NixBlitz

The bootstrap command on Pi 5 needs two preflight extras the x86
walkthrough doesn't:

- **`git` on PATH** — the upstream live image doesn't ship it,
  and `nix run` against a `git+https://…` URL needs it.
- **`nixos-raspberrypi.cachix.org` as an extra substituter** —
  without it, nix substitutes 4K-aligned aarch64 binaries from
  cache.nixos.org and the Pi 5's 16K-page kernel SIGBUSes the
  first time it tries to run one. (See quirk #5 in the heads-up
  callout above.)

Drop into a shell with git first:

```bash
nix-shell -p git
```

Then run the bootstrap from inside that shell:

```bash
nix run \
  --extra-substituters "https://nixos-raspberrypi.cachix.org" \
  --extra-trusted-public-keys "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" \
  --experimental-features "nix-command flakes" \
  --no-write-lock-file --refresh \
  git+https://forge.f44.fyi/f44/nixblitz_ng
```

First run takes 1-2 minutes on x86; on Pi 5 it's 5-30 minutes
depending on which closures the cachix has pre-built. The Dart
workspace bits are NixBlitz-specific (no upstream cache) so
they always build locally on the Pi.

The TUI launches into **install mode** (it detects tmpfs root —
the live image is ephemeral, same trigger as x86).

### 4. Walk the install wizard

Identical to x86, with one auto-detected difference:

- The platform field auto-fills to `pi5` (read from
  `/proc/cpuinfo`).
- The wizard's disk picker shows the Pi 5's storage —
  pick `nvme0n1` for NVMe, or `mmcblk0` for SD.
- On confirm, the TUI runs:
  ```
  sudo disko-install --flake $base#nixblitz-pi5-installer \
    --disk main /dev/nvme0n1
  ```
  (`installerAttributeFor` in `install_service.dart` picks the
  Pi 5 target automatically when the detected platform is
  `pi5`.)

`disko-install` partitions the target disk per
`templates/modules/system/disko-pi5.nix` (1 GB FAT firmware
partition + ext4 root), copies the closure, and the upstream
bootloader activation script populates `/boot/firmware`.

### 5. Reboot into the installed system

Power off the Pi 5. Pull the USB stick. Power on. The Pi 5 boots
from the NVMe / SD you installed onto.

First-boot setup runs the same as on x86: change the admin
password, services come up under `nixos-rebuild switch --flake
.#nixblitz-pi5` (the TUI picks the right rebuild target
automatically per `rebuildAttributeFor`), dashboard appears.

### What runs where

| Step                                             | Flake target                                  | Architecture  |
| ------------------------------------------------ | --------------------------------------------- | ------------- |
| Live image (USB stick)                           | `nvmd/nixos-raspberrypi#installerImages.rpi5` | aarch64-linux |
| `disko-install` (lays down the installed system) | `<repo>#nixblitz-pi5-installer`               | aarch64-linux |
| Post-first-boot rebuilds (Apply, Update)         | `<repo>#nixblitz-pi5`                         | aarch64-linux |

The `installer` target only differs from the installed target in
its passwordless sudo override; same kernel, firmware, and disko
layout.

## What's next

- **Make changes**: see [dev-loop.md](dev-loop.md) for the
  edit / test / iterate flow on your dev machine + VM.
- **Understand the layout**: see [architecture.md](architecture.md)
  for the workspace structure, the config-as-source-of-truth
  model, and the few Nix concepts you'll meet.
- **Build a plugin**: see [plugin-authoring.md](plugin-authoring.md)
  for the manifest, the two-stage `plugin.nix` ABI, the
  companion-script pattern, and worked examples cribbed from the
  in-tree dogfood plugins.

If something doesn't work, `~/nixblitz.log` on the VM is the
first place to look.
