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

    boot.loader.grub = {
      enable = true;
      devices = ["/dev/vda"];
    };
  };
}
