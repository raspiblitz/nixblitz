# Ideas & Future Features

Parking lot for ideas we've discussed but don't want to implement right now.

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

## Semver-style config versioning

Currently we use a single integer for schema version (`version: 1`). If the
number of breaking changes grows, splitting into MAJOR.MINOR (breaking vs
additive) might be clearer. `minCompatibleVersion` currently covers this
use case adequately.

**Status:** Only if we ever regret the simple integer scheme.
