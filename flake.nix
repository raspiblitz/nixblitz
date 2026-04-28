{
  description = "NixBlitz - Bitcoin/Lightning NixOS node manager";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:fusion44/nixpkgs/dart-workspace-member-filter";
    flake-utils.url = "github:numtide/flake-utils";
    nix-filter.url = "github:numtide/nix-filter";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    flake-utils,
    nix-filter,
    disko,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
        version = "0.1.0";
        # Short git hash of the source tree at build time, tagged with
        # "-dirty" when the worktree has uncommitted changes. Surfaces
        # in the TUI header and `nixblitz --version` output.
        gitHash = self.shortRev or self.dirtyShortRev or "unknown";

        nixblitzUnwrapped = pkgsUnstable.callPackage ./nix/tui_pkg.nix {
          nixFilter = nix-filter.lib;
          inherit version gitHash;
          # Augmented version goes into the derivation's name so
          # `nvd diff` lists nixblitz as changed on every commit
          # (otherwise nvd compares "nixblitz-0.1.0" against
          # itself and reports "No version or selection state
          # changes" even when the binary actually moved). Display
          # surfaces (TUI header, --version) still see plain
          # [version] so they don't churn on micro-changes.
          derivationVersion = "${version}+${gitHash}";
        };

        # Wrap nixblitz with disko and git on PATH so `nix run` just works
        nixblitzWrapped = pkgs.writeShellScriptBin "nixblitz" ''
          export PATH="${pkgs.lib.makeBinPath [
            disko.packages.${system}.default
            pkgs.git
          ]}:$PATH"
          exec ${nixblitzUnwrapped}/bin/nixblitz "$@"
        '';
      in {
        packages = {
          default = self.packages.${system}.nixblitz;
          nixblitz = nixblitzWrapped;
          nixblitz-unwrapped = nixblitzUnwrapped;
        };

        apps.default = {
          type = "app";
          program = "${nixblitzWrapped}/bin/nixblitz";
        };
      }
    );
}
