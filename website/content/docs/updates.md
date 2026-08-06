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

**System → Updates.** Opens a status panel with a **NixBlitz** row
(the system + all its flake inputs, rolled up) and a **Plugins**
row (with a per-plugin breakdown when something moved), each
showing one of three states:

- `✓ up to date` — nothing waiting.
- `↑ update available` — upstream has moved past your locked version.
- `not checked yet` — the periodic check hasn't run (fresh install).

A check is read-only with respect to your node: it looks upstream,
stages what it finds as a _candidate_, and stops. Nothing changes
on the running system until you decide to Apply.

## How to actually apply an update

Two steps, whatever kind of update is waiting:

### 1. Check (usually already done for you)

The daily timer runs the check on its own; **System → Updates →
Check for updates** runs the same thing on demand. The check
looks upstream, and when something moved it stages the result as
a candidate — your node keeps running exactly what it ran before.

**What's changing…** (same panel) shows the details: a
package-by-package version diff (`Bitcoin Core 27.1 → 28.0`,
`nginx 1.26.0 → 1.26.1`, …) when everything is downloadable, or
the list of packages your node would have to compile locally when
it isn't (see the Pi warning below).

### 2. Apply — `[a]`

One Apply deploys everything queued, whatever the mix: your own
Configure edits, a staged system update, plugin updates. Press
`[a]` (or pick **System → Apply → Apply pending changes**). The
review screen lists each queued category — your config diff,
upstream pin updates, plugin bumps — then asks for sudo, commits
to the internal git history, and streams the rebuild live.
Success or failure is reported on a final screen.

There's deliberately no second deploy verb in the TUI. The review
screen's `[d] Discard all` resets the whole queue if you change
your mind; for scripted or granular bumps the CLI keeps separate
verbs (`nixblitz update tui`, `nixblitz update plugins`).

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

You'll see this coming **before** it happens. The check probes the
caches as part of its dry run, and when packages would have to
build locally the Updates panel warns you — "Applying builds 108
packages on the node first — can be slow on a Pi 5." That's the
TUI telling you: "if you Apply right now, the Pi will compile 108
packages from source, and that takes hours."

What to do:

- **Wait a day or two.** Upstream caches catch up regularly. Run
  `Check for updates` again later; the number usually drops to
  near zero once the cache rebuilds.
- **Apply anyway.** If you have the time and you want the
  update, go ahead — the node stays responsive (we cap nix to 3
  of the 4 cores so bitcoind and the dashboard keep working
  during the build) but the rebuild itself is slow. The TUI
  streams output live; you can watch progress.
- **`What's changing…`** lists exactly which packages would be
  built. Same panel, action right below `Check for updates`.

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
tell you. The check timer runs on its own (daily, with a few
hours of random spread) and surfaces whatever's available; you
decide when to act.

A few rules of thumb:

- **Mainnet operators with channels**: avoid Apply / Update
  during high-routing periods. A rebuild restarts services; an
  in-flight payment in the middle of that is a bad time.
- **Regtest / evaluation**: update whenever you want. Worst case,
  rollback.
- **A security fix is announced**: don't wait for the timer. Run
  `Check for updates` manually (System → Updates); if the
  affected input has moved, Apply.
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
