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
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    nix-bitcoin,
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
        ];
    };

    nixosConfigurations.nixblitz = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/default.nix
        self.nixosModules.default
      ];
    };
  };
}
