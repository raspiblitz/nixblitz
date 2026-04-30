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
    # All the NixBlitz feature toggles, hostname, services, etc.
    # x86 and Pi 5 only differ in bootloader / kernel / firmware;
    # everything from `installed.nix` upward is platform-agnostic.
    ./installed.nix
  ];

  # Stay on the standard 4K page size. bcm2712 supports 16K
  # pages and the upstream README recommends opting into them
  # for the jemalloc / glibc tuning, but that breaks any aarch64
  # binary on cache.nixos.org built with the standard 4K
  # alignment — and several of our build-time tools, notably
  # `uv` (Python wheel installer pulled in by blitz-api), link
  # against jemalloc and abort at startup with
  # `<jemalloc>: Unsupported system page size` on a 16K kernel.
  # cache.nixos.org doesn't host 16K-page rebuilds; the upstream
  # nixos-raspberrypi cachix doesn't cover our blitz-api closure.
  # Trading the (small) TLB-efficiency win for a working install
  # is the right call until either (a) we ship our own cachix
  # with 16K-aware builds or (b) jemalloc-using upstream tools
  # gain runtime page-size detection.

  # Migrate off the legacy `kernelboot` default — the new
  # generational `kernel` bootloader supports rollback to a prior
  # generation via the boot menu, matching the experience x86
  # operators already have via systemd-boot.
  boot.loader.raspberry-pi.bootloader = "kernel";
}
