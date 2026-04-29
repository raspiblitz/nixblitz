{
  config,
  lib,
  ...
}: let
  cfg = config.features.system.disko-pi5;
in {
  options.features.system.disko-pi5.enable =
    lib.mkEnableOption "Pi 5 disk layout (GPT, FAT firmware + ext4 root)";

  config = lib.mkIf cfg.enable {
    # Pi 5 boot path needs a FAT partition for vendor firmware,
    # device-tree blobs, overlays, and (with the `kernel`
    # bootloader from nvmd/nixos-raspberrypi) per-generation
    # kernel images. Mount point matches the upstream module's
    # default `boot.loader.raspberry-pi.firmwarePath` so we don't
    # have to wire that through here.
    #
    # Default device targets NVMe (the supported configuration
    # via the official M.2 HAT) but `disko-install --disk main
    # <path>` overrides this at install time, so the user can
    # pick SD / USB / NVMe at the wizard step regardless.
    disko.devices.disk.main = {
      device = lib.mkDefault "/dev/nvme0n1";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          firmware = {
            # 1 GB headroom matches the upstream installer
            # image's `sdImage.firmwareSize = 1024` so multiple
            # NixOS generations + their kernels fit alongside the
            # vendor firmware blobs.
            size = "1024M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot/firmware";
              # 0077 keeps the firmware partition root-owned —
              # nothing should be reading kernel images from
              # here at runtime.
              mountOptions = ["umask=0077"];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
