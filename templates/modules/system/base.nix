{
  config,
  lib,
  pkgs,
  nixblitz,
  ...
}: let
  cfg = config.features.system.base;
in {
  options.features.system.base = {
    enable = lib.mkEnableOption "base NixBlitz system configuration";

    # The TUI surfaces this as a select in Configure → system. Both
    # candidates ship in environment.systemPackages below so flipping
    # the choice doesn't trigger a fresh closure download.
    shell = lib.mkOption {
      type = lib.types.enum ["bash" "nushell"];
      default = "bash";
      description = "Default login shell for the admin user.";
    };
  };

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
      # Both shells are kept available regardless of the
      # `defaultUserShell` choice — operators flipping the option
      # via Configure shouldn't have to wait on a new closure
      # fetch, and a `nu` / `bash` invocation from a script keeps
      # working.
      bashInteractive
      nushell
      nixblitz.packages.${pkgs.system}.nixblitz-unwrapped
    ];

    users.defaultUserShell =
      if cfg.shell == "nushell"
      then pkgs.nushell
      else pkgs.bashInteractive;
  };
}
