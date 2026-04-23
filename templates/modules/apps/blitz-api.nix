{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.blitz-api;
  lndEnabled = config.features.apps.lnd.enable;
  clnEnabled = config.features.apps.cln.enable;
in {
  options.features.apps.blitz-api = {
    enable = lib.mkEnableOption "Blitz API (FastAPI backend)";
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = ''
        Nginx virtual host name. Points the frontend at this value via
        the reverse proxy. Share this with `features.apps.blitz-web` so
        both land on the same vhost.
      '';
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open port 80 on the nginx virtual host.";
    };
  };

  config = lib.mkIf cfg.enable {
    # bitcoind is still a hard requirement — the API can't start without
    # it. LN is optional: lnd / clightning / none are all valid.
    assertions = [
      {
        assertion = config.features.apps.bitcoind.enable;
        message = "features.apps.blitz-api requires features.apps.bitcoind.enable";
      }
    ];

    # blitz-api requires a Redis instance on localhost:6379 for the
    # celery task queue + fastapi plugin (BAPI_REDIS_URL defaults to
    # redis://localhost:6379/0 when not overridden). The empty-named
    # NixOS redis server runs on exactly that address/port with a
    # 127.0.0.1 bind by default.
    services.redis.servers."".enable = true;

    services.blitz-api = {
      enable = true;
      generateDotEnvFile = true;
      network = config.features.apps.bitcoind.network;

      # Tell the ASGI app it's mounted under /api so its redirects and
      # OpenAPI schema generate URLs with the right prefix. Matches the
      # nginx location below — nginx strips /api before proxying, but
      # the API still needs to know where it lives externally.
      rootPath = "/api";

      ln.connectionType =
        if lndEnabled
        then "lnd_grpc"
        else if clnEnabled
        then "cln_jrpc"
        else "none";

      nginx = {
        enable = true;
        hostName = cfg.hostName;
        location = "/api";
        openFirewall = cfg.openFirewall;
      };
    };
  };
}
