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

        # Stable, recognizable artifact name. Set `isoImage.isoBaseName`
        # (the filename *stem*) rather than `isoImage.isoName` /
        # `image.fileName` directly: nixpkgs 25.11 recomposes the final
        # filename from the base name via the new image API, so a direct
        # `isoName` override is silently recomposed away, whereas the base
        # name flows through cleanly. Result: nixblitz-installer.iso.
        isoImage.isoBaseName = lib.mkForce "nixblitz-installer";

        # Bake the minimal installer-system closure into the live store so
        # disko-install runs fully offline — every leaf package it needs is
        # already present, no substituter required. squashfs dedups these
        # against the live system's own closure, so the ISO grows only by the
        # non-overlapping installed paths. The closure is built by
        # nix/installer-system.nix and threaded in from flake.nix.
        isoImage.storeContents = [installerClosure];
      }
    )
  ];
}
