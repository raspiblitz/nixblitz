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
{
  self,
  nixpkgs,
  disko,
  system ? "x86_64-linux",
}: let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;
  installerConfig =
    (lib.importJSON ../tests/config/fixtures/base/config.json)
    // {initialized = false;};

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

  # Assemble the sibling files installer.nix/installed.nix read at eval time.
  profile = pkgs.runCommand "nixblitz-installer-profile" {} ''
    mkdir -p $out/hosts
    cp ${../templates/hosts/installed.nix} $out/hosts/installed.nix
    cp ${../templates/hosts/installer.nix} $out/hosts/installer.nix
    cp ${pkgs.writeText "config.json" (builtins.toJSON installerConfig)} $out/config.json
    cp ${../tests/config/fixtures/base/hardware-configuration.nix} $out/hardware-configuration.nix
  '';

  installerSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {nixblitz = self;};
    modules =
      (findModules ../templates/modules)
      ++ [
        (profile + "/hosts/installer.nix")
        disko.nixosModules.default
      ];
  };
in
  installerSystem.config.system.build.toplevel
