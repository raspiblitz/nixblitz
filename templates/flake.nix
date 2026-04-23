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
  in {
    nixosModules.default = {
      imports =
        (findModules ./modules)
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
