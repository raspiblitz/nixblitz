# Config channel verification — eval tier.
# See docs/superpowers/specs/2026-05-19-config-channel-verification-design.md
#
# Returns a `checks`-shaped attrset (one eval-gate per host ×
# channel) for the root flake to expose under checks.x86_64-linux.
{
  self,
  lib,
  nixpkgs,
  nixpkgs-vanilla-unstable,
  disko,
  system ? "x86_64-linux",
}: let
  pkgs = nixpkgs.legacyPackages.${system};

  excludedFiles = ["package.nix" "flake.nix"];

  # Same directory walk templates/flake.nix uses to collect its
  # module set. Duplicated (not imported as a flake input) to keep
  # the root flake's lock free of templates' closure
  # (nixos-raspberrypi + a remote nixblitz fetch).
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

  # installed.nix reads `../config.json` and imports
  # `../hardware-configuration.nix` (both generated at install,
  # absent from source). Merge the committed fixture onto a fresh
  # copy of the host modules so those sibling reads resolve. IFD:
  # this derivation builds before the config evaluates.
  profile = pkgs.runCommand "nixblitz-test-profile" {} ''
    mkdir -p $out/hosts
    cp ${../../templates/hosts/installed.nix} $out/hosts/installed.nix
    cp ${../../templates/hosts/installer.nix} $out/hosts/installer.nix
    cp ${./fixtures/base/config.json} $out/config.json
    cp ${./fixtures/base/hardware-configuration.nix} $out/hardware-configuration.nix
  '';

  # Layer 1 — build a node config for a channel + host.
  mkNodeConfig = {
    channelFlake,
    hostName,
  }:
    channelFlake.lib.nixosSystem {
      inherit system;
      specialArgs = {nixblitz = self;};
      modules =
        (findModules ../../templates/modules)
        ++ [
          (profile + "/hosts/${hostName}.nix")
          disko.nixosModules.default
        ];
    };

  # Layer 2 — matrix (channels × hosts), defined once.
  channels = {
    stable = nixpkgs;
    unstable = nixpkgs-vanilla-unstable;
  };
  hostNames = ["installed" "installer"];

  matrix = lib.listToAttrs (
    lib.concatMap (
      hostName:
        map (channelName: {
          name = "${hostName}-${channelName}";
          value = mkNodeConfig {
            channelFlake = channels.${channelName};
            inherit hostName;
          };
        }) (lib.attrNames channels)
    )
    hostNames
  );

  # Layer 3 — eval-gate tier applier. Referencing .drvPath forces
  # full module evaluation without realizing the system; an eval
  # error (renamed option / removed package) means this runCommand
  # can't be produced and `nix flake check` fails.
  #
  # Future tiers slot in here additively: a buildGate returning
  # `cfg.config.system.build.toplevel`, a bootGate returning
  # `pkgs.nixosTest {...}`, each mapped over the SAME `matrix`.
  evalGate = name: cfg:
    pkgs.runCommand "config-eval-${name}" {} ''
      echo ${cfg.config.system.build.toplevel.drvPath} > $out
    '';
in
  lib.mapAttrs' (
    name: cfg: lib.nameValuePair "config-${name}" (evalGate name cfg)
  )
  matrix
