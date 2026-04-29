{
  description = "NixBlitz node configuration";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-bitcoin = {
      url = "github:fort-nix/nix-bitcoin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixblitz = {
      url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
    };
    blitz-api = {
      url = "github:fusion44/blitz_api";
    };
    blitz-web = {
      # Tracks the branch with the nix packaging in place (pending PR
      # back to raspiblitz/raspiblitz-web). Once merged upstream this
      # can point at github:raspiblitz/raspiblitz-web directly.
      url = "github:fusion44/raspiblitz-web";
    };
    # Pi 5 isn't supported by upstream NixOS — vendor kernel + firmware
    # come from this third-party flake. Pinned to a tag so refreshes
    # are explicit; bump deliberately rather than tracking `main`.
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/v1.20260411.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    nix-bitcoin,
    nixblitz,
    blitz-api,
    blitz-web,
    nixos-raspberrypi,
  }: let
    inherit (nixpkgs) lib;

    excludedFiles = ["package.nix" "flake.nix"];

    findModules = dir: let
      entries = builtins.readDir dir;
      processEntry = name: type: let
        path = dir + "/${name}";
      in
        if type == "directory"
        then findModules path
        else if type == "regular" && lib.hasSuffix ".nix" name && !builtins.elem name excludedFiles
        then [path]
        else [];
    in
      lib.concatLists (lib.mapAttrsToList processEntry entries);

    # User-installed plugins (see docs/decisions/plugins.md D14).
    # Each plugin dir has its own plugin.nix (NixOS module) + config.json
    # (user-editable settings edited via the TUI Configure view).
    #
    # Plugin ABI: plugin.nix is a TWO-STAGE function:
    #   { pluginCfg ? {} }: { config, lib, pkgs, ... }: { … }
    # The outer stage receives the plugin's own config.json; the
    # inner is a standard NixOS module function. We deliver
    # pluginCfg via closure on the outer stage, NOT as a named arg
    # on the inner — because NixOS's module system routes every
    # named module-function arg through `_module.args.<name>`, and
    # that namespace is global: two plugins both declaring
    # `pluginCfg` as a module arg would collide with
    #   `_module.args.pluginCfg' is defined multiple times`.
    # Two-stage isolates each plugin's cfg inside its own closure.
    pluginModules = let
      pluginDirs = builtins.attrNames (builtins.readDir ./plugins);
      isPluginDir = name: let
        entries = builtins.readDir ./plugins;
        isDir = (entries.${name} or null) == "directory";
      in
        isDir && builtins.pathExists (./plugins + "/${name}/plugin.nix");
      mkPluginModule = name: let
        pluginPath = ./plugins + "/${name}/plugin.nix";
        configPath = ./plugins + "/${name}/config.json";
        cfg =
          if builtins.pathExists configPath
          then builtins.fromJSON (builtins.readFile configPath)
          else {};
      in
        # `import pluginPath` returns the outer function; calling it
        # with {pluginCfg = cfg} returns the inner module function
        # (no pluginCfg in that signature), which the module system
        # treats as a normal NixOS module.
        (import pluginPath) {pluginCfg = cfg;};
    in
      map mkPluginModule (builtins.filter isPluginDir pluginDirs);
  in {
    nixosModules.default = {
      imports =
        (findModules ./modules)
        ++ (
          if builtins.pathExists ./plugins
          then pluginModules
          else []
        )
        ++ [
          disko.nixosModules.default
          nix-bitcoin.nixosModules.default
          blitz-api.nixosModules.default
          blitz-web.nixosModules.default
        ];
    };

    nixosConfigurations.nixblitz = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {inherit nixblitz;};
      modules = [
        ./hosts/installed.nix
        self.nixosModules.default
      ];
    };

    # Live-ISO config used by `disko-install --flake .#nixblitz-installer`.
    # Identical to nixosConfigurations.nixblitz except for passwordless
    # sudo. See docs/decisions/plugins.md (sudo posture).
    nixosConfigurations.nixblitz-installer = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {inherit nixblitz;};
      modules = [
        ./hosts/installer.nix
        self.nixosModules.default
      ];
    };

    # Pi 5 build target. Use `nixos-raspberrypi.lib.nixosSystem`
    # (not `nixpkgs.lib.nixosSystem`) so the upstream's bootloader
    # / vendor-kernel / vendor-firmware / kernel-and-firmware
    # overlays are auto-applied. The opt-in `pkgs` overlay
    # (ffmpeg, kodi, etc.) is NOT applied — `nixosSystem` is the
    # node-friendly variant; `nixosSystemFull` would pull in the
    # media stack, which is wasted on a headless node.
    nixosConfigurations.nixblitz-pi5 = nixos-raspberrypi.lib.nixosSystem {
      specialArgs = {inherit nixblitz nixos-raspberrypi;};
      modules = [
        ./hosts/installed-pi5.nix
        self.nixosModules.default
      ];
    };

    # Pi 5 install target. Used by
    # `disko-install --flake .#nixblitz-pi5-installer` from inside
    # the live image (typically the upstream
    # `nvmd/nixos-raspberrypi#installerImages.rpi5` flashed to a
    # USB stick). Differs from `nixblitz-pi5` only in
    # `installer-pi5.nix`'s passwordless sudo override; same
    # bootloader / kernel / firmware / disko layout.
    nixosConfigurations.nixblitz-pi5-installer = nixos-raspberrypi.lib.nixosSystem {
      specialArgs = {inherit nixblitz nixos-raspberrypi;};
      modules = [
        ./hosts/installer-pi5.nix
        self.nixosModules.default
      ];
    };
  };
}
