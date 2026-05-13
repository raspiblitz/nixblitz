---
title: Updates - NixBlitz
---

# Keeping your node updated

> **⚠ Highly experimental — under construction.** NixBlitz has NOT
> received a thorough security review. Don't use it for production
> funds. Run on regtest in a VM or on dedicated hardware
> you're okay reinstalling. Things will break.

A walking tour of what "updating" means on a NixBlitz node, what
the TUI shows when an update is waiting, and what to actually
press. No NixOS background required — if you've made it through
the installation, you have everything you need.

For the technical view (the flake-lock / nixos-rebuild split that
sits under all of this), see
[Architecture → The update model](/docs/architecture#the-update-model).

## Three kinds of updates

The node has three independent moving parts. Any of them can
have an update waiting without affecting the others:

| What                   | Updates when…                                                                         |
| ---------------------- | ------------------------------------------------------------------------------------- |
| **The TUI itself**     | The NixBlitz project ships a new release.                                             |
| **The system**         | Upstream packages move — A new Bitcoin Core lands, a CVE in nginx, a kernel fix, etc. |
| **Individual plugins** | A plugin author tags a new version of LNbits / Tailscale / your own custom plugin.    |

Plus a fourth, hidden one: **your own configuration edits**. When
you toggle something in Configure, that's a pending change too,
and it lives in the same `X to apply` count as the others.

## How the TUI tells you something's waiting

Two places to look:

**Node tile, top of the dashboard.** The status badge reads either
`all applied` (you're caught up) or `<n> to apply` (something is
pending — could be your own edits, an upstream input bump, or a
rebuild that never finished from a previous session).

**System → Check.** Opens a status panel listing each flake input
(`disko`, `nixblitz`, `nixos-raspberrypi`, `nixpkgs`, …) with one
of three icons:

- `✓ up to date` — nothing waiting.
- `↑ update available` — upstream has moved past your locked version.
- a plain dash — the periodic check hasn't run yet (fresh install).

The "checks" are passive — they just look. Nothing changes on
your node until you decide to act.

## How to actually apply an update

Three flows, three sections of the System view:

### Your own edits — `[a]` Apply

You changed something in Configure (a hostname, a network, a
plugin toggle), the badge flipped to `1 to apply`, you want to
deploy it. Open the dashboard, press `[a]`. The TUI shows a
unified diff of what you changed, asks for sudo, commits the
change to its internal git history, and runs the rebuild. Output
streams live; success or failure is reported on a final screen.

### Everything together — `[u]` Update entire system

You want fresh versions of bitcoind, lnd, nginx, and the kernel
all in one go. Same view (`System`), pick `Update entire system`.
The TUI fetches new metadata for each input, asks you to confirm
the package-by-package diff (`Bitcoin Core 27.1 → 28.0`,
`nginx 1.26.0 → 1.26.1`, …), then commits + rebuilds in one
transaction.

### Individual plugins — `Update plugins`

LNbits ships a fix you want without touching the rest of the
system. Same System view, pick `Update plugins`. The TUI
refreshes each installed plugin's source, shows what changed,
and chains a rebuild.

These three flows are independent. Applying your config edits
doesn't fetch new upstream versions; updating upstream doesn't
deploy your config edits. The TUI just makes sure you can do any
of them in one keystroke.

## What can go wrong (and how the node protects you)

### The Pi 5 compile-storm — important if you run on Pi hardware

This one is worth its own warning paragraph. The Pi 5 needs a
custom kernel + page-size-16k jemalloc that the public Nix cache
doesn't ship; we get those binaries from a separate cache run by
the upstream Pi project. That cache is rebuilt periodically — but
**when your node's package versions move past whatever the
upstream cache most recently published, the Pi has to build
those packages from source**. On a 4-core Pi 5, a fresh build of
the Rust toolchain alone can take 1-3 hours; a full rebuild of
the closure can take longer.

You'll see this coming **before** it happens. After running
`Heavy check` (under System → Check), the status panel will say
something like `↑ system closure: 108 need compile`. That's the
TUI telling you: "if you Apply right now, the Pi will compile
108 packages from source, and that takes hours."

What to do:

- **Wait a day or two.** Upstream caches catch up regularly. Run
  `Heavy check` again later; the number usually drops to near
  zero once the cache rebuilds.
- **Apply anyway.** If you have the time and you want the
  update, go ahead — the node stays responsive (we cap nix to 3
  of the 4 cores so bitcoind and the dashboard keep working
  during the build) but the rebuild itself is slow. The TUI
  streams output live; you can watch progress.
- **`View packages to compile`** lists exactly which packages
  would be built. Same panel, action right below `Heavy check`.

On x86 hardware (VM or bare metal), this case is rare — the
public Nix cache covers nearly everything you'll need, and
rebuilds finish in a few minutes.

### A rebuild fails midway

NixOS keeps the previous working system around as a "generation."
If the new system fails to activate (a service won't start, a
config is rejected), the running system is **unchanged** — you
weren't deploying a broken version, the broken version just
couldn't take over. Reboot and you're on the old generation
automatically; or run `sudo nixos-rebuild --rollback` to revert
explicitly. The TUI surfaces the failure on the final screen
with the rebuild's exit code and the failed unit name.

### You quit during an Apply

A long rebuild plus a fat-fingered `q` would normally leave the
node in a weird half-applied state. The TUI guards against this:
during an in-flight rebuild, the first `q` doesn't quit — it
arms a 3-second confirm window and shows a banner. Second `q`
within those three seconds quits anyway; anything else cancels
the arm.

If you do quit a rebuild (deliberately or not), the next launch
notices: the node tile picks up an `unapplied rebuild` row, the
badge counts it as pending, and one more `[a]` Apply puts the
node back in sync.

### You want to undo a change

Every Apply is a commit in the TUI's internal git history (it
lives at `~/nixblitz/` on the box). `git revert <commit>` followed
by another `[a]` Apply rolls the change back the same way it
went in — diff, sudo, commit, rebuild. Or `sudo nixos-rebuild
--rollback` for an instant revert without touching git.

## When should you update?

Honest answer: there's no urgency the dashboard doesn't already
tell you. The check timers run on their own (daily for cheap
probes, weekly for the heavy one) and surface whatever's
available; you decide when to act.

A few rules of thumb:

- **Mainnet operators with channels**: avoid Apply / Update
  during high-routing periods. A rebuild restarts services; an
  in-flight payment in the middle of that is a bad time.
- **Regtest / evaluation**: update whenever you want. Worst case,
  rollback.
- **A security fix is announced**: don't wait for the timer. Run
  `Simple check` manually (System → Check → Simple check); if
  the affected input has moved, run `Update entire system`.
- **The Pi shows "N need compile"**: revisit in a few days unless
  you're ready for the wait.

That's it. The node nags you when something's pending, you press
a key when you're ready, NixOS handles the rollback if it goes
wrong. No subscription, no scheduler, no surprises.

## What to read next

- [Architecture → The update model](/docs/architecture#the-update-model) —
  if you want the under-the-hood story (flake.lock, nixos-rebuild, the
  on-disk last-applied record).
- [Plugins](/docs/plugins) — how to write or audit a plugin if
  you're adding services beyond the bundled ones.
