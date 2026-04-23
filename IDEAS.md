# Ideas & Future Features

Parking lot for ideas we've discussed but don't want to implement right now.

## Richer diff in the "config too new" screen

Today the `ConfigTooNewView` just dumps the raw `config.json` text so the user
can see what's there before continuing. A richer version would structurally
diff the on-disk JSON against what the TUI would write back after a round-trip
through `NixblitzConfig.fromJson` + `toJson`, highlighting specifically which
fields this TUI doesn't understand and would drop. Two paths:

- Parse both JSONs, walk the trees recursively, emit a per-field summary:
  "`blitz_api.newFeature` (unknown — will be dropped on save)".
- Write both blobs to temp files and run `git diff --no-index`, reuse the
  existing `ScrollableLog` renderer.

**Status:** Park. The raw dump is enough for MVP and adding structure needs
unknown-field tracking in the model first (right now fromJson silently
discards unknowns — see nixblitz_config.dart).

## Bitcoin testnet / signet support

Currently only `mainnet` and `regtest` are offered. `testnet`/`signet`
require section-aware `bitcoin.conf` generation — nix-bitcoin's
`modules/bitcoind.nix` writes `rpcbind`/`rpcport` at the top level of
the conf, and Bitcoin Core rejects those at top level when running on
any non-main chain (they must live inside the matching `[test]` /
`[signet]` section).

**Path forward:**
- Fork nix-bitcoin to `forge.f44.fyi/f44/nix-bitcoin` and patch
  `modules/bitcoind.nix` so it emits a section header matching the
  active chain (generalize the existing `regtest=1\n[regtest]` block)
- Or: ditch nix-bitcoin's bitcoind module in favor of NixOS's built-in
  `services.bitcoind.<name>` and reimplement the RPC wiring ourselves
- Update the network picker in `install_view.dart` + `configure_view.dart`
  once support lands

**Status:** Park until we decide whether we want a long-lived nix-bitcoin
fork. Mainnet + regtest cover the common cases for now.

## Convert existing NixOS to NixBlitz

**Scenario:** User is already running a NixOS system (not a live ISO, not a
NixBlitz install) and runs `nixblitz`. Instead of refusing (current behavior),
offer to convert the system.

**Rationale:** Some users may have an existing NixOS server they want to
turn into a Bitcoin/Lightning node without reinstalling.

**Sketch:**
- Detect: not on live ISO + no `~/nixblitz/` + running NixOS
- Prompt: "Convert this system to NixBlitz?"
- On confirm:
  - Scaffold `~/nixblitz/` from embedded templates
  - Run `nixos-generate-config` to capture current hardware
  - Write `config.json`
  - Don't run disko (disk is already set up)
  - Run `nixos-rebuild switch --flake ~/nixblitz`
- Risks: user's existing NixOS config gets replaced. Need clear confirmation
  and ideally a backup of `/etc/nixos` first.

**Status:** Future. Current behavior: refuse with a message pointing to the
ISO install path.

## Lightning wallet password change (Password C)

RaspiBlitz has this via `blitz.passwords.sh set c`. Would change both LND
and CLN wallet passwords. Requires old password + new password.

**Status:** Park until LND/CLN integration is fleshed out. See
`docs/decisions/password-management.md`.

## RPC password management (Password B)

RaspiBlitz manages a shared RPC password used by bitcoind, electrs, BTCPayServer,
etc. With nix-bitcoin, this may be handled automatically via generated secrets —
need to evaluate whether user management is needed at all.

**Status:** Evaluate when we add more services.

## Brute force protection for password operations

RaspiBlitz adds a delay on repeated password check attempts (cached via a
small state file). Useful if we expose password checking over a network
interface.

**Status:** Only relevant when/if we add WebUI or network-exposed password
operations.

## Password hash storage

RaspiBlitz stores salted SHA-512 hashes in `/mnt/hdd/app-data/passwords/` so
services can verify passwords without having them in plaintext. Useful for
Password B (RPC) and Password C (Lightning) scenarios.

**Status:** Implement alongside Password B/C work.

## Early swap for install on low-RAM devices

The live NixOS ISO stages nix store builds in a tmpfs backed by RAM.
When installing a large config (bitcoind + LND + nix-bitcoin), the
tmpfs can fill up on devices with ≤8GB RAM, causing "No space left
on device" before disko-install finishes.

Possible fixes:
- After disko partitions the disk but before the large build starts,
  mkswap a small partition and `swapon` it so the tmpfs can overflow
- Or: add a "zram" swap device sized from available RAM
- Or: ship a custom installer ISO that does this automatically on boot

Affects Pi4 8GB, Pi5 8GB, and any x86 node with ≤8GB RAM.

**Status:** Not urgent (VM workaround: bump -m 16384). Implement when
we target real hardware with less RAM.

## Semver-style config versioning

Currently we use a single integer for schema version (`version: 1`). If the
number of breaking changes grows, splitting into MAJOR.MINOR (breaking vs
additive) might be clearer. `minCompatibleVersion` currently covers this
use case adequately.

**Status:** Only if we ever regret the simple integer scheme.
