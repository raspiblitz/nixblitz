# The minimal Pi 5 installer-system toplevel closure, baked into the Pi 5
# installer image (nix/pi5-image.nix `sdImage.storePaths`) so disko-install runs
# offline — every leaf package it needs is already in the image's /nix/store.
# The aarch64 analogue of nix/installer-system.nix.
#
# `nixblitz-pi5-installer` reads `../config.json` and imports
# `../hardware-configuration.nix`, both generated per-machine at install and
# absent from source. We reuse the committed test fixtures + the same store-
# `profile` trick nix/installer-system.nix uses so those sibling reads resolve,
# but force `initialized = false` (bootstrap gate: all services off — the state
# disko-install actually builds, which keeps the bake small) AND
# `system.platform = "pi5"` (selects the disko-pi5 layout + the Pi 5 host path).
# Built via nixos-raspberrypi.lib.nixosSystem so the vendor kernel / 16K
# overlays match the image.
#
# `findModules` is duplicated (not imported from templates' flake) for the same
# reason nix/installer-system.nix / tests/config duplicate it: keep the root
# flake's lock free of templates' closure.
{
  self,
  nixos-raspberrypi,
  disko,
}: let
  lib = nixos-raspberrypi.inputs.nixpkgs.lib;
  # rpi-overlaid aarch64 pkgs, only used to assemble the eval-time sibling files
  # via runCommand/writeText below.
  pkgs = nixos-raspberrypi.legacyPackages.aarch64-linux;

  base = lib.importJSON ../tests/config/fixtures/base/config.json;
  installerConfig =
    base
    // {
      initialized = false;
      system = base.system // {platform = "pi5";};
    };

  excludedFiles = ["package.nix" "flake.nix"];
  findModules = dir: let
    entries = builtins.readDir dir;
    processEntry = name: type: let
      path = dir + "/${name}";
    in
      if type == "directory"
      then findModules path
      else if
        type
        == "regular"
        && lib.hasSuffix ".nix" name
        && !builtins.elem name excludedFiles
      then [path]
      else [];
  in
    lib.concatLists (lib.mapAttrsToList processEntry entries);

  # Assemble the sibling files installer-pi5 → installed-pi5 → installed read at
  # eval time.
  profile = pkgs.runCommand "nixblitz-pi5-installer-profile" {} ''
    mkdir -p $out/hosts
    cp ${../templates/hosts/installed.nix} $out/hosts/installed.nix
    cp ${../templates/hosts/installed-pi5.nix} $out/hosts/installed-pi5.nix
    cp ${../templates/hosts/installer-pi5.nix} $out/hosts/installer-pi5.nix
    cp ${pkgs.writeText "config.json" (builtins.toJSON installerConfig)} $out/config.json
    cp ${../tests/config/fixtures/base/hardware-configuration.nix} $out/hardware-configuration.nix
  '';

  # nixosSystemRPi auto-injects specialArgs.nixos-raspberrypi (consumed by
  # installed-pi5.nix); we thread nixblitz = self for templates/modules.
  installerSystem = nixos-raspberrypi.lib.nixosSystem {
    specialArgs = {nixblitz = self;};
    modules =
      (findModules ../templates/modules)
      ++ [
        (profile + "/hosts/installer-pi5.nix")
        disko.nixosModules.default
      ];
  };
in
  installerSystem.config.system.build.toplevel
