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
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    nix-bitcoin,
    nixblitz,
    blitz-api,
    blitz-web,
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
        ./hosts/default.nix
        self.nixosModules.default
      ];
    };
  };
}
