{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.system.operator;
in {
  options.features.system.operator = {
    enable =
      lib.mkEnableOption
      "operator user access to service CLIs (bitcoin-cli, lncli, lightning-cli)";
    name = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Existing user to grant operator access.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix-bitcoin.operator = {
      enable = true;
      name = cfg.name;
    };
  };
}
