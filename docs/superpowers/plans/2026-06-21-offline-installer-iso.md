# Self-contained offline installer ISO — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake the minimal install closure into the installer ISO so `disko-install` on the booted medium runs fully offline (no cache.nixos.org, no attic), and remove the attic-from-install machinery.

**Architecture:** A repurposed closure builder (`nix/installer-system.nix`) produces the minimal (`initialized = false`) installer toplevel via the `tests/config` fixture store-profile; `flake.nix` threads its closure into `nix/iso.nix`, which bakes it with `isoImage.storeContents`. The live-ISO attic substituter, the `installer-seed` flake output, the `iso-cache-push` recipe, and the attic spec are removed.

**Tech Stack:** Nix (flakes, NixOS `installation-cd` / iso-image), `just`/nushell.

## Global Constraints

- **x86_64-linux only** (the ISO + closure are x86; outputs stay under `lib.optionalAttrs (system == "x86_64-linux")`).
- **No new flake inputs.**
- **Keep** `templates/modules/system/base.nix`'s attic substituter and the `templates/flake.nix` nixConfig removal (`f065a6f3`) — both unrelated to the install-path attic work being dropped here.
- **Representative closure accepted:** the bake uses the committed fixture hardware-config + `initialized = false`; the real per-machine toplevel builds locally at install (leaves baked). A forced _leaf rebuild_ is an accepted offline-miss.
- Nix formatting: **alejandra** (`nix run nixpkgs#alejandra -- <files>`).
- New `.nix` files must be `git add`ed before a flake build/eval sees them (the repo's established pattern — nix reads the git tree).

**Spec:** `docs/superpowers/specs/2026-06-21-offline-installer-iso-design.md`

**VCS note:** Commits are the user's (jj). Treat each task's commit step as a "green checkpoint" — leave a ready-to-paste message; don't run `jj commit` unless asked.

---

## File Structure

- **Rename** `nix/installer-seed.nix` → `nix/installer-system.nix`; change the fixture config to `initialized = false`. Returns the minimal installer toplevel.
- **Modify** `nix/iso.nix`: drop the attic `nix.settings` block; add `installerClosure` arg + `isoImage.storeContents = [installerClosure]`; replace the inert phase-2-hook comment with a "this is now active" note.
- **Modify** `flake.nix`: pass `installerClosure` into `iso.nix`; remove the `installer-seed` package output.
- **Modify** `justfile`: remove the `iso-cache-push` recipe.
- **Delete** `docs/superpowers/specs/2026-06-18-installer-iso-attic-cache-design.md`.

---

### Task 1: Repurpose the closure builder → minimal (`initialized = false`) installer system

**Files:**

- Rename: `nix/installer-seed.nix` → `nix/installer-system.nix`
- Modify: the renamed file (config override + comments)

**Interfaces:**

- Consumes: `{ self, nixpkgs, disko, system ? "x86_64-linux" }` (unchanged signature); the committed fixtures `tests/config/fixtures/base/config.json` + `…/hardware-configuration.nix`.
- Produces: the installer system's `config.system.build.toplevel` (a derivation), now built from an `initialized = false` config. Consumed by `flake.nix` in Task 2.

- [ ] **Step 1: Rename the file**

```bash
git mv nix/installer-seed.nix nix/installer-system.nix
```

(If `git mv` complains in the jj-colocated repo, use `mv nix/installer-seed.nix nix/installer-system.nix` then `git add -A nix/`.)

- [ ] **Step 2: Override the fixture config to `initialized = false` + refresh the header comment**

In `nix/installer-system.nix`, replace the top-of-file doc comment's first paragraph (the one describing it as a cache "seed") with an offline-bake description, and change the `profile`'s `config.json` line so it writes an `initialized = false` config instead of copying the fixture verbatim.

Replace the file's leading comment block (everything from the first `#` line down to the line immediately before `{` — currently the "Buildable handle … seed the attic cache" block) with:

```nix
# The minimal installer-system toplevel closure, baked into the installer ISO
# (nix/iso.nix `isoImage.storeContents`) so disko-install runs offline — every
# leaf package it needs is already in the live medium's /nix/store.
#
# `nixblitz-installer` reads `../config.json` and imports
# `../hardware-configuration.nix`, both generated per-machine at install and
# absent from source. We reuse the committed test fixtures + the same
# store-`profile` trick `tests/config/default.nix` uses so those sibling reads
# resolve, but force `initialized = false` — the bootstrap-gate state
# disko-install actually builds (all services off), which is exactly the
# closure the install needs and keeps the bake small.
#
# Representative, not byte-exact: the real install uses the operator's hardware
# config, so the final per-machine system derivation builds locally at install
# time — offline, because its leaves are baked. A forced leaf rebuild (e.g. a
# kernel rebuild) is an accepted offline-miss.
#
# `findModules` is duplicated (not imported from templates' flake) for the same
# reason tests/config duplicates it: to keep the root flake's lock free of
# templates' closure.
```

Then, in the `let` body, add an `installerConfig` binding and use it in the
profile. Change the existing `pkgs`/`lib` area to include:

```nix
  installerConfig =
    (lib.importJSON ../tests/config/fixtures/base/config.json)
    // {initialized = false;};
```

and replace the profile's config.json copy line:

```nix
    cp ${../tests/config/fixtures/base/config.json} $out/config.json
```

with:

```nix
    cp ${pkgs.writeText "config.json" (builtins.toJSON installerConfig)} $out/config.json
```

Leave the `hardware-configuration.nix` copy, `findModules`, `installerSystem`, and the final `installerSystem.config.system.build.toplevel` return unchanged. Also rename the `runCommand` derivation name from `"nixblitz-seed-profile"` to `"nixblitz-installer-profile"` (cosmetic, matches the new purpose).

- [ ] **Step 3: Format + stage**

```bash
nix run nixpkgs#alejandra -- nix/installer-system.nix
git add nix/installer-system.nix
```

Expected: alejandra reports compliance (or reformats).

- [ ] **Step 4: Verify it evaluates to a toplevel with initialized=false**

Run (the file's only consumer wiring comes in Task 2; eval it standalone):

```bash
nix eval --impure --raw --expr '
  let
    self = builtins.getFlake (toString ./.);
    nixpkgs = self.inputs.nixpkgs;
    disko = self.inputs.disko;
  in (import ./nix/installer-system.nix {
    inherit self nixpkgs disko;
    system = "x86_64-linux";
  }).drvPath
'
```

Expected: prints a `/nix/store/…-nixos-system-nixblitz-….drv` path (proves the profile + nixosSystem evaluate). If it errors that `self`/inputs can't resolve this way, fall back to the Task-2 build as the gate and note it.

- [ ] **Step 5: Commit (checkpoint)**

```bash
git add -A nix/
# message: refactor(iso): installer-system closure (initialized=false) for offline bake
```

---

### Task 2: Bake the closure into the ISO; drop the attic substituter + seed output

**Files:**

- Modify: `nix/iso.nix`
- Modify: `flake.nix`

**Interfaces:**

- Consumes: `nix/installer-system.nix`'s toplevel (Task 1); `nixpkgs`, `nixblitzWrapped`, `self`, `disko`, `system`, `lib` (all in `flake.nix` scope).
- Produces: `packages.x86_64-linux.installer-iso` — an ISO whose store contains the installer closure. `installer-seed` output is gone.

- [ ] **Step 1: `nix/iso.nix` — add the `installerClosure` arg**

Change the argument set (currently `{ nixpkgs, nixblitzPackage }`) to:

```nix
{
  nixpkgs,
  nixblitzPackage,
  installerClosure,
}:
```

- [ ] **Step 2: `nix/iso.nix` — remove the attic substituter block**

Delete this entire block (the comment + both `nix.settings.*` assignments):

```nix
        # Pull the node closure from our attic cache during the operator's
        # disko-install, instead of hammering cache.nixos.org. Set via
        # `nix.settings` (system nix.conf — always trusted) rather than a
        # flake `nixConfig`, which nix silently ignores. Same substituter +
        # key the installed system uses (base.nix); seed it with
        # `just iso-cache-push`.
        nix.settings.extra-substituters = [
          "https://attic.f44.fyi/nixblitz"
        ];
        nix.settings.extra-trusted-public-keys = [
          "nixblitz:u7XgfZdWeXp1ilOIlzKzQbxWZZg9r2rVU0VBaffHtbw="
        ];
```

- [ ] **Step 3: `nix/iso.nix` — replace the inert phase-2 hook with the active bake**

Replace this block:

```nix
        # ── Phase-2 hook (offline install) — intentionally inert ─────────
        # To make disko-install work with NO network, pre-seed the installer
        # system closure into the live store, e.g.:
        #   isoImage.storeContents = [ <templates#nixblitz-installer toplevel> ];
        #   isoImage.includeSystemBuildDependencies = true;
        # Left out in phase 1 (build uses network, same as today). Adding it
        # crosses into the templates flake — see the spec's phase-2 note.
```

with:

```nix
        # Bake the minimal installer-system closure into the live store so
        # disko-install runs fully offline — every leaf package it needs is
        # already present, no substituter required. squashfs dedups these
        # against the live system's own closure, so the ISO grows only by the
        # non-overlapping installed paths. The closure is built by
        # nix/installer-system.nix and threaded in from flake.nix.
        isoImage.storeContents = [installerClosure];
```

(`includeSystemBuildDependencies` is intentionally NOT set — we bake prebuilt
leaves, not build-from-source inputs; the per-machine final derivation composes
them locally without compilation.)

- [ ] **Step 4: `flake.nix` — thread the closure in + remove `installer-seed`**

Replace this block (currently lines ~110-126):

```nix
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

            # Representative installer-system closure, for seeding the attic
            # cache via `just iso-cache-push` (see nix/installer-seed.nix).
            installer-seed = import ./nix/installer-seed.nix {
              inherit self nixpkgs disko system;
            };
          };
```

with:

```nix
          // lib.optionalAttrs (system == "x86_64-linux") {
            installer-iso =
              (import ./nix/iso.nix {
                inherit nixpkgs;
                nixblitzPackage = nixblitzWrapped;
                # Minimal installer-system closure, baked into the ISO store
                # so disko-install runs offline (see nix/installer-system.nix).
                installerClosure = import ./nix/installer-system.nix {
                  inherit self nixpkgs disko system;
                };
              })
              .config
              .system
              .build
              .isoImage;
          };
```

- [ ] **Step 5: Format + stage**

```bash
nix run nixpkgs#alejandra -- nix/iso.nix flake.nix
git add nix/iso.nix flake.nix
```

- [ ] **Step 6: Verify — output wires + no attic on the ISO**

```bash
# Output evaluates to a derivation:
nix eval .#packages.x86_64-linux.installer-iso.drvPath
# No attic substituter baked into the live config:
grep -n "extra-substituters\|attic" nix/iso.nix || echo "no attic in iso.nix (good)"
# installer-seed output is gone:
nix eval .#packages.x86_64-linux.installer-seed.drvPath 2>&1 | grep -qi "error\|does not" && echo "installer-seed removed (good)"
```

Expected: `installer-iso` drvPath prints; no attic match in iso.nix; `installer-seed` no longer exists.

- [ ] **Step 7: Build the ISO (the real gate)**

```bash
nix build .#installer-iso --print-out-paths
ls -la result/iso/
```

Expected: succeeds; `result/iso/nixblitz-installer.iso` exists and is **noticeably larger** than the pre-bake ~1.4 GB (the installer closure is now inside). This build realizes the installer-system closure — minutes; if the env can't build, Step 6's eval is the fallback and the user runs the build.

- [ ] **Step 8: Commit (checkpoint)**

```bash
git add -A nix/iso.nix flake.nix
# message: feat(iso): bake the install closure into the ISO (offline disko-install); drop attic substituter + seed output
```

---

### Task 3: Remove `iso-cache-push`; delete the attic spec

**Files:**

- Modify: `justfile`
- Delete: `docs/superpowers/specs/2026-06-18-installer-iso-attic-cache-design.md`

**Interfaces:**

- Consumes: nothing.
- Produces: a `justfile` with no attic recipe; `iso-build` + `vm-boot` unchanged.

- [ ] **Step 1: Remove the `iso-cache-push` recipe**

In `justfile`, delete the whole recipe — from its doc comment line
`# Seed the attic cache from local (installer ISO + representative node closure)`
through the recipe's final `print` line (the block ending with
`print "Done. Attic seeded with ISO + representative install closure."`), plus
the trailing blank line. Leave `iso-build` (above it) and `vm-boot` (below it)
intact.

- [ ] **Step 2: Verify the justfile still parses + the recipe is gone**

```bash
just --list 2>&1 | grep -E "iso-build|vm-boot|iso-cache-push"
```

Expected: `iso-build` and `vm-boot` listed; **no** `iso-cache-push`.

- [ ] **Step 3: Delete the attic spec**

```bash
git rm docs/superpowers/specs/2026-06-18-installer-iso-attic-cache-design.md
```

(or `rm` + `git add -A docs/superpowers/specs/`.)

- [ ] **Step 4: Confirm no dangling references to removed names**

```bash
grep -rn "iso-cache-push\|installer-seed\|installer-iso-attic-cache" justfile flake.nix nix/ docs/superpowers/specs/2026-06-21-offline-installer-iso-design.md \
  | grep -v "2026-06-21-offline-installer-iso" || echo "no dangling refs (good)"
```

Expected: no matches (the new offline spec may mention the old spec name in its "Supersedes" line — that's fine).

- [ ] **Step 5: Commit (checkpoint)**

```bash
git add -A justfile docs/superpowers/specs/
# message: chore(iso): drop iso-cache-push recipe + attic-cache spec (offline ISO supersedes)
```

---

## Final verification

- [ ] `nix build .#installer-iso` → `result/iso/nixblitz-installer.iso`, larger than ~1.4 GB (closure baked in).
- [ ] `nix eval .#packages.x86_64-linux.installer-seed.drvPath` errors (output removed); `iso-cache-push` absent from `just --list`.
- [ ] `grep -rn "attic" nix/iso.nix` → nothing; `base.nix`'s attic substituter untouched (`grep -n attic templates/modules/system/base.nix` still present).
- [ ] **Offline-install acceptance (manual/VM):** `just iso-build` → `just vm-boot` with the VM **offline** (or cache.nixos.org blocked) → run the install → it completes pulling nothing from the network (closure served from the live store). A forced leaf rebuild is the accepted representative miss.

## Self-review notes (author)

- **Spec coverage:** §A builder (initialized=false) = Task 1; §B storeContents + drop attic substituter = Task 2; §B remove installer-seed output = Task 2; §C remove iso-cache-push = Task 3; §D delete attic spec = Task 3. Testing = per-task eval/build + final offline VM.
- **Decisions honored:** minimal (initialized=false) closure ✓; isoImage.storeContents ✓; representative accepted ✓; attic kept in base.nix + nixConfig fix untouched ✓; installer-seed output + iso-cache-push removed ✓.
- **Name consistency:** `nix/installer-system.nix`, `installerClosure`, `installerConfig`, `installer-iso`, `nixblitz-installer.iso` used consistently.
- **Env caveat:** the ISO build is heavy (realizes the installer closure); each build step has an eval fallback, with the real build + offline VM test left to the user.
