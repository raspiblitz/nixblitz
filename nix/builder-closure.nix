# The per-machine delta-rebuild BUILDER closure — the second half of the
# offline-installer keystone (nix/offline-inputs.nix is the first).
#
# ## Why this exists (the L4b hole)
# The offline ISO bakes the installer system's `toplevel` OUTPUT, i.e. its
# RUNTIME closure. But a real operator's machine writes its OWN
# hardware-configuration.nix (real kernel modules, swap, fileSystems) and picks
# its OWN disk device, so at `disko-install` time a batch of derivations
# re-evaluate and REBUILD locally: etc/fstab, grub-config + install-grub,
# initrd, closure-info, system-units, stage-1/2 init, boot.json, nixos.conf,
# the os-release-ish text drvs, and the toplevel itself.
#
# Rebuilding ANY of those — even a 1 KB writeText — requires its BUILDER's
# outputs: the stdenv setup script + bash + coreutils + gnused/grep/find, the
# perl buildEnv that setup-etc / closure-info / update-users-groups run under,
# and the makeInitrd tooling (extra-utils, make-initrd.sh, modules-closure.sh,
# busybox, kmod). These are build-time-only; they appear in NO runtime closure
# and are never part of the baked `toplevel`. Without them, nix falls back to
# rebuilding stdenv from bootstrap sources and dies fetching a toolchain
# offline — the 617-drv cascade this whole mechanism exists to prevent.
#
# ## The mechanism: `.inputDerivation`
# `drv.inputDerivation` is a stdenv-provided derivation whose RUNTIME closure
# equals `drv`'s full BUILD-INPUT closure. Baking the inputDerivations of the
# per-machine rebuild products therefore bakes exactly the builders those
# products need — and it is NIX-COMPUTED, so it tracks nixpkgs bumps and module
# changes automatically instead of rotting like a hand-pinned store-path list.
#
# The product list below is measured, not guessed. Procedure (x86 fixture):
#   1. Scaffold two fixture flakes (base + a delta with a different
#      disk_device AND a realistic hardware-configuration.nix — extra
#      availableKernelModules + a swapDevice).
#   2. delta-drv set  = `nix-store -q --requisites` of the delta toplevel .drv
#      minus the base's.
#   3. build-needs    = each delta drv's direct inputDrvs' OUTPUTS + inputSrcs.
#   4. builder set    = build-needs minus (baked toplevel-output closure ∪
#      disko-script closure ∪ offline source paths).
#   5. Confirm `inputDerivation` of the products below has a runtime closure
#      that ⊇ that builder set.
# On the last measurement this covered 104/104 builder paths (the lone
# straggler, jq's `dev` output pulled by the boot.json builder, is added
# explicitly). Incremental ISO growth ≈ 40 MB (squashfs dedups the rest against
# the live system's own closure). The offline-VM install acceptance test is the
# ultimate guard: if a nixpkgs bump moves a builder out of this set, that test
# fails loudly.
#
# Hardware-specific LEAF packages (Intel microcode, out-of-tree module
# packages, a from-source kernel) are deliberately OUT of scope — those are the
# accepted substitute-or-miss class, and baking the full C-compiler toolchain
# to rebuild them offline would balloon the image for no realistic benefit.
{
  pkgs,
  # `config.system.build` of the installer nixosSystem.
  sysBuild,
}: let
  # Products a per-machine install always rebuilds and that expose a clean
  # accessor. `x or null` keeps this robust across the x86 and Pi 5 systems
  # (e.g. a systemd-initrd variant may not expose every attr) — missing ones
  # are filtered out rather than throwing.
  #
  # `config.system.build.units` is NOT here: it's an attrset of the individual
  # unit derivations (no `.inputDerivation`), not the aggregated `system-units`
  # derivation, which has no clean accessor. Its extra builders (jq's `dev`
  # output, lndir) are baked explicitly below instead; the one disabled-unit
  # text drv it also pulls rebuilds trivially from the stdenv that the products
  # here already bake.
  rebuildProducts =
    builtins.filter (p: p != null)
    [
      sysBuild.toplevel # the system derivation itself
      (sysBuild.etc or null) # /etc tree (fstab, os-release, …)
      (sysBuild.initialRamdisk or null) # initrd (makeInitrd tooling)
      (sysBuild.bootStage1 or null) # stage-1-init.sh
      (sysBuild.bootStage2 or null) # stage-2-init.sh
      (sysBuild.modulesClosure or null) # shrunk initrd modules (kmod)
    ];
in
  (map (p: p.inputDerivation) rebuildProducts)
  # Measured stragglers not reachable through any product's `.inputDerivation`:
  #   - jq `dev`: build input of the boot.json builder.
  #   - lndir: link-units (the system-units builder) shells out to it.
  # Both are compiled packages, so unlike the text/script builders they can't
  # be reconstructed from stdenv alone — bake them directly.
  ++ [pkgs.jq.dev pkgs.xorg.lndir]
