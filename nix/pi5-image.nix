# Buildable aarch64 Raspberry Pi 5 installer image carrying the nixblitz TUI.
#
# A dev/release artifact (built on a dev machine / CI), NOT shipped to nodes —
# hence it lives in the top-level flake, not templates/. The aarch64 analogue of
# nix/iso.nix: a live medium that auto-launches the TUI; the operator then runs
# the install wizard, which scaffolds ~/nixblitz from the TUI's embedded
# templates and calls `disko-install --flake ~/nixblitz#nixblitz-pi5-installer`.
#
# Pure function: takes nixos-raspberrypi + the (wrapped, aarch64) TUI package +
# the baked offline closure, so it never reaches into templates/ or `self`.
{
  nixos-raspberrypi,
  nixblitzPackage,
  installerClosure,
}:
# nixosInstaller composes nixos-raspberrypi's full config + the sd-image module
# (→ config.system.build.sdImage) + the installer profile (installation-device:
# tty1 `nixos` autologin, passwordless sudo). nixpkgs defaults to
# nixos-raspberrypi's own pinned rev (the 16K-page-aligned nixpkgs backing
# nixos-raspberrypi.cachix.org) — do NOT override it.
nixos-raspberrypi.lib.nixosInstaller {
  modules = [
    (
      {
        config,
        lib,
        ...
      }: {
        imports = with nixos-raspberrypi.nixosModules; [
          # Pi 5 vendor kernel + matched firmware + 16K pages.
          raspberry-pi-5.base
          # 16K-page-aware jemalloc (nvmd#64 / issue #24).
          raspberry-pi-5.page-size-16k
        ];

        # The wrapped TUI (disko + git already on PATH). The operator runs the
        # install wizard from here; it scaffolds ~/nixblitz from the embedded
        # templates and calls disko-install against nixblitz-pi5-installer.
        environment.systemPackages = [nixblitzPackage];

        # The installer profile already gives passwordless sudo + a `nixos`
        # tty1 autologin. Set a known password too so `ssh nixos@<host>` works
        # on this ephemeral medium (mirrors nix/iso.nix). Clear the profile's
        # empty initialHashedPassword (mkForce → null) so NixOS doesn't warn
        # about multiple password options.
        users.users.nixos.initialHashedPassword = lib.mkForce null;
        users.users.nixos.initialPassword = "nixblitz";

        # Auto-launch the TUI on the live console's interactive shell (fires on
        # the installer profile's tty1 autologin bash). Guard skips
        # non-interactive / already-launched shells so `ssh host <cmd>` and
        # nested shells don't recurse. Kept as a small dedicated copy of the
        # snippet in templates/modules/system/base.nix so this dev artifact
        # stays decoupled from templates/ (same as nix/iso.nix).
        programs.bash.interactiveShellInit = ''
          if [ -z "''${NIXBLITZ_AUTOLAUNCHED:-}" ] && [ -t 0 ] && [ -t 1 ] \
              && command -v nixblitz >/dev/null 2>&1; then
            export NIXBLITZ_AUTOLAUNCHED=1
            nixblitz
          fi
        '';

        # Recognizable artifact name → nixblitz-pi5-installer.img.zst. The
        # installer chain sets image.baseName at `mkOverride 40`
        # (nixos-raspberrypi flake.nix), so a plain `mkForce` (priority 50)
        # would LOSE — override at a higher priority. This is the Pi 5 analogue
        # of the isoBaseName subtlety in nix/iso.nix.
        image.baseName = lib.mkOverride 30 "nixblitz-pi5-installer";

        # Bake the minimal installer-system closure into the image rootfs so
        # disko-install runs fully offline — the direct analogue of
        # isoImage.storeContents. Default sdImage.storePaths is
        # [config.system.build.toplevel]; append the nixblitz-pi5-installer
        # toplevel (built by nix/pi5-installer-system.nix, threaded from
        # flake.nix). Overlapping store paths are copied once. As with the x86
        # ISO this is representative, not byte-exact: the real install uses the
        # operator's hardware config, so the final per-machine system builds
        # locally at install time — offline, because its leaves are baked.
        sdImage.storePaths = [config.system.build.toplevel installerClosure];
      }
    )
  ];
}
