# Buildable x86_64 installer ISO carrying the nixblitz TUI.
#
# A dev/release artifact (built on a dev machine / CI), NOT shipped to
# nodes — hence it lives in the top-level flake, not templates/. It is a
# minimal NixOS live medium that auto-launches the TUI; the operator then
# runs the install wizard, which scaffolds ~/nixblitz from the TUI's
# embedded templates and calls `disko-install --flake ~/nixblitz#nixblitz-installer`.
#
# Pure function: takes nixpkgs + the (wrapped) TUI package so it never
# reaches into templates/ or `self`.
{
  nixpkgs,
  nixblitzPackage,
  installerClosure,
  # Path-locked templates/flake.lock (nix/offline-flake-lock.nix), delivered
  # onto the live medium so `disko-install --flake ~/nixblitz#...` can copy
  # it over the scaffolded ~/nixblitz's own lock instead of re-resolving
  # inputs from the network.
  offlineLock,
  # Every input source store path the above lock resolves against
  # (nix/offline-inputs.nix `sourcePaths`) — baked into the ISO store
  # alongside offlineLock so the path references it contains actually
  # exist on the live medium.
  offlineSourcePaths,
  # disko-install's ACTUAL eval products — the diskoScript / formatScript /
  # mountScript / installToplevel / closureInfo it realizes on the live medium
  # (nix/install-cli-products.nix). Baking these OUTPUTS means a fixture-path
  # install builds zero drvs; their `.inputDerivation`s ride in
  # installerBuilderPaths for the real-machine delta. A list so all five are
  # threaded through one arg.
  installerCliProducts,
  # Build-time closure (stdenv + perl-env + makeInitrd tooling) needed to
  # REBUILD the per-machine delta derivations offline — see
  # nix/builder-closure.nix. The baked `installerClosure` only carries the
  # runtime closure; without these the operator's own
  # hardware-configuration.nix + disk would drop into a bootstrap-stdenv
  # rebuild that dies offline.
  installerBuilderPaths,
  # closureInfo's `total-nar-size` file (nix/install-cli-products.nix
  # `cliProducts.closureInfo` — a store path, not baked separately: it's
  # already one of the `installerCliProducts` above). Exposed to the
  # install wizard's copy-progress bar as a static file so it doesn't have
  # to `du -sb /nix/store` on the live medium (minutes, with the offline
  # ISO's ~500k-file store) to learn the total it's copying (13s on fast
  # hardware). See common/lib/src/services/install/install_progress.dart
  # `installTotalBytesFromEtc`.
  installTotalBytesFile,
}:
nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    (
      {
        modulesPath,
        lib,
        ...
      }: {
        imports = [
          "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
        ];

        # The wrapped TUI (disko + git already on PATH). The operator runs
        # the install wizard from here; it scaffolds ~/nixblitz from the
        # embedded templates and calls disko-install against
        # nixblitz-installer.
        environment.systemPackages = [nixblitzPackage];

        # The install wizard runs disko-install / mount /
        # nixos-generate-config non-interactively via `sudo -n`. The live
        # medium is ephemeral, so passwordless sudo is the right default
        # here (mirrors templates/hosts/installer.nix's rationale).
        security.sudo.wheelNeedsPassword = false;

        # Make SSH usable on the live installer: `ssh nixos@<host>`,
        # password "nixblitz" (matches the installed system's admin
        # password). installation-cd-base enables sshd but gives the
        # `nixos` user an empty password, and OpenSSH rejects
        # empty-password auth — so the running daemon is otherwise
        # unreachable. A known password is an acceptable convenience on
        # this ephemeral install-time medium. Clear the profile's empty
        # `initialHashedPassword` (mkForce → null) so only `initialPassword`
        # is set — otherwise NixOS warns about multiple password options.
        users.users.nixos.initialHashedPassword = lib.mkForce null;
        users.users.nixos.initialPassword = "nixblitz";

        # Auto-launch the TUI on the live console's interactive shell. The
        # installation-cd profile auto-logs into a bash shell on tty1; this
        # fires there. Guard skips non-interactive / already-launched
        # shells so `ssh host <cmd>` and nested shells don't recurse.
        # (Kept as a small dedicated copy of the snippet in
        # templates/modules/system/base.nix so this dev artifact stays
        # decoupled from templates/.)
        programs.bash.interactiveShellInit = ''
          if [ -z "''${NIXBLITZ_AUTOLAUNCHED:-}" ] && [ -t 0 ] && [ -t 1 ] \
              && command -v nixblitz >/dev/null 2>&1; then
            export NIXBLITZ_AUTOLAUNCHED=1
            nixblitz
          fi
        '';

        # Stable, recognizable artifact name. `image.baseName` is the
        # 25.11 image-API home of what used to be `isoImage.isoBaseName`
        # (the deprecation alias warned on every eval). Set the base name
        # (the filename *stem*) rather than `image.fileName` directly:
        # the image API recomposes the final filename from the base name,
        # so a direct fileName override is silently recomposed away,
        # whereas the base name flows through cleanly. Result:
        # nixblitz-installer.iso. (Pi 5 analogue in nix/pi5-image.nix
        # needs mkOverride 30 — its installer chain pre-sets the name at
        # 40; here the profile only provides a default, so mkForce is
        # plenty.)
        image.baseName = lib.mkForce "nixblitz-installer";

        # Deliver the path-locked templates/flake.lock onto the live medium.
        # The install wizard's scaffolded ~/nixblitz gets its flake.lock
        # replaced with this one (instead of the source-tree lock, which
        # points at network-fetchable inputs) so `disko-install --flake`
        # resolves every input from the baked store paths below.
        environment.etc."nixblitz/offline-flake.lock".source = offlineLock;

        # Static install-total-bytes for the copy-progress bar (see the
        # `installTotalBytesFile` doc comment above). Read by
        # `installTotalBytesFromEtc` in common/lib/src/services/install/
        # install_progress.dart.
        environment.etc."nixblitz/install-total-bytes".source =
          installTotalBytesFile;

        # Bake the minimal installer-system closure into the live store so
        # disko-install runs fully offline — every leaf package it needs is
        # already present, no substituter required. squashfs dedups these
        # against the live system's own closure, so the ISO grows only by the
        # non-overlapping installed paths. The closure is built by
        # nix/installer-system.nix and threaded in from flake.nix.
        # installerCliProducts and offlineSourcePaths are baked alongside it:
        # the cli products are exactly what disko-install realizes (its
        # diskoScript + installToplevel + closureInfo + format/mountScript),
        # and the source paths are what offlineLock's path-locked nodes resolve
        # against — without them present in the store, the lock's
        # references would dangle.
        isoImage.storeContents =
          [installerClosure]
          ++ installerCliProducts
          ++ offlineSourcePaths
          ++ installerBuilderPaths;

        # Harden against accidental network use now that the ISO is
        # self-contained: no flake registry lookups, and a short connect
        # timeout so any attempt fails fast instead of hanging. Substituters
        # are deliberately NOT cleared — network stays a fallback if the
        # baked store is ever incomplete, rather than a hard failure.
        #
        # experimental-features must be enabled system-wide here:
        # `flake-registry` is a flakes-gated setting, and NixOS's
        # nix.conf build-time validation treats "ignoring setting
        # 'flake-registry'" as fatal without it. (disko-install passes
        # the features per-invocation, but the validator checks the
        # system nix.conf.) Same pairing as clan-core's offline flash
        # check.
        nix.settings = {
          experimental-features = ["nix-command" "flakes"];
          flake-registry = "";
          connect-timeout = 3;
        };
      }
    )
  ];
}
