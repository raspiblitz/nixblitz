# Getting started

> Operator install docs live on the website
> (`website/content/docs/install-pi5.md` / `install-x86.md`, rendered
> at `/docs/install-pi5` and `/docs/install-x86`). This file is the
> **contributor quickstart** — the fastest way to a running dev VM
> if you're hacking on the TUI itself.

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

## Dev loop: boot a VM from a checkout

From a repo checkout:

```bash
just vm-boot
```

This builds the TUI-carrying `.#installer-iso` (via `just iso-build`
if it isn't already built) and boots it in a local qemu VM, with the
guest's SSH forwarded to host port `10022`. Walk the install wizard
inside that VM exactly like a real Proxmox install — see
`website/content/docs/install-x86.md` for the wizard / first-boot /
dashboard walkthrough; the flow is identical, only the hypervisor
differs.

Once the wizard's disk step comes up, or any time you want a shell
in the live ISO context, SSH in from your host instead of using the
qemu console:

```bash
just vm-ssh-installer
# or directly: ssh -p 10022 nixos@localhost
```

After install completes and the VM reboots into the installed
system:

```bash
just vm-run                 # boot the existing disk image
just vm-ssh                 # SSH in as admin@ (same port-10022 forward)
just vm-clean                # delete the disk image, start over
```

See [dev-loop.md](dev-loop.md) for the full edit / test / iterate
workflow, including the faster loops that skip a full VM rebuild.

> **Why regtest?** The demo / dev-loop flows assume regtest because
> the test-LND helpers (open a channel, pay a self-invoice) need a
> network where you can mine blocks on demand. For an evaluation
> install you probably want regtest. For a real node, pick
> mainnet at the wizard step instead.

## Exercising Lightning without real funds

Once the wizard picks LND on regtest, a secondary `lncli-test`
instance comes up automatically for end-to-end channel + payment
testing. From the dashboard, the `[D]` Debug pane exposes regtest
helpers — a numeric block-count input to mine blocks on demand, plus
a "Regtest auto-miner" that runs as a transient systemd unit and
keeps mining after the TUI exits. That's usually the fastest path to
a synced, channel-ready node for manual testing.

## What's next

- **Full install walkthrough** (wizard, first-boot, dashboard tour,
  Pi 5 hardware notes): `website/content/docs/install-x86.md` and
  `website/content/docs/install-pi5.md`.
- **Make changes**: see [dev-loop.md](dev-loop.md) for the
  edit / test / iterate flow on your dev machine + VM.
- **Build or release installer media**:
  [releasing-installer-images.md](releasing-installer-images.md).

If something doesn't work, `~/nixblitz.log` on the VM is the first
place to look.
