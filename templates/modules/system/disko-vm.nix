{
  config,
  lib,
  ...
}: let
  cfg = config.features.system.disko-vm;
in {
  options.features.system.disko-vm.enable = lib.mkEnableOption "VM disk layout (virtio, single ext4 partition)";

  config = lib.mkIf cfg.enable {
    disko.devices.disk.main = {
      device = lib.mkDefault "/dev/vda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "1M";
            type = "EF02";
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

    # Note: disko automatically configures boot.loader.grub.devices
    # based on the disko.devices.disk.* definitions above. Setting it
    # explicitly here would cause a "duplicated devices in mirroredBoots" error.
    boot.loader.grub.enable = true;
  };
}
