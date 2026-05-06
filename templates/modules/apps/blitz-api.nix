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

    # Upstream blitz-api's setup-env script splits bitcoind.zmqpubrawblock
    # on ":" and indexes [2] for the port — assuming a fully-qualified
    # `tcp://addr:port` URL. nix-bitcoin's lnd / cln modules set this option
    # to a sensible default when their LN backend is enabled, but with
    # blitz-api standalone (no LN backend) the option stays null and the
    # upstream script crashes with "elemAt 2 on size 1".
    #
    # Backstop the URL ourselves when no LN backend is on; LND/CLN keep
    # their own mkDefault when they are on.
    services.bitcoind.zmqpubrawblock =
      lib.mkIf
      (!lndEnabled && !clnEnabled)
      (lib.mkDefault "tcp://127.0.0.1:28332");
    services.bitcoind.zmqpubrawtx =
      lib.mkIf
      (!lndEnabled && !clnEnabled)
      (lib.mkDefault "tcp://127.0.0.1:28333");

    # Make the auto-generated `.login-password` (and the dataDir
    # itself) readable to wheel members so the TUI can read it
    # directly via File.readAsString — no sudo dance required. The
    # upstream `services.blitz-api-setup-env` oneshot writes the file
    # mode 0600 owned by root in a 0700 dataDir, which on installed
    # systems (wheelNeedsPassword = true, no NOPASSWD rules) means
    # the admin user can't read it without a cached sudo timestamp.
    # We relax to:
    #   - dataDir 0750 root:wheel (wheel can enter; can't list other
    #     blitz-api private state because per-file modes still
    #     control read access)
    #   - .login-password 0640 root:wheel (wheel can read)
    # Trust boundary: any wheel member is already root-equivalent
    # via sudo, so sharing the JWT password adds nothing. See
    # `common/lib/src/services/blitz_api/blitz_api_client.dart`'s
    # _readPassword for the consumer side.
    systemd.services.blitz-api-setup-env.postStart = ''
      if [ -f /var/lib/blitz_api/.login-password ]; then
        chgrp wheel /var/lib/blitz_api/.login-password
        chmod 0640 /var/lib/blitz_api/.login-password
      fi
      chgrp wheel /var/lib/blitz_api
      chmod 0750 /var/lib/blitz_api
    '';
  };
}
