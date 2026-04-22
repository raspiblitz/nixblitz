{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = builtins.fromJSON (builtins.readFile ../config.json);
  sys = cfg.system;
  # Bootstrap gate: during initial install, `initialized` is false and all
  # services are forced off so disko-install builds a minimal system that
  # fits in the live ISO's tmpfs. After first-boot setup, `initialized`
  # flips to true and the real service configuration is built on the
  # installed system's disk (plenty of space).
  initialized = cfg.initialized or false;
in {
  imports = [
    ../hardware-configuration.nix
  ];

  networking.hostName = sys.hostname;
  time.timeZone = sys.timezone;

  features.system.base.enable = true;

  # Disk layout — enable the appropriate disko config for the platform
  features.system.disko-vm.enable = sys.platform == "vm" || sys.platform == "x86";

  features.apps.bitcoind.enable = initialized && cfg.bitcoind.enabled;
  features.apps.bitcoind.network = cfg.bitcoind.network;
  features.apps.bitcoind.pruned = cfg.bitcoind.pruned;
  features.apps.bitcoind.pruneSizeGb = cfg.bitcoind.prune_size_gb;

  features.apps.lnd.enable = initialized && cfg.lnd.enabled;
  features.apps.lnd.alias = cfg.lnd.alias;

  features.apps.cln.enable = initialized && cfg.cln.enabled;

  features.apps.blitz-api.enable = initialized && cfg.blitz_api.enabled;
  features.apps.blitz-web.enable = initialized && cfg.blitz_web.enabled;

  # Grant admin access to bitcoin-cli / lncli / lightning-cli once services
  # are up. Needs at least one service enabled — nix-bitcoin.operator adds
  # the user to groups that only exist when the relevant service runs.
  features.system.operator.enable =
    initialized
    && (cfg.bitcoind.enabled || cfg.lnd.enabled || cfg.cln.enabled);

  users.users.admin = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    initialPassword = "nixblitz";
  };

  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  system.stateVersion = "25.11";
}
