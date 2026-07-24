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

    # Vanilla nixos-unstable, used ONLY by the config-channel
    # verification checks (tests/config) to eval the node config
    # against unstable. Distinct from nixpkgs-unstable above (the
    # dart-workspace-member-filter fork, for the TUI build). No
    # follows — it only supplies lib.nixosSystem for the eval.
    nixpkgs-vanilla-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # flake-utils + nix-filter are pure-lib flakes with no nixpkgs
    # input themselves — nothing to follow.
    flake-utils.url = "github:numtide/flake-utils";
    nix-filter.url = "github:numtide/nix-filter";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Raspberry Pi 5 vendor kernel + firmware + 16K-page nixpkgs, for the
    # aarch64 installer image (nix/pi5-image.nix). Deliberately NO follows in
    # either direction: nixos-raspberrypi pins its own nixpkgs (the rev its
    # cachix cache is built against) and the Pi 5 image must build against
    # THAT — making it follow our nixpkgs would diverge the derivation hash,
    # force a multi-hour local kernel rebuild, and risk 16K-page SIGBUS. Same
    # rule as templates/flake.nix; see CLAUDE.md → Flake input rules.
    # Tag-pinned: bump deliberately, never via a blind `nix flake update`.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/v1.20260707.1";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    nixpkgs-vanilla-unstable,
    flake-utils,
    nix-filter,
    disko,
    nixos-raspberrypi,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
        lib = nixpkgs.lib;
        # The ONE wasmtime version nixblitz controls (pinned c-api
        # release, independent of any nixpkgs input) — its lib is baked
        # into the wrapper and its headers feed the ffigen bindings, so
        # runtime ABI can never drift from the generated code. See
        # nix/wasmtime.nix and CLAUDE.md → Flake input rules.
        wasmtimePinned = pkgs.callPackage ./nix/wasmtime.nix {};
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
          inherit wasmtimePinned version gitHash derivationVersion;
        };

        # Wrap nixblitz with disko and git on PATH so `nix run` just works
        nixblitzWrapped = pkgs.writeShellScriptBin "nixblitz" ''
          export PATH="${pkgs.lib.makeBinPath [
            disko.packages.${system}.default
            pkgs.git
          ]}:$PATH"
          export WASMTIME_DART_LIB="${wasmtimePinned}/lib/libwasmtime.so"
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
        packages =
          {
            default = self.packages.${system}.nixblitz;
            nixblitz = nixblitzWrapped;
            nixblitz-unwrapped = nixblitzUnwrapped;
            website = nixblitzWebsite;
            # Pinned wasmtime c-api (lib + headers). `gen-wasmtime-bindings`
            # reads its headers; the wrapper bakes its lib.
            wasmtime-pinned = wasmtimePinned;
          }
          # x86 installer ISO — a dev/release artifact (see nix/iso.nix).
          # Gated to x86_64-linux: it's an x86 live medium and references
          # the x86 wrapped TUI.
          // lib.optionalAttrs (system == "x86_64-linux") (let
            # Single eval shared by installer-iso, installer-toplevel, and
            # offline-flake-lock below (closes the "double-IFD" review Minor
            # — installer-system.nix's fixture build used to run twice).
            offlineInputs = import ./nix/offline-inputs.nix {
              inherit self nixos-raspberrypi disko;
            };
            offlineLock = import ./nix/offline-flake-lock.nix {
              inherit pkgs offlineInputs;
            };
            installerSystem = import ./nix/installer-system.nix {
              inherit self disko nixos-raspberrypi system;
            };
          in {
            installer-iso =
              (import ./nix/iso.nix {
                inherit nixpkgs;
                nixblitzPackage = nixblitzWrapped;
                # Minimal installer-system closure, baked into the ISO store
                # so disko-install runs offline (see nix/installer-system.nix).
                installerClosure = installerSystem.toplevel;
                installerDiskoScript = installerSystem.diskoScript;
                # Path-locked templates/flake.lock + the input source paths
                # it resolves against (see nix/offline-flake-lock.nix,
                # nix/offline-inputs.nix) — makes the ISO fully offline.
                inherit offlineLock;
                offlineSourcePaths = offlineInputs.sourcePaths;
              })
              .config
              .system
              .build
              .isoImage;

            # Debug/test output for evaluating the installer system THROUGH
            # templates/flake.nix's own outputs function (see
            # nix/installer-system.nix) — the "closure A == closure B" check.
            # `nix eval .#packages.x86_64-linux.installer-toplevel.drvPath`
            # must succeed without a full build.
            installer-toplevel = installerSystem.toplevel;

            # Debug/test output for the offline path-locked flake.lock
            # generator (see nix/offline-flake-lock.nix, nix/offline-inputs.nix).
            # `nix build .#offline-flake-lock` must succeed with zero network
            # access — that's the proof every templates/flake.lock input is
            # covered by a path override.
            offline-flake-lock = offlineLock;
          })
          # NixBlitz Raspberry Pi 5 installer image — a dev/release artifact
          # (see nix/pi5-image.nix). Gated to aarch64-linux: it's an aarch64
          # live medium built via nixos-raspberrypi. Build needs an aarch64
          # builder (or binfmt) + the nixos-raspberrypi.cachix.org and
          # attic.f44.fyi/nixblitz substituters (see docs/releasing-installer-images.md).
          // lib.optionalAttrs (system == "aarch64-linux") (let
            # Single eval shared by pi5-installer-image below (same pattern
            # as the x86_64-linux block above — closes the "double-IFD"
            # review Minor for this side too).
            offlineInputs = import ./nix/offline-inputs.nix {
              inherit self nixos-raspberrypi disko;
            };
            offlineLock = import ./nix/offline-flake-lock.nix {
              inherit pkgs offlineInputs;
            };
            installerSystem = import ./nix/pi5-installer-system.nix {
              inherit self nixos-raspberrypi disko;
            };
          in {
            pi5-installer-image =
              (import ./nix/pi5-image.nix {
                inherit nixos-raspberrypi;
                nixblitzPackage = nixblitzWrapped;
                # Minimal installer-system closure, baked into the image
                # store so disko-install runs offline (see
                # nix/pi5-installer-system.nix).
                installerClosure = installerSystem.toplevel;
                installerDiskoScript = installerSystem.diskoScript;
                # Path-locked templates/flake.lock + the input source paths
                # it resolves against (see nix/offline-flake-lock.nix,
                # nix/offline-inputs.nix) — makes the image fully offline.
                inherit offlineLock;
                offlineSourcePaths = offlineInputs.sourcePaths;
              })
              .config
              .system
              .build
              .sdImage;
          });

        apps.default = {
          type = "app";
          program = "${nixblitzWrapped}/bin/nixblitz";
        };

        # Config-channel verification (eval tier). x86_64-linux
        # only — Pi 5 configs are locked to nvmd's nixpkgs by
        # design, so varying their channel is meaningless. See
        # tests/config/default.nix.
        checks = lib.optionalAttrs (system == "x86_64-linux") (
          import ./tests/config {
            inherit self lib nixpkgs nixpkgs-vanilla-unstable disko system;
          }
        );
      }
    );
}
