{
  config,
  lib,
  pkgs,
  nixos-raspberrypi,
  ...
}: {
  imports = [
    # Pi 5 vendor kernel + matched firmware. Comes from
    # `nvmd/nixos-raspberrypi`; the per-Pi attribute set is
    # documented at github.com/nvmd/nixos-raspberrypi.
    nixos-raspberrypi.nixosModules.raspberry-pi-5.base
    # bcm2712 (Pi 5 SoC) supports 16K page sizes; the upstream
    # README recommends enabling this for the jemalloc / glibc
    # tuning that goes with it.
    nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
    # All the NixBlitz feature toggles, hostname, services, etc.
    # x86 and Pi 5 only differ in bootloader / kernel / firmware;
    # everything from `installed.nix` upward is platform-agnostic.
    ./installed.nix
  ];

  # Migrate off the legacy `kernelboot` default — the new
  # generational `kernel` bootloader supports rollback to a prior
  # generation via the boot menu, matching the experience x86
  # operators already have via systemd-boot.
  boot.loader.raspberry-pi.bootloader = "kernel";
}
