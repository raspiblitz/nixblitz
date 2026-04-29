{
  config,
  lib,
  ...
}: let
  cfg = config.features.system.disko-x86;
in {
  options.features.system.disko-x86.enable =
    lib.mkEnableOption "x86 disk layout (GPT, BIOS-boot + ESP + ext4 root)";

  config = lib.mkIf cfg.enable {
    # Hybrid GPT layout — boots on both BIOS (qemu/Proxmox/older
    # hardware) and UEFI (essentially every modern x86 board)
    # without operator intervention. Three partitions:
    #
    # 1. `bios` (1 MB, type EF02): GRUB's BIOS-boot partition.
    #    No filesystem; GRUB embeds its core image directly into
    #    the partition bytes.
    # 2. `esp` (512 MB, type EF00, FAT32): the EFI System
    #    Partition. Mounted at /boot. Holds the GRUB EFI binary
    #    + the kernel / initrd images.
    # 3. `root` (rest, ext4): the system + /nix/store + /home.
    #
    # Without the ESP, a UEFI machine can't find an EFI binary
    # and hangs at firmware setup ("no boot device") — which is
    # exactly the regression that hit the operator's first
    # bare-metal install. Adding the ESP costs 512 MB and makes
    # the same image portable across firmware modes.
    disko.devices.disk.main = {
      device = lib.mkDefault "/dev/vda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          bios = {
            size = "1M";
            type = "EF02";
            # Must come first on the disk for GRUB's BIOS embed
            # to find it.
            priority = 1;
          };
          esp = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              # Restrict the firmware partition to root — nothing
              # at runtime should be reading kernels from there.
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

    # GRUB in dual-mode: BIOS install lands on the EF02
    # partition (disko sets boot.loader.grub.devices for us),
    # EFI install lands at /EFI/BOOT/BOOTX64.EFI on the ESP.
    # `efiInstallAsRemovable = true` uses the standard fallback
    # path, so the firmware finds the binary without needing an
    # NVRAM entry — robust for VMs (no persistent NVRAM) and
    # reinstalls onto different disks.
    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
  };
}
