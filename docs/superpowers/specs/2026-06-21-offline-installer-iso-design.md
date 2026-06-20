# Self-contained offline installer ISO

Date: 2026-06-21
Status: Approved (design)

Supersedes the install-path half of
`2026-06-18-installer-iso-attic-cache-design.md` (attic-for-install is dropped).

## Problem

Testing the installer re-downloads the node closure from `cache.nixos.org` on
every cycle. The attic-cache approach (serve the closure from a private cache)
needs the cache to hold the _whole_ closure, attic to outrank cache.nixos.org,
a substituter on the live ISO, plus retention/GC to stay under the server's
20 GB — a lot of moving parts and infra to maintain.

A simpler, more scalable solution: **bake the install closure into the ISO** so
`disko-install` finds everything in the live medium's local `/nix/store` and
needs no network at all. No cache server, no substituter config, no quota
management.

## Decisions (settled in brainstorming)

- **Bake the minimal install closure (`initialized = false`)** — base system +
  TUI, services off. That is exactly the bootstrap-gate state `disko-install`
  actually builds (per `templates/hosts/installed.nix`: `initialized = false`
  forces all services off so the install fits the live tmpfs). Smaller than the
  full node; first-boot service enablement (bitcoind/lnd/…) is _not_ covered and
  still pulls from the installed node's own substituters (base.nix's attic) —
  out of scope here.
- **Mechanism: `isoImage.storeContents`** — the iso-image module computes the
  closure of the listed paths and includes it in the ISO's nix store; squashfs
  dedups against the live system's own closure, so the ISO grows only by the
  non-overlapping installed paths.
- **Representative closure, accepted.** The bake uses a stand-in
  hardware-config (the committed fixture); at install time `disko-install`
  builds the _real_ per-machine toplevel, but its **leaf packages are all
  baked**, so it composes locally offline. Only the cheap final system/initrd
  derivation builds on the live medium (no compilation). Tail risk: a config
  forcing a _leaf rebuild_ (e.g. a kernel rebuild) would need network —
  unlikely on x86 + initialized=false + standard kernel.
- **Drop attic from the install path**, repurpose the seed builder, **remove**
  the `installer-seed` flake output + `just iso-cache-push`. Keep base.nix's
  attic substituter (installed-node ongoing rebuilds — unrelated) and the
  `templates/flake.nix` nixConfig warning fix (`f065a6f3`).
- Revert is a **forward change** (the attic + ISO work is intertwined in
  committed commits), not a git-revert.

## Design

### A. The closure builder — `nix/installer-system.nix`

Rename/repurpose `nix/installer-seed.nix` → `nix/installer-system.nix`. Same
`tests/config` store-`profile` trick (assemble `installed.nix` + `installer.nix`

- fixture `config.json` + fixture `hardware-configuration.nix` so the sibling
  reads resolve), with one change: **override the fixture config to
  `initialized = false`** so the result is the minimal install closure. Returns
  the installer `config.system.build.toplevel`.

```nix
{ self, nixpkgs, disko, system ? "x86_64-linux" }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  findModules = …;  # duplicated, as tests/config does, for lock hygiene
  installerConfig =
    (lib.importJSON ../tests/config/fixtures/base/config.json)
    // { initialized = false; };
  profile = pkgs.runCommand "nixblitz-installer-profile" {} ''
    mkdir -p $out/hosts
    cp ${../templates/hosts/installed.nix} $out/hosts/installed.nix
    cp ${../templates/hosts/installer.nix} $out/hosts/installer.nix
    cp ${pkgs.writeText "config.json" (builtins.toJSON installerConfig)} $out/config.json
    cp ${../tests/config/fixtures/base/hardware-configuration.nix} $out/hardware-configuration.nix
  '';
  installerSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { nixblitz = self; };
    modules = (findModules ../templates/modules) ++ [
      (profile + "/hosts/installer.nix")
      disko.nixosModules.default
    ];
  };
in installerSystem.config.system.build.toplevel
```

### B. Bake into the ISO — `nix/iso.nix` + `flake.nix`

`nix/iso.nix` gains a new arg `installerClosure` and:

```nix
isoImage.storeContents = [ installerClosure ];
```

and **removes** the Section-A attic substituter block (`nix.settings.extra-*`).

`flake.nix` builds the installer closure and threads it in:

```nix
installer-iso =
  (import ./nix/iso.nix {
    inherit nixpkgs;
    nixblitzPackage = nixblitzWrapped;
    installerClosure = import ./nix/installer-system.nix {
      inherit self nixpkgs disko system;
    };
  }).config.system.build.isoImage;
```

The `installer-seed` package output is **removed**.

### C. Tooling — `justfile`

- **Remove** `iso-cache-push`.
- **Keep** `iso-build` and `vm-boot` unchanged (still build/boot `.#installer-iso`).

### D. Docs

- **Delete** `docs/superpowers/specs/2026-06-18-installer-iso-attic-cache-design.md`
  (attic-for-install is abandoned). base.nix's attic usage for the installed
  node remains documented in base.nix itself.
- This spec records the offline-ISO approach.

## Testing

- **Build:** `nix build .#installer-iso` succeeds; `result/iso/nixblitz-installer.iso`
  exists. Confirm the installer closure is in the image — e.g. the ISO is
  meaningfully larger than the pre-bake ~1.4 GB, and
  `nix eval .#installer-iso` / the build log shows storeContents realized.
- **No attic on the ISO:** `grep -r extra-substituters nix/iso.nix` → none;
  the live config carries no attic substituter.
- **Offline install (the acceptance test, VM):** `just iso-build` → `just vm-boot`
  with the **VM offline** (or block cache.nixos.org), run the install; it
  completes pulling **nothing** from the network — the closure comes from the
  live store. (If a leaf rebuild is triggered it'd fail offline; that's the
  accepted representative tail.)

## Out of scope

- First-boot **service** closures (bitcoind/lnd/blitz-api) — those install at
  setup time on the running node, which has base.nix's attic substituter.
  Baking them would balloon the ISO (the full-node option we rejected).
- Pi 5 ISO (uses nvmd's installer image).
- Byte-exact per-machine closure (representative bake only).
