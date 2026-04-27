# Getting started

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

NixBlitz is **not** a custom ISO. You boot stock NixOS and bootstrap
the TUI from the network on first run. Same flake handles install,
runtime, and updates — there's no second image to maintain.

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
- blitz-api (FastAPI; waits for lnd's macaroon)
- blitz-web (the React UI behind nginx)

When done, you land on the **dashboard**.

## Tour the dashboard

| Tile          | What                                                    |
| ------------- | ------------------------------------------------------- |
| **System**    | hostname, network, uptime, key services up / down state |
| **Hardware**  | memory + disk usage from `/proc`                        |
| **Bitcoin**   | sync %, block height, peer count, mempool size          |
| **Lightning** | alias, pubkey, peer + channel counts, balances          |

Plus any tiles installed plugins added (none yet).

Footer hints show shortcuts:

- `[c]` Configure — open the typed-options editor
- `[a]` Apply — review pending changes + commit + rebuild
- `[u]` Update — pull TUI + plugin + flake updates
- `[D]` Debug — service health, log tail, regtest helpers
- `[?]` Help

Walk through Configure for a moment. Tab through the service
sections; toggle a value; hit Esc to return. The dashboard now
shows an orange `1 pending change` banner. Press `[a]` to review
the diff. The Apply view shows the unified `git diff` against
`~/nixblitz/config.json`. Commit + rebuild with `[a]` again.

That's the loop: edit → diff → apply.

A second banner may also appear above the tiles after a few hours:
**`updates available: nixpkgs, … — checked Xh ago`**. This is the
periodic update-check service — a daily lightweight cron-style
timer hits each flake input's upstream HEAD, and a weekly heavy
timer additionally evaluates the new system + runs `nvd diff` for
a per-package version delta. Both write to
`/var/lib/nixblitz-tui/update-status.json`; the dashboard reads it
each render. Run **`nixblitz check light`** or **`nixblitz check
heavy`** at any shell to trigger them on demand.

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
