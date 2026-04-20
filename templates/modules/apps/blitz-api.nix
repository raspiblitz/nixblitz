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
