# Faithful in-tree replication of disko's `share/disko/lib/install-cli.nix`
# (at templates' locked disko rev) — the eval that
# `disko-install --flake ~/nixblitz#<attr>` performs on the live medium.
#
# ## Why this exists (the last offline-install hole)
# disko-install does NOT build the flake's plain
# `config.system.build.{toplevel,diskoScript}`. It calls install-cli.nix,
# which applies `extendModules` to the flake's nixosConfiguration TWICE and
# then builds `-A installToplevel -A closureInfo -A diskoScript`:
#
#   - diskoSystem = originalSystem.extendModules {
#       disko.rootMountPoint = "/mnt/disko-install-root";   # not the "/mnt" default
#       disko.devices.disk   = mkVMOverride <disks with device rewritten to
#                                            the operator's --disk mapping>;
#     } → formatScript / mountScript / diskoScript
#   - installSystem = originalSystem.extendModules {
#       boot.loader.efi.canTouchEfiVariables = mkVMOverride false;
#       boot.loader.grub.devices             = mkVMOverride [<mapping devices>];
#     } → toplevel + closureInfo
#
# Those products differ from the plain ones by construction (rootMountPoint,
# the disk-device rewrite, the grub/efi overrides), so the earlier bake — which
# baked the PLAIN diskoScript/toplevel — never covered the drvs disko-install
# actually realizes. Building the real diskoScript pulls make-binary-wrapper-hook
# + gcc-wrapper (makeBinaryWrapper compiles a C shim) + shellcheck, none of
# which were baked → bootstrap-tools FOD → offline death. Baking THESE products
# (and their `.inputDerivation`s, via nix/builder-closure.nix) closes that hole:
# a fixture-path install builds zero drvs, and a real machine's delta variant
# rebuilds offline with full builder coverage.
#
# ## Fidelity
# Semantics are copied verbatim from install-cli.nix @ the locked rev
# (nix/offline-inputs.nix `sourcePaths` → the disko `source` store path). The
# defaults below are disko-install's own script defaults:
#   - rootMountPoint = "/mnt/disko-install-root" — the script's `mountPoint`,
#     passed through `realpath`; it has no symlink components, so unchanged.
#   - writeEfiBootEntries = false — the script default (no `--write-efi-boot-entries`).
#   - extraSystemConfig = "{}" — the script default (no `--system-config`);
#     `builtins.fromJSON "{}"` → an empty module tagged with the `_file` marker
#     install-cli attaches, replicated so the module-eval (hence the toplevel /
#     closureInfo drvs) is byte-identical.
#   - diskMappings — the wizard's `--disk main <device>`; supplied by the caller
#     as the platform-default fixture device.
#
# Keeping this as one shared helper (imported by both nix/installer-system.nix
# and nix/pi5-installer-system.nix) means the x86 and Pi 5 bakes cannot drift
# from each other or from upstream install-cli.
{
  # The flake's nixosConfiguration — install-cli's `originalSystem`.
  originalSystem,
  # `{ <diskName> = "/dev/…"; }` — install-cli's `diskMappings`, i.e. the
  # operator's `--disk <name> <device>` arguments. Fixture value: the
  # platform-default install target.
  diskMappings,
}: let
  pkgs = originalSystem.pkgs;
  lib = pkgs.lib;

  deviceName = name:
    if diskMappings ? ${name}
    then diskMappings.${name}
    else throw "No device passed for disk '${name}'. Pass `--disk ${name} /dev/name` via commandline";

  modifiedDisks =
    builtins.mapAttrs (
      name: value: let
        dev = deviceName name;
      in
        value
        // {
          device = dev;
          content =
            value.content
            // {
              device = dev;
            };
        }
    )
    originalSystem.config.disko.devices.disk;

  # filter all nixos module internal attributes
  cleanedDisks = lib.filterAttrsRecursive (n: _: !lib.hasPrefix "_" n) modifiedDisks;

  diskoSystem = originalSystem.extendModules {
    modules = [
      {
        disko.rootMountPoint = "/mnt/disko-install-root";
        disko.devices.disk = lib.mkVMOverride cleanedDisks;
      }
    ];
  };

  installSystem = originalSystem.extendModules {
    modules = [
      (
        {lib, ...}: {
          boot.loader.efi.canTouchEfiVariables = lib.mkVMOverride false;
          boot.loader.grub.devices = lib.mkVMOverride (lib.attrValues diskMappings);
          imports = [
            ({_file = "disko-install --system-config";} // (builtins.fromJSON "{}"))
          ];
        }
      )
    ];
  };

  installToplevel = installSystem.config.system.build.toplevel;
in {
  inherit installToplevel;
  closureInfo = installSystem.pkgs.closureInfo {
    rootPaths = [installToplevel];
  };
  inherit (diskoSystem.config.system.build) formatScript mountScript diskoScript;

  # The diskoScript is a thin symlink (`ln -s <content-pkg>/bin/disko`); the
  # real script is a `writers.makeScriptWriter` "content" derivation that
  # `diskoScript` points at, and disko rebuilds it per-device (the disk-layout
  # text is embedded). That content build runs `makeBinaryWrapper` — which
  # compiles a C shim — so its build-only inputs are make-binary-wrapper-hook
  # + the C toolchain (gcc-wrapper, binutils, glibc). Those live in NO runtime
  # closure, and the content derivation is a LOCAL binding inside
  # makeScriptWriter (unreachable as an attr), so `diskoScript.inputDerivation`
  # can't carry them. Bake the hook explicitly instead: its own runtime closure
  # already includes the full cc/binutils/glibc it invokes, so a per-device
  # content rebuild links its shim offline. Sourced from the system's own
  # `pkgs` so the instance matches the one disko's `_scripts` uses. (Same
  # "compiled tool, can't be reconstructed from stdenv — bake it directly"
  # class as jq.dev / xorg.lndir in nix/builder-closure.nix.)
  diskoScriptToolchain = [pkgs.makeBinaryWrapper];
}
