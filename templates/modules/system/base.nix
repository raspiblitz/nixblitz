{
  config,
  lib,
  pkgs,
  nixblitz,
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
      # Used by the TUI's Update view to render a per-package
      # version diff (`[U.] bitcoind 27.1, 27.2`) between the
      # running system and the dry-built next generation. Tiny
      # closure; also useful at the shell.
      nvd
      nushell
      nixblitz.packages.${pkgs.system}.nixblitz-unwrapped
    ];

    users.defaultUserShell = pkgs.nushell;
  };
}
