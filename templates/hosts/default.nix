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
