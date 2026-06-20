# x86 installer ISO with the nixblitz TUI

Date: 2026-06-18
Status: Approved (design)

## Problem

There is no buildable x86 installer image. The current x86 test/install workflow
boots a **manually-downloaded stock `nixos-minimal` ISO** (`just vm-boot` points
at `~/Downloads/nixos-minimal-*.iso`) and bootstraps the TUI from there. We want
a reproducible, buildable x86_64 ISO that boots into a minimal live NixOS,
auto-launches the nixblitz TUI, and lets the operator install the full node to
disk via the existing `disko-install --flake ~/nixblitz#nixblitz-installer` flow.

## Decisions (settled in brainstorming)

- **Role: live installer medium.** Boot → auto-launch TUI → TUI installs the node
  to disk via the existing disko-install path. Not a live-run/demo node.
- **Lives in the top-level (dev) flake, not `templates/`.** The ISO is a
  dev/release artifact (built on a dev machine / CI), the sibling of the TUI
  package and website. `templates/flake.nix` is scaffolded onto every node and
  must not carry build-only config. Keeping the ISO at top level also avoids a
  circular flake input (templates already takes the TUI flake as its `nixblitz`
  input).
- **Offline scope: phase 1 = source-baked, build uses network** (same posture as
  today — no regression). Structured so **phase 2** (pre-seed the installer
  closure for fully-offline install) is a localized addition at a marked hook,
  not a restructure.
- **Mechanism: native nixpkgs installation-cd profile**
  (`installer/cd-dvd/installation-cd-minimal.nix`) + `.config.system.build.isoImage`.
  No new flake input.
- **Live-medium TUI wiring: a dedicated minimal module in `nix/iso.nix`** (TUI
  package + ~15-line auto-launch + passwordless sudo). The live medium needs
  *less* than the full node `features.system.base`, and this fully decouples the
  ISO from `templates/`. The auto-launch snippet is duplicated from
  `templates/modules/system/base.nix` (acceptable; see Alternatives).
- **Tooling: `just iso-build` + repoint `just vm-boot`** at the freshly-built ISO.

## How the pieces already fit

- The top-level flake builds the **wrapped TUI** `self.packages.${system}.nixblitz`
  (`nixblitzWrapped`), which already puts `disko` + `git` on PATH — exactly what
  the install wizard's `disko-install` needs.
- The TUI **embeds the templates** (`EmbeddedTemplates`) and scaffolds the flake
  to `~/nixblitz` at first run (`ScaffoldService`). So the install flake *source*
  is carried by the TUI — "baked in" for free in phase 1.
- `InstallService.diskoInstall` runs
  `sudo -n disko-install --flake <~/nixblitz>#nixblitz-installer --disk main <dev>`.
  It detects the live source mount (`/iso`, `/run/initramfs/live`). The
  `nixblitz-installer` config stays in `templates/` (it's the disk-install
  *target*, scaffolded to the node) — the ISO does not embed it in phase 1.

## Design

### A. ISO config — `nix/iso.nix` (new)

A self-contained NixOS live-medium config built with `nixpkgs.lib.nixosSystem`
(`system = "x86_64-linux"`), taking the wrapped TUI package as an argument so it
doesn't reach into `templates/`:

```nix
# nix/iso.nix
{ nixpkgs, nixblitzPackage }:
nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    ({ modulesPath, lib, ... }: {
      imports = [
        "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
      ];

      # The TUI (wrapped: disko + git on PATH). The operator runs the
      # install wizard from here; it scaffolds ~/nixblitz from embedded
      # templates and calls disko-install --flake ~/nixblitz#nixblitz-installer.
      environment.systemPackages = [ nixblitzPackage ];

      # The install wizard runs disko-install / mount / nixos-generate-config
      # non-interactively via `sudo -n`. The live medium is ephemeral, so
      # passwordless sudo is the right default here (mirrors templates/hosts/
      # installer.nix's rationale).
      security.sudo.wheelNeedsPassword = false;

      # Auto-launch the TUI on the live console login. Mirrors the snippet in
      # templates/modules/system/base.nix (kept as a small dedicated copy so
      # the dev flake stays decoupled from templates/). The guard skips
      # non-interactive / already-launched shells.
      programs.bash.interactiveShellInit = ''
        if [ -z "''${NIXBLITZ_AUTOLAUNCHED:-}" ] && [ -t 0 ] && [ -t 1 ] \
            && command -v nixblitz >/dev/null 2>&1; then
          export NIXBLITZ_AUTOLAUNCHED=1
          nixblitz
        fi
      '';

      isoImage.isoName = lib.mkForce "nixblitz-installer-x86_64.iso";

      # ── Phase-2 hook (offline install) ──────────────────────────────
      # To make disko-install work with no network, pre-seed the installer
      # closure into the live store here, e.g.:
      #   isoImage.storeContents = [ <templates#nixblitz-installer toplevel> ];
      #   isoImage.includeSystemBuildDependencies = true;
      # Left out in phase 1 (build uses network). Adding it crosses into the
      # templates flake — see the spec's phase-2 note.
    })
  ];
}
```

Exact auto-launch wiring (which live user logs in, whether nushell login.nu is
also needed) is finalized in the plan + confirmed by the boot smoke test; the
bash path above covers the installation-cd default console.

### B. Flake output — top-level `flake.nix`

Inside the existing `flake-utils.lib.eachDefaultSystem` `in { ... }`, expose the
artifact x86-only (it references `nixblitzWrapped`, already in scope):

```nix
packages = {
  default = self.packages.${system}.nixblitz;
  nixblitz = nixblitzWrapped;
  nixblitz-unwrapped = nixblitzUnwrapped;
  website = nixblitzWebsite;
} // lib.optionalAttrs (system == "x86_64-linux") {
  installer-iso =
    (import ./nix/iso.nix { inherit nixpkgs; nixblitzPackage = nixblitzWrapped; })
    .config.system.build.isoImage;
};
```

Build: `nix build .#installer-iso` → `result/iso/nixblitz-installer-x86_64.iso`.

### C. Tooling — `justfile`

- **`just iso-build`** — `nix build .#installer-iso` and print the resulting
  `result/iso/*.iso` path.
- **`just vm-boot`** — build the ISO if missing (or always, fast when cached),
  then boot it in QEMU instead of the hardcoded `~/Downloads/nixos-minimal-*.iso`.
  The existing disk-image / `vm-ssh-installer` parts are unchanged.

## Testing

- **Eval/build:** `nix build .#installer-iso` succeeds on x86_64-linux. Optionally
  add an eval check that `nix/iso.nix` evaluates, alongside the existing
  `config-installer-*` checks surfaced by `just test`.
- **Boot smoke (manual/VM):** `just iso-build` → `just vm-boot` → the ISO boots,
  the TUI auto-launches on the live console, and `disko-install` can target a
  blank VM disk (the existing VM install path). Confirms the live medium carries
  a working TUI + disko.

## Alternatives considered

- **ISO in `templates/flake.nix`** (original sketch): rejected — ships build-only
  config to every node and risks a circular flake input.
- **Reuse `features.system.base` / path-import base.nix**: rejected for phase 1 —
  drags the full node base feature (substituters, full package set, shell wiring)
  onto the live medium and re-couples the dev flake to `templates/`. The
  ~15-line auto-launch duplication is the smaller cost.
- **Extract a shared auto-launch module** both base.nix and iso.nix import: nicer
  DRY, but a refactor touching shipping node config — out of scope here; revisit
  if the duplication ever drifts.
- **nixos-generators**: rejected — adds a flake input for a single output the
  native profile already produces.

## Out of scope

- **Phase 2: fully-offline install** (pre-seed the `nixblitz-installer` closure +
  flake inputs into the ISO store). Marked hook in `nix/iso.nix`; crosses into
  the templates flake, so deferred.
- **Pi 5 ISO** — Pi 5 already uses nvmd's prebuilt installer image; unchanged.
- **Refactoring the auto-launch into a shared module** (see Alternatives).
