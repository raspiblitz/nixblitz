---
title: Installation - NixBlitz
---

# Installation

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

Boot a live image, run one command, walk a three-question wizard,
reboot into a working node with bitcoind + LND. The shape is the
same on both platforms NixBlitz supports; the live-image source
differs.

> **Why regtest?** The demo / dev-loop flows assume regtest because
> the test-LND helpers (open a channel, pay a self-invoice) need a
> network where you can mine blocks on demand. For an evaluation
> install you probably want regtest. For a real node, pick
> mainnet at the wizard step instead.

## Pick your platform

NixBlitz currently supports two platforms. Pick whichever matches
the hardware you have.

| Platform | When to use                                                                                  | Live-image source                                                                                                                                                                                                                                                                                   |
| -------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **x86**  | Evaluating in a VM (Proxmox / qemu / libvirt) or running on a NUC, server, or repurposed PC. | [**Prebuilt NixBlitz ISO**](https://zipline.f44.fyi/u/nixblitz-x86-installer-1.iso) (offline, TUI baked in) — best for VMs and lower-RAM boxes; or the stock NixOS 25.11 minimal ISO from [nixos.org/download](https://nixos.org/download/) + a network bootstrap on machines with ≥ 8 GB RAM.      |
| **Pi 5** | Production node on dedicated hardware. Pi 5 8 GB recommended, NVMe via the official M.2 HAT. | [**Prebuilt NixBlitz Pi 5 image**](https://zipline.f44.fyi/u/nixblitz-pi5-installer-1.img.zst) (offline, download-and-flash); or build & flash the third-party `nvmd/nixos-raspberrypi` image + network bootstrap (NixOS upstream doesn't ship Pi 5 firmware / vendor kernel / matched bootloader). |

Once installed, the same flake on disk handles runtime + updates
on both platforms. The asymmetry today is purely about how you get
_onto_ the box the first time.

The install wizard auto-detects the platform from `/proc/cpuinfo`
once it runs.

## What you need

### x86 hardware budget

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

Bare metal works the same — same minimums, just with real
hardware instead of a hypervisor.

### Pi 5 hardware budget

- **Pi 5 8 GB**. The 4 GB will boot but is tight alongside
  indexing tools (electrs, etc.).
- **NVMe via the official M.2 HAT** is the supported storage
  config. SD-only works for evaluation; not recommended for a
  long-running node.
- **A USB stick** to boot the live image from. ≥4 GB.
- **Active cooling required.** Initial chain sync pegs the CPU at
  100% for days; passive heatsinks throttle hard and the box runs
  uncomfortably hot. The official Active Cooler (or any
  fan-equipped case) is the safe choice for any node that will
  actually sync mainnet.

## 1. Get the live image

Two routes, pick by RAM and use-case. The **prebuilt NixBlitz
images** (direct download links per platform below)
bake the whole install closure, so a VM, a low-RAM box, or an
offline install never does a memory-heavy on-device build — flash
and go. A machine with **≥ 8 GB RAM and a network** can instead take
the lighter **official image + network bootstrap** (the TUI pulls
itself over the network on first run). Both end at the same install
wizard.

### x86: prebuilt NixBlitz ISO (VMs / low-RAM)

Download [`nixblitz-installer.iso`](https://zipline.f44.fyi/u/nixblitz-x86-installer-1.iso). It
carries the TUI and an offline install closure, so nothing is
fetched during install. Attach it to the VM, or flash it to a USB
stick for bare metal:

```bash
sudo dd if=nixblitz-installer.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

(Building it yourself, or cutting a release, is documented in
`docs/releasing-installer-images.md`.)

### x86: stock NixOS ISO (≥ 8 GB RAM, network bootstrap)

Alternatively, grab the **NixOS 25.11 minimal ISO** from
[nixos.org/download](https://nixos.org/download/) (about 1 GB).
The graphical ISO works too if you prefer a graphical console;
neither is "more correct." The TUI bootstraps over the network on
first run (§3), so this path wants a machine that can build the
config locally — hence the ≥ 8 GB guidance.

You don't need Nix on your host. Everything happens inside the VM
(or on bare metal).

### Pi 5: live image

NixOS upstream doesn't ship Pi 5 firmware / vendor kernel /
matched bootloader, so there's no vanilla NixOS Pi 5 medium — and
no "official" image to just download. Two routes:

**Prebuilt NixBlitz Pi 5 image (offline, download-and-flash):**

Download [`nixblitz-pi5-installer.img.zst`](https://zipline.f44.fyi/u/nixblitz-pi5-installer-1.img.zst). Like
the x86 ISO it bakes the TUI + the offline install closure and uses
a known `nixos` / `nixblitz` login, so none of the upstream rough
edges below apply. Flash it (the `.img.zst` is zstd-compressed):

```bash
zstd -dc nixblitz-pi5-installer.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Raspberry Pi Imager flashes `.img.zst` natively too. Then skip to
§2 — no network bootstrap needed.

**Build & flash the upstream image yourself (≥ 8 GB, network bootstrap):**

The end-to-end flow mirrors x86 — same bootstrap command, same
install wizard — only the live image differs. NixBlitz layers on the
third-party
[`nvmd/nixos-raspberrypi`](https://github.com/nvmd/nixos-raspberrypi)
flake (pinned to a specific tag), which doesn't publish pre-built
`.img` files, so you build it:

Upstream maintains a Cachix binary cache for the heavy bits (vendor
kernel, firmware, installer closure). **Enable it before
building** — otherwise `nix build` will try to compile the
kernel locally, which on x86 means cross-compilation or qemu
emulation and a multi-hour wait.

```bash
# One-time, on the build machine:
nix --experimental-features "nix-command flakes" run nixpkgs#cachix \
  -- use nixos-raspberrypi
```

Then build the image. On a machine with Nix installed
(`x86_64-linux` works fine — the closure substitutes from the
Cachix):

```bash
nix --experimental-features "nix-command flakes" build \
  github:nvmd/nixos-raspberrypi/v1.20260707.1#installerImages.rpi5
```

First run downloads ~500 MB. The result is a
`result/sd-image/<name>.img.zst` symlink. Flash to a USB stick:

```bash
zstd -dc result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

(Replace `/dev/sdX` with your USB stick's path. Triple-check.)

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
> 3. **SSH is enabled by default** with no authorized keys —
>    login requires the root password.
> 4. **`git` is not on PATH.** The bootstrap step needs it (`nix
run` against a `git+https://…` URL); drop into
>    `nix-shell -p git` first. The fully-installed system has git
>    (we add it via `features.system.base`).
> 5. **You MUST add the `nixos-raspberrypi.cachix.org`
>    substituter or the bootstrap SIGBUSes mid-fetch.** The Pi 5
>    vendor kernel uses 16K pages; cache.nixos.org's standard
>    aarch64 binaries are 4K-aligned. Mmap'ing them on a 16K-page
>    kernel faults with SIGBUS the first time the binary is
>    exercised, and `nix run` crashes hundreds of MB into the
>    closure with `Bus error (core dumped)`. The bootstrap
>    command in section 3 below includes the substituter and
>    public key as flags so you don't have to configure it
>    separately.
>
> To skip all of this, use the **prebuilt NixBlitz Pi 5 image**
> above — it bakes the closure in, ships with a known `nixos` /
> `nixblitz` login, and needs no network bootstrap. This upstream
> route is for building from source or when you specifically want
> the `nix run` path.

## 2. Boot the live environment

### x86

Boot the ISO from inside a VM or on bare metal. You land on a
NixOS shell as user `nixos`. No password is set on the live ISO;
sudo is passwordless there. (The _installed_ system uses NixOS's
password-required default; we prompt you to set an admin password
during first-boot setup.)

#### Optional: SSH from your host

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

2. Find the VM's IP:

   ```bash
   ip -4 addr | grep inet
   ```

3. From your host, SSH in:

   ```bash
   ssh nixos@<vm-ip>
   ```

The rest of the install wizard runs identically over SSH; the only
difference is you can paste the bootstrap command instead of
typing it.

### Pi 5

Insert the USB stick. If you're installing onto NVMe via M.2,
make sure the NVMe drive is also seated. Power on. The Pi 5
boots from USB (default boot order priority).

To set a known root password on the local console (recommended):

```bash
passwd                     # set a password you'll actually remember
ip -4 addr | grep inet     # find the Pi's IP
```

Then SSH in from your workstation as `root` with that password.

## 3. Bootstrap the NixBlitz TUI

The bootstrap command shape is the same on both platforms; Pi 5
needs two extra flags (substituter + trusted key) and one
preflight (`git` on PATH).

### x86

From the live ISO shell:

```bash
nix run git+https://forge.f44.fyi/f44/nixblitz_ng \
  --experimental-features "nix-command flakes" \
  --no-write-lock-file --refresh
```

### Pi 5

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

### What this does (both platforms)

- `nix run` — builds and executes the flake's default app.
- `--experimental-features "nix-command flakes"` — stock NixOS
  still gates flakes behind a feature flag.
- `--no-write-lock-file` / `--refresh` — the live ISO root is
  tmpfs and we don't want stale cache from previous attempts.
- (Pi 5) `--extra-substituters` / `--extra-trusted-public-keys` —
  the Pi 5 vendor kernel needs 16K-aligned aarch64 binaries; the
  upstream cachix bucket has them.

First-run takes 30-60 seconds on x86; 5-30 minutes on Pi 5
depending on which closures the cachix has pre-built. The Dart
workspace bits are NixBlitz-specific (no upstream cache) so they
always build locally on the Pi.

The TUI launches into **install mode** because it detected tmpfs
root (live ISO context).

## 4. Walk the install wizard

Three decisions, defaults are sane:

1. **Disk** — pick the disk you provisioned for the install.
   The wizard shows size + model so you can't get it wrong.
   - x86: typically `vda` or `sda` in a VM, `nvme0n1` / `sdX` on
     bare metal.
   - Pi 5: `nvme0n1` for NVMe, `mmcblk0` for SD.
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

Takes 2-5 minutes on a typical VM, 5-10 minutes on Pi 5. The TUI
streams disko's output live; you'll see partitioning, copying
store paths, installing GRUB (x86) / writing firmware (Pi 5).

When done, the TUI offers **Reboot**. Hit Enter.

- x86: GRUB picks up the new generation.
- Pi 5: Power off, **pull the USB stick**, power on. The Pi 5
  boots from the NVMe / SD you installed onto.

## 5. First boot

The TUI launches automatically (auto-login on `tty1`) into
**first-boot setup**. Same flow on both platforms.

### Set the admin password

NixBlitz uses NixOS's default `wheelNeedsPassword = true`. The TUI
prompts you for sudo authorization first time you do something
privileged in a session, and caches the timestamp for ~10 min
after. The default admin password from the install is `nixblitz`
— type it when the sudo modal appears.

Then enter a new password. The TUI runs `chpasswd` over the
cached sudo timestamp.

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
LND).

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

## 6. Tour the dashboard

The header strip shows `NIXBLITZ` on the left, `<lnd alias> | <platform> | <pending status>`
in the middle (e.g. `MyNode | Pi 5 | all applied`), and the build
version on the right. Below that, the top-menu strip:

```
[Dashboard]  Configure  System  Debug                  [?] Help  [q] Quit
```

`←`/`→` (or `h`/`l`) cycle the strip and switch view immediately.
The active entry is bracketed and accent-colored.

Below the menu, the tile grid. Two tiles are bundled:

| Tile         | What                                                            |
| ------------ | --------------------------------------------------------------- |
| **System**   | uptime + per-service active/inactive (blitz-api, nginx, redis…) |
| **Hardware** | memory + disk usage from `/proc`                                |

A separate **node tile** above the grid summarizes node identity:
hostname, uptime, last apply timestamp, and an `<n> to apply`
status badge that counts both pending config edits and pending
upstream input bumps.

Bitcoin / Lightning tiles come from the **bitcoind** / **lnd** (or
**cln**) plugins the wizard installed — they're not built into the
binary. Removing those plugins removes their tiles; additional
plugins (tailscale, lnbits, …) added later via
`nixblitz plugin add …` register their own tiles the same way.

Global hotkeys work from any view (equivalents to picking a top-menu
entry):

- `[c]` Configure — typed-options editor with a sidebar of
  per-service sections
- `[a]` Apply / `[u]` Update — both land on **System**, whose
  sidebar splits read-only **Check** probes, destructive **Apply**
  rebuilds, and **Power** (shutdown / reboot) into three sections
- `[D]` Debug — service health, log tail, regtest helpers
- `[?]` Help
- `[q]` Quit — during an in-flight Apply / Update / sudo prompt,
  the first `q` arms a 3-second confirm window and shows a
  banner; second `q` actually quits

Walk through Configure for a moment. Use `j`/`k` (or `↑`/`↓`) to move
through the sidebar's sections; `Enter` (or `l` / `→`) focuses the
content pane; toggle a value; `Esc` returns to the sidebar, then to
the dashboard. The node tile's status badge now reads
`1 to apply`. Press `[a]` — that lands on **System → Apply**,
which auto-rewrites any drifted templates as a preflight, then
shows the unified `git diff` against `~/nixblitz/`. Commit + rebuild
from there.

That's the loop: edit → diff → apply.

After a few hours the node tile's `system updates` row populates
once the periodic check timer (`nixblitz-check-light.timer`) has
run. The status badge folds that count — along with any pending
config edits and any `unapplied rebuild` from a previous Apply
that crashed before completing — into the same `<n> to apply`
indicator. Trigger a check on demand from inside the TUI via
**System → Check → Simple check** (or **Heavy check** for the
full `nvd diff`), or from any shell with `nixblitz check light`
/ `nixblitz check heavy`.

The Heavy check probes the cache first via `nix build --dry-run`
and only runs `nvd diff` when every path is substitutable; if any
derivation would need a local compile the check bails out before
realising the toplevel (to spare a Pi 5 from a multi-hour rustc
storm) and surfaces the would-build list under **View packages
to compile** — `[v]` from anywhere in the Check section is the
shortcut into the same viewer.

## 7. Access the running node

From your host:

```bash
# SSH into the box (admin user, the password you set at first-boot)
ssh admin@<ip>
```

Inside the box you have:

- `bitcoin-cli`, `lncli`, `lightning-cli` on `PATH`.
- On regtest also `lncli-test` for the secondary LND.
- `nixblitz` itself — re-run the TUI any time. Same binary, same
  config.

## What's next

- [Updates](/docs/updates) — how to keep the node updated without
  surprises (which key to press, what the badge means, what the
  Pi 5's compile-storm warning is, how rollback works).
- [Architecture](/docs/architecture) — the layout, the
  config-as-source-of-truth model, and the few Nix concepts
  you'll meet.
- [Plugins](/docs/plugins) — extending NixBlitz with extra
  services or integrations.

If something doesn't work, `~/nixblitz.log` on the box is the
first place to look.
