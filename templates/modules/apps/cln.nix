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
