# x86 installer ISO with the nixblitz TUI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `nix build .#installer-iso` (and `just iso-build`) produces a bootable x86_64 ISO that boots a minimal live NixOS, auto-launches the nixblitz TUI, and lets the operator install the node to disk via the existing `disko-install --flake ~/nixblitz#nixblitz-installer` flow.

**Architecture:** A dev/release artifact in the **top-level flake** (not `templates/`). A new pure-function module `nix/iso.nix` builds a `nixpkgs.lib.nixosSystem` from nixpkgs' `installation-cd-minimal` profile + a small inline module (the wrapped TUI package, an auto-launch snippet, passwordless sudo). The flake exposes `packages.x86_64-linux.installer-iso`; `just` wires building + booting it.

**Tech Stack:** Nix (flakes, NixOS `installation-cd` profile), `just` + `nushell` recipes, QEMU.

## Global Constraints

- **Top-level flake only.** Do NOT add anything to `templates/flake.nix` or `templates/`. The ISO is build-only and must not ship to nodes. (Avoids a circular flake input — templates already takes the TUI flake as its `nixblitz` input.)
- **No new flake inputs.** Use the native `installation-cd-minimal.nix` profile from the existing `nixpkgs` input.
- **x86_64-linux only.** The output is gated under `lib.optionalAttrs (system == "x86_64-linux")`.
- **Phase 1 = source-baked, build-uses-network.** The TUI carries the flake (embedded templates) and scaffolds `~/nixblitz` at runtime; `disko-install` evaluates/builds over the network, same as today. A commented phase-2 hook (offline closure pre-seed) is left in `nix/iso.nix`; do not implement it.
- **`nix/iso.nix` is a pure function** taking `{ nixpkgs, nixblitzPackage }` — it must NOT reference `self` or reach into `templates/`.
- Nix formatting: **alejandra** (`nix run nixpkgs#alejandra -- <files>`), matching the repo.

**Spec:** `docs/superpowers/specs/2026-06-18-x86-installer-iso-design.md`

**VCS note:** Commits are the user's (jj). Treat each task's commit step as a "green checkpoint" — do not run `jj commit`/`git commit` yourself unless the user asks; leave a ready-to-paste message.

---

## File Structure

- **Create `nix/iso.nix`** — pure function `{ nixpkgs, nixblitzPackage }: nixpkgs.lib.nixosSystem {...}` returning a live-medium NixOS config whose `.config.system.build.isoImage` is the ISO. One responsibility: define the installer live medium.
- **Modify `flake.nix`** — add `installer-iso` to the x86-only `packages` set, calling `nix/iso.nix` with `nixblitzWrapped`.
- **Modify `justfile`** — add `iso-build`; repoint `vm-boot` at the built ISO.

---

### Task 1: `nix/iso.nix` — the live-medium ISO config

**Files:**
- Create: `nix/iso.nix`

**Interfaces:**
- Consumes: the top-level flake's `nixpkgs` input; the wrapped TUI package `nixblitzWrapped` (a derivation with `disko` + `git` on PATH, `/bin/nixblitz`).
- Produces: a function `{ nixpkgs, nixblitzPackage }` → a NixOS system whose `.config.system.build.isoImage` is the bootable ISO. Consumed by `flake.nix` in Task 2.

- [ ] **Step 1: Write the file**

Create `nix/iso.nix`:

```nix
# Buildable x86_64 installer ISO carrying the nixblitz TUI.
#
# A dev/release artifact (built on a dev machine / CI), NOT shipped to
# nodes — hence it lives in the top-level flake, not templates/. It is a
# minimal NixOS live medium that auto-launches the TUI; the operator then
# runs the install wizard, which scaffolds ~/nixblitz from the TUI's
# embedded templates and calls `disko-install --flake ~/nixblitz#nixblitz-installer`.
#
# Pure function: takes nixpkgs + the (wrapped) TUI package so it never
# reaches into templates/ or `self`.
{
  nixpkgs,
  nixblitzPackage,
}:
nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    (
      {
        modulesPath,
        lib,
        ...
      }: {
        imports = [
          "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
        ];

        # The wrapped TUI (disko + git already on PATH). The operator runs
        # the install wizard from here; it scaffolds ~/nixblitz from the
        # embedded templates and calls disko-install against
        # nixblitz-installer.
        environment.systemPackages = [nixblitzPackage];

        # The install wizard runs disko-install / mount /
        # nixos-generate-config non-interactively via `sudo -n`. The live
        # medium is ephemeral, so passwordless sudo is the right default
        # here (mirrors templates/hosts/installer.nix's rationale).
        security.sudo.wheelNeedsPassword = false;

        # Auto-launch the TUI on the live console's interactive shell. The
        # installation-cd profile auto-logs into a bash shell on tty1; this
        # fires there. Guard skips non-interactive / already-launched
        # shells so `ssh host <cmd>` and nested shells don't recurse.
        # (Kept as a small dedicated copy of the snippet in
        # templates/modules/system/base.nix so this dev artifact stays
        # decoupled from templates/.)
        programs.bash.interactiveShellInit = ''
          if [ -z "''${NIXBLITZ_AUTOLAUNCHED:-}" ] && [ -t 0 ] && [ -t 1 ] \
              && command -v nixblitz >/dev/null 2>&1; then
            export NIXBLITZ_AUTOLAUNCHED=1
            nixblitz
          fi
        '';

        # Stable, recognizable artifact name (overrides the profile default).
        isoImage.isoName = lib.mkForce "nixblitz-installer-x86_64.iso";

        # ── Phase-2 hook (offline install) — intentionally inert ─────────
        # To make disko-install work with NO network, pre-seed the installer
        # system closure into the live store, e.g.:
        #   isoImage.storeContents = [ <templates#nixblitz-installer toplevel> ];
        #   isoImage.includeSystemBuildDependencies = true;
        # Left out in phase 1 (build uses network, same as today). Adding it
        # crosses into the templates flake — see the spec's phase-2 note.
      }
    )
  ];
}
```

- [ ] **Step 2: Format**

Run: `nix run nixpkgs#alejandra -- nix/iso.nix`
Expected: "Congratulations! Your code complies with the Alejandra style." (or it reformats in place — fine).

- [ ] **Step 3: Verify it evaluates as a NixOS system**

Run (uses the system nixpkgs as a stand-in for the input so this task can be checked in isolation, with a dummy package — the real wiring is Task 2):

```bash
nix eval --impure --raw --expr '
  let
    nixpkgs = builtins.getFlake "github:nixOS/nixpkgs/nixos-25.11";
    pkgs = import <nixpkgs> {};
    iso = import ./nix/iso.nix {
      inherit nixpkgs;
      nixblitzPackage = pkgs.hello;  # any derivation; real one wired in Task 2
    };
  in iso.config.system.build.isoImage.name
'
```
Expected: prints a derivation name containing `nixos` / `iso` (proves the module set evaluates and `isoImage` is wired). If it errors on a network fetch of nixpkgs, that's environmental — note it and proceed; Task 2's `nix build` is the real gate.

- [ ] **Step 4: Commit**

```bash
git add nix/iso.nix
git commit -m "feat(iso): live-medium installer ISO config carrying the TUI"
```

---

### Task 2: Expose `installer-iso` in the flake

**Files:**
- Modify: `flake.nix` (the `packages = { ... };` block, currently lines 100-105)

**Interfaces:**
- Consumes: `nix/iso.nix`'s function (Task 1); `nixpkgs` (flake input, in scope in `outputs`); `nixblitzWrapped` (in scope in the `let` of `eachDefaultSystem`); `lib = nixpkgs.lib` (in scope, defined at flake.nix:46).
- Produces: `packages.x86_64-linux.installer-iso` — the ISO derivation (`.config.system.build.isoImage`). Consumed by `just iso-build` / `vm-boot` in Task 3.

- [ ] **Step 1: Edit the packages block**

In `flake.nix`, replace this exact block:

```nix
        packages = {
          default = self.packages.${system}.nixblitz;
          nixblitz = nixblitzWrapped;
          nixblitz-unwrapped = nixblitzUnwrapped;
          website = nixblitzWebsite;
        };
```

with:

```nix
        packages =
          {
            default = self.packages.${system}.nixblitz;
            nixblitz = nixblitzWrapped;
            nixblitz-unwrapped = nixblitzUnwrapped;
            website = nixblitzWebsite;
          }
          # x86 installer ISO — a dev/release artifact (see nix/iso.nix).
          # Gated to x86_64-linux: it's an x86 live medium and references
          # the x86 wrapped TUI.
          // lib.optionalAttrs (system == "x86_64-linux") {
            installer-iso =
              (import ./nix/iso.nix {
                inherit nixpkgs;
                nixblitzPackage = nixblitzWrapped;
              })
              .config
              .system
              .build
              .isoImage;
          };
```

- [ ] **Step 2: Format**

Run: `nix run nixpkgs#alejandra -- flake.nix`
Expected: complies (or reformats in place).

- [ ] **Step 3: Verify the output is visible + evaluates**

Run: `nix eval .#packages.x86_64-linux.installer-iso.drvPath`
Expected: prints a `/nix/store/...-nixblitz-installer-x86_64.iso....drv` path (proves the flake output wires through to a buildable derivation). No network build yet — just evaluation.

- [ ] **Step 4: Build the ISO (the real gate)**

Run: `nix build .#installer-iso --print-out-paths`
Expected: succeeds; prints a store path; `ls result/iso/` shows `nixblitz-installer-x86_64.iso`. (This is a full ISO build — minutes, network. If the environment can't build, note it and rely on Step 3's eval; the user runs the build.)

- [ ] **Step 5: Commit**

```bash
git add flake.nix
git commit -m "feat(iso): expose packages.installer-iso (x86_64-linux)"
```

---

### Task 3: `just iso-build` + repoint `vm-boot`

**Files:**
- Modify: `justfile` (add `iso-build`; edit `vm-boot`, currently lines 167-193)

**Interfaces:**
- Consumes: `packages.x86_64-linux.installer-iso` (Task 2). The built ISO lands at `result/iso/nixblitz-installer-x86_64.iso` after `nix build .#installer-iso`.
- Produces: `just iso-build` (build recipe) and an updated `just vm-boot` that boots the built ISO.

- [ ] **Step 1: Add the `iso-build` recipe**

In `justfile`, immediately ABOVE the `# Boot a NixOS ISO in QEMU for testing the installer` comment (line 167), insert:

```just
# Build the x86_64 installer ISO (carries the nixblitz TUI)
iso-build:
  #!/usr/bin/env nu
  nix build .#installer-iso
  let iso = (ls result/iso/*.iso | get name | first)
  print $"ISO built: ($iso)"
```

- [ ] **Step 2: Repoint `vm-boot` at the built ISO**

In `justfile`, replace this exact block (lines 167-176):

```just
# Boot a NixOS ISO in QEMU for testing the installer
vm-boot:
  #!/usr/bin/env nu
  # let iso = "/home/f44/Downloads/nixos-graphical-25.11.6561.1267bb4920d0-x86_64-linux.iso"
  let iso = "/home/f44/Downloads/nixos-minimal-25.11.9418.c7f47036d3df-x86_64-linux.iso"

  if not ($iso | path exists) {
    print $"ISO not found at ($iso)"
    exit 1
  }
```

with:

```just
# Boot the nixblitz installer ISO in QEMU for testing the installer
vm-boot:
  #!/usr/bin/env nu
  # Build the nixblitz installer ISO if it isn't present, then boot it.
  # (Cheap when the store is warm.) Was previously a hand-downloaded
  # stock nixos-minimal ISO; now we boot our own TUI-carrying image.
  if not ('result/iso' | path exists) {
    print "Building installer ISO (just iso-build)..."
    nix build .#installer-iso
  }
  let iso = (ls result/iso/*.iso | get name | first)

  if not ($iso | path exists) {
    print $"ISO not found at ($iso) — run 'just iso-build'"
    exit 1
  }
```

(The rest of `vm-boot` — the qcow2 creation, the `qemu-system-x86_64 ... -cdrom $iso` invocation — is unchanged; `$iso` is now the built path.)

- [ ] **Step 3: Verify the recipes parse**

Run: `just --list | grep -E 'iso-build|vm-boot'`
Expected: both recipes listed with their doc comments (`just` parses the file without error).

- [ ] **Step 4: Build via the recipe**

Run: `just iso-build`
Expected: builds and prints `ISO built: result/iso/nixblitz-installer-x86_64.iso`. (Full build — minutes/network; if unavailable, Step 3 proves the recipe is well-formed and the user runs it.)

- [ ] **Step 5: Commit**

```bash
git add justfile
git commit -m "build(iso): add just iso-build; boot the built ISO in vm-boot"
```

---

## Final verification

- [ ] `nix eval .#packages.x86_64-linux.installer-iso.drvPath` resolves (Task 2 wiring).
- [ ] `nix build .#installer-iso` produces `result/iso/nixblitz-installer-x86_64.iso`.
- [ ] **Boot smoke (manual/VM, the acceptance test):** `just iso-build` → `just vm-boot` → the ISO boots, the TUI **auto-launches** on the live console, and the install wizard can run `disko-install` against the blank `nixblitz-disk.qcow2` (the existing VM install path). `just vm-ssh-installer` still works (the installation-cd profile keeps the `nixos` SSH user).
- [ ] Confirm `templates/` is untouched (`git status` shows only `nix/iso.nix`, `flake.nix`, `justfile`).

## Self-review notes (author)

- **Spec coverage:** §A ISO config = Task 1 (`nix/iso.nix`, installation-cd profile + TUI + auto-launch + passwordless sudo + phase-2 hook); §B flake output = Task 2 (`installer-iso`, x86-gated, pure-function call); §C tooling = Task 3 (`iso-build` + `vm-boot`). Testing = per-task eval/build + the final boot smoke.
- **Decisions honored:** top-level flake (not templates) ✓; native profile, no new input ✓; dedicated auto-launch copy ✓; phase-2 hook inert/marked ✓; `nix/iso.nix` pure (`{nixpkgs, nixblitzPackage}`, no `self`) ✓.
- **Name consistency:** `installer-iso`, `nix/iso.nix`, `nixblitzPackage`/`nixblitzWrapped`, `nixblitz-installer-x86_64.iso`, `result/iso/` used consistently across tasks.
- **Known env caveat:** full ISO builds need network + time; each build step has an eval-only fallback so the structure is verifiable even where a build can't run, with the user running the real build.
