{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.blitz-web;
in {
  options.features.apps.blitz-web = {
    enable = lib.mkEnableOption "Blitz Web UI (mobile-first frontend)";
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = ''
        Nginx virtual host name. Share this with `features.apps.blitz-api`
        so the SPA and its backend API land on the same vhost — the
        frontend is built with BACKEND_SERVER fixed to http://127.0.0.1.
      '';
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open port 80 on the nginx virtual host.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Upstream renamed the attribute to `services.raspiblitz-web`; our
    # user-facing `features.apps.blitz-web` option keeps the shorter name
    # for symmetry with blitz-api.
    services.raspiblitz-web = {
      enable = true;
      nginx = {
        enable = true;
        hostName = cfg.hostName;
        location = "/";
        openFirewall = cfg.openFirewall;
      };
    };
  };
}
