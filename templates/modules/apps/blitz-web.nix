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
