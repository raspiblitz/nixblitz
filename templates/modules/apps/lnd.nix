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
