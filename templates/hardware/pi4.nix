{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  hardware.enableRedistributableFirmware = true;

  boot.kernelParams = ["cma=64M"];
}
