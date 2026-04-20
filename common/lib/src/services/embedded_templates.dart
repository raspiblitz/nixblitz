// AUTO-GENERATED — do not edit by hand.
// Run the generator to refresh from templates/.

/// Provides all NixOS template files embedded as string constants.
class EmbeddedTemplates {
  EmbeddedTemplates._();

  /// Returns a map of relative path → file content for every template file.
  static Map<String, String> getAll() {
    return {
      'flake.nix': _flakeNix,
      'hardware/pi4.nix': _hardwarePi4,
      'hardware/pi5.nix': _hardwarePi5,
      'hardware/vm.nix': _hardwareVm,
      'hardware/x86.nix': _hardwareX86,
      'hosts/default.nix': _hostsDefault,
      'modules/apps/bitcoind.nix': _modulesAppsBitcoind,
      'modules/apps/blitz-api.nix': _modulesAppsBlitzApi,
      'modules/apps/blitz-web.nix': _modulesAppsBlitzWeb,
      'modules/apps/cln.nix': _modulesAppsCln,
      'modules/apps/lnd.nix': _modulesAppsLnd,
      'modules/system/base.nix': _modulesSystemBase,
      'modules/system/disko-vm.nix': _modulesSystemDiskoVm,
    };
  }

  // ---------------------------------------------------------------------------
  // flake.nix
  // ---------------------------------------------------------------------------
  static const String _flakeNix = r'''
{
  description = "NixBlitz node configuration";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-bitcoin = {
      url = "github:fort-nix/nix-bitcoin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    nix-bitcoin,
  }: let
    inherit (nixpkgs) lib;

    excludedFiles = ["package.nix" "flake.nix"];

    findModules = dir: let
      entries = builtins.readDir dir;
      processEntry = name: type: let
        path = dir + "/${name}";
      in
        if type == "directory"
        then findModules path
        else if type == "regular" && lib.hasSuffix ".nix" name && !builtins.elem name excludedFiles
        then [path]
        else [];
    in
      lib.concatLists (lib.mapAttrsToList processEntry entries);
  in {
    nixosModules.default = {
      imports =
        (findModules ./modules)
        ++ [
          disko.nixosModules.default
          nix-bitcoin.nixosModules.default
        ];
    };

    nixosConfigurations.nixblitz = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/default.nix
        self.nixosModules.default
      ];
    };
  };
}
''';

  // ---------------------------------------------------------------------------
  // hardware/pi4.nix
  // ---------------------------------------------------------------------------
  static const String _hardwarePi4 = r'''
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
''';

  // ---------------------------------------------------------------------------
  // hardware/pi5.nix
  // ---------------------------------------------------------------------------
  static const String _hardwarePi5 = r'''
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
}
''';

  // ---------------------------------------------------------------------------
  // hardware/vm.nix
  // ---------------------------------------------------------------------------
  static const String _hardwareVm = r'''
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd = {
      availableKernelModules = ["ata_piix" "uhci_hcd" "virtio_pci" "floppy" "sr_mod" "virtio_blk"];
      kernelModules = [];
    };
    kernelModules = ["kvm-amd"];
    extraModulePackages = [];
  };

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

  swapDevices = [];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  services.qemuGuest.enable = true;
}
''';

  // ---------------------------------------------------------------------------
  // hardware/x86.nix
  // ---------------------------------------------------------------------------
  static const String _hardwareX86 = r'''
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  disko.devices.disk.main = {
    device = lib.mkDefault "/dev/sda";
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

  boot.loader.grub.enable = true;
}
''';

  // ---------------------------------------------------------------------------
  // hosts/default.nix
  // ---------------------------------------------------------------------------
  static const String _hostsDefault = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = builtins.fromJSON (builtins.readFile ../config.json);
  sys = cfg.system;
in {
  imports = [
    ../hardware-configuration.nix
  ];

  networking.hostName = sys.hostname;
  time.timeZone = sys.timezone;

  features.system.base.enable = true;

  # Disk layout — enable the appropriate disko config for the platform
  features.system.disko-vm.enable = sys.platform == "vm" || sys.platform == "x86";

  features.apps.bitcoind.enable = cfg.bitcoind.enabled;
  features.apps.bitcoind.network = cfg.bitcoind.network;
  features.apps.bitcoind.pruned = cfg.bitcoind.pruned;
  features.apps.bitcoind.pruneSizeGb = cfg.bitcoind.prune_size_gb;

  features.apps.lnd.enable = cfg.lnd.enabled;
  features.apps.lnd.alias = cfg.lnd.alias;

  features.apps.cln.enable = cfg.cln.enabled;

  features.apps.blitz-api.enable = cfg.blitz_api.enabled;
  features.apps.blitz-web.enable = cfg.blitz_web.enabled;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    initialPassword = "nixblitz";
  };

  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  system.stateVersion = "25.11";
}
''';

  // ---------------------------------------------------------------------------
  // modules/apps/bitcoind.nix
  // ---------------------------------------------------------------------------
  static const String _modulesAppsBitcoind = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.bitcoind;
in {
  options.features.apps.bitcoind = {
    enable = lib.mkEnableOption "Bitcoin daemon";
    network = lib.mkOption {
      type = lib.types.enum ["mainnet" "testnet" "signet"];
      default = "mainnet";
      description = "Bitcoin network to connect to.";
    };
    pruned = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to prune the blockchain.";
    };
    pruneSizeGb = lib.mkOption {
      type = lib.types.int;
      default = 550;
      description = "Prune target size in GB (minimum 550).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.bitcoind = {
      enable = true;
      dataDir = "/mnt/data/bitcoind";
      regtest = cfg.network == "regtest";
      prune = if cfg.pruned then cfg.pruneSizeGb * 1000 else 0;
      extraConfig = ''
        server=1
        ${lib.optionalString (cfg.network == "testnet") "testnet=1"}
        ${lib.optionalString (cfg.network == "signet") "signet=1"}
      '';
    };
  };
}
''';

  // ---------------------------------------------------------------------------
  // modules/apps/blitz-api.nix
  // ---------------------------------------------------------------------------
  static const String _modulesAppsBlitzApi = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.blitz-api;
in {
  options.features.apps.blitz-api = {
    enable = lib.mkEnableOption "Blitz API";
  };

  config = lib.mkIf cfg.enable {
    # TODO: configure blitz-api service
    # This depends on the blitz-api package being available in nixpkgs or as a flake input
  };
}
''';

  // ---------------------------------------------------------------------------
  // modules/apps/blitz-web.nix
  // ---------------------------------------------------------------------------
  static const String _modulesAppsBlitzWeb = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.blitz-web;
in {
  options.features.apps.blitz-web = {
    enable = lib.mkEnableOption "Blitz Web UI";
  };

  config = lib.mkIf cfg.enable {
    # TODO: configure blitz-web service
    # This depends on the blitz-web package being available in nixpkgs or as a flake input
  };
}
''';

  // ---------------------------------------------------------------------------
  // modules/apps/cln.nix
  // ---------------------------------------------------------------------------
  static const String _modulesAppsCln = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.cln;
in {
  options.features.apps.cln = {
    enable = lib.mkEnableOption "Core Lightning (CLN)";
  };

  config = lib.mkIf cfg.enable {
    services.clightning = {
      enable = true;
      dataDir = "/mnt/data/clightning";
    };
  };
}
''';

  // ---------------------------------------------------------------------------
  // modules/apps/lnd.nix
  // ---------------------------------------------------------------------------
  static const String _modulesAppsLnd = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.lnd;
in {
  options.features.apps.lnd = {
    enable = lib.mkEnableOption "Lightning Network Daemon (LND)";
    alias = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Node alias visible on the Lightning Network.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.lnd = {
      enable = true;
      dataDir = "/mnt/data/lnd";
      extraConfig = ''
        ${lib.optionalString (cfg.alias != "") "alias=${cfg.alias}"}
      '';
    };
  };
}
''';

  // ---------------------------------------------------------------------------
  // modules/system/base.nix
  // ---------------------------------------------------------------------------
  static const String _modulesSystemBase = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.system.base;
in {
  options.features.system.base.enable = lib.mkEnableOption "base NixBlitz system configuration";

  config = lib.mkIf cfg.enable {
    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["root" "admin"];
    };

    # nix-bitcoin secrets management
    nix-bitcoin.generateSecrets = true;

    environment.systemPackages = with pkgs; [
      git
      htop
      btop
      tree
      jq
      nushell
    ];

    users.defaultUserShell = pkgs.nushell;
  };
}
''';

  // ---------------------------------------------------------------------------
  // modules/system/disko-vm.nix
  // ---------------------------------------------------------------------------
  static const String _modulesSystemDiskoVm = r'''
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
''';
}
