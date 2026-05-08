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
    # documented at github.com/nvmd/nixos-raspberrypi. The
    # vendor kernel is configured for 16K pages at build time
    # (CONFIG_ARM64_16K_PAGES) — that's not something `.base` is
    # opting into, it's just what the hardware-friendly Pi 5
    # kernel ships with.
    nixos-raspberrypi.nixosModules.raspberry-pi-5.base
    # Optional-but-required-in-practice: rebuilds `pkgs.jemalloc`
    # with `--with-lg-page=14` (16K-aware). Without it, any C
    # binary on cache.nixos.org that links the system jemalloc
    # aborts with "Unsupported system page size" at startup
    # because cache.nixos.org's substitutes are built for 4K
    # alignment. See nvmd/nixos-raspberrypi#64.
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

  # Enable the Pi 5's onboard 4-pin fan header. Without this dtparam
  # the `cooling_fan` device tree node stays at its default
  # `status = "disabled"` and the kernel never enrolls the fan as
  # a thermal cooling device — `/sys/class/thermal/cooling_device*`
  # comes up empty, no PWM control reaches the fan, and the SoC
  # cooks under sustained load (kernel compile, etc). The vendor
  # `nixos-raspberrypi` flake doesn't turn this on by default.
  hardware.raspberry-pi.config.all.base-dt-params.cooling_fan = {
    enable = true;
    value = "on";
  };
}
