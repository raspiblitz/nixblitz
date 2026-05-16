{
  description = "NixBlitz - Bitcoin/Lightning NixOS node manager";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";

    # DELIBERATELY a separate nixpkgs — the dart-workspace-member-filter
    # patch in this fork is what lets the TUI's Dart build evaluate.
    # Following `nixpkgs` here would lose the patch. This is the one
    # documented exception to the "every input follows nixpkgs" rule
    # in CLAUDE.md.
    nixpkgs-unstable.url = "github:fusion44/nixpkgs/dart-workspace-member-filter";

    # flake-utils + nix-filter are pure-lib flakes with no nixpkgs
    # input themselves — nothing to follow.
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
  }: let
    # nixosModules sit outside the per-system block — they evaluate
    # against the consumer's pkgs, not ours. `self` is closed over so
    # the module body can reach `self.packages.${pkgs.system}.cachepop`
    # at consumer-eval time.
    nixosModulesOut = {
      cachepop = import ./cachepop/nix/module.nix self;
    };
  in
    (flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
        version = "0.1.0";
        # Short git hash of the source tree at build time, tagged with
        # "-dirty" when the worktree has uncommitted changes. Surfaces
        # in the TUI header and `nixblitz --version` output.
        gitHash = self.shortRev or self.dirtyShortRev or "unknown";

        # Augmented version goes into the derivation's name so
        # `nvd diff` lists nixblitz as changed on every commit
        # (otherwise nvd compares "nixblitz-0.1.0" against itself
        # and reports "No version or selection state changes" even
        # when the binary actually moved). Display surfaces (TUI
        # header, --version) still see plain [version] so they
        # don't churn on micro-changes.
        #
        # Date prefix matters: nvd parses semver build metadata
        # (the part after `+`) by extracting a leading numeric
        # prefix from each side. A bare git hash like `e7aabca`
        # has no numeric prefix → nvd reads it as 0, while
        # `248a8b8` reads as 248 → newer build flagged as a
        # downgrade ("[D*]"). Prefixing with the flake's
        # `lastModifiedDate` (YYYYMMDDHHMMSS, monotonic across
        # commits) gives nvd a numeric-orderable field to lead
        # with; the hash stays for human debug, same shape
        # `nixos-system-nixblitz` already uses
        # (`25.11.20260510.8fd9daa`).
        flakeDate = self.lastModifiedDate or "0";
        derivationVersion = "${version}+${flakeDate}-${gitHash}";

        nixblitzUnwrapped = pkgsUnstable.callPackage ./nix/tui_pkg.nix {
          nixFilter = nix-filter.lib;
          inherit version gitHash derivationVersion;
        };

        # Wrap nixblitz with disko and git on PATH so `nix run` just works
        nixblitzWrapped = pkgs.writeShellScriptBin "nixblitz" ''
          export PATH="${pkgs.lib.makeBinPath [
            disko.packages.${system}.default
            pkgs.git
          ]}:$PATH"
          exec ${nixblitzUnwrapped}/bin/nixblitz "$@"
        '';

        # Static-rendered Jaspr site. Output is a tree of HTML +
        # CSS + assets ready to drop behind nginx / caddy / any
        # static-file server. Built fully offline in the Nix
        # sandbox via a patched jaspr_cli (vendor/jaspr_cli/),
        # see vendor/jaspr_cli/NIXBLITZ_FORK.md for the rationale.
        nixblitzWebsite = pkgsUnstable.callPackage ./nix/website_pkg.nix {
          nixFilter = nix-filter.lib;
          tailwindcss_4 = pkgs.tailwindcss_4;
          inherit version gitHash derivationVersion;
        };
      in {
        packages = {
          default = self.packages.${system}.nixblitz;
          nixblitz = nixblitzWrapped;
          nixblitz-unwrapped = nixblitzUnwrapped;
          website = nixblitzWebsite;
          cachepop = pkgs.callPackage ./cachepop/nix/cachepop_pkg.nix {
            nixblitz = nixblitzWrapped;
            attic-client = pkgs.attic-client;
          };
        };

        apps.default = {
          type = "app";
          program = "${nixblitzWrapped}/bin/nixblitz";
        };
      }
    ))
    // {
      nixosModules = nixosModulesOut;
    };
}
