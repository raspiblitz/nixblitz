{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.system.testLnd;

  user = "lnd-test";
  group = "lnd-test";
  dataDir = "/var/lib/lnd-test";
  pwFile = "${dataDir}/.wallet-password";
  seedFile = "${dataDir}/.seed-mnemonic";
  # Sentinel we write only after lndinit init-wallet succeeds. Using a
  # marker (instead of "wallet.db exists") means a partial half-init
  # from an earlier failing config doesn't fool us into skipping the
  # real init on the next boot.
  initMarker = "${dataDir}/.wallet-initialized";
  # LND's own layout — chain/ sits directly under dataDir, NOT under a
  # data/ subdir. Matches nix-bitcoin's services.lnd.networkDir.
  networkDir = "${dataDir}/chain/bitcoin/regtest";

  # Reference the primary bitcoind the nix-bitcoin module defines.
  # We talk to it via the group-readable regtest cookie file — no need
  # to thread nix-bitcoin's secrets through for a local test node.
  bitcoind = config.services.bitcoind;
  cookiePath = "${bitcoind.dataDir}/regtest/.cookie";

  # nix-bitcoin ships the `lndinit` helper for headless wallet creation.
  # Grab it from their package set; we already import nix-bitcoin's
  # default NixOS module elsewhere in the system.
  lndinit = "${config.nix-bitcoin.pkgs.lndinit}/bin/lndinit";

  # ZMQ publisher URLs come from nix-bitcoin in tcp://0.0.0.0:PORT form
  # (or [::]); LND won't resolve those to loopback by itself, so swap
  # them to explicit localhost.
  zmqFix = builtins.replaceStrings ["0.0.0.0" "[::]"] ["127.0.0.1" "[::1]"];

  # Alt ports so we don't collide with the primary LND.
  p2pPort = 9736;
  rpcPort = 10010;
  restPort = 8081;

  configFile = pkgs.writeText "lnd-test.conf" ''
    datadir=${dataDir}
    tlscertpath=${dataDir}/tls.cert
    tlskeypath=${dataDir}/tls.key

    # journald already timestamps + tags; no need to log to file.
    logging.file.disable=1
    logging.console.no-timestamps=1

    listen=127.0.0.1:${toString p2pPort}
    rpclisten=127.0.0.1:${toString rpcPort}
    restlisten=127.0.0.1:${toString restPort}

    bitcoin.regtest=1
    bitcoin.node=bitcoind

    bitcoind.rpchost=127.0.0.1:${toString bitcoind.rpc.port}
    bitcoind.rpccookie=${cookiePath}
    bitcoind.zmqpubrawblock=${zmqFix bitcoind.zmqpubrawblock}
    bitcoind.zmqpubrawtx=${zmqFix bitcoind.zmqpubrawtx}

    # The wallet is created headlessly in preStart via lndinit; LND then
    # auto-unlocks on every subsequent boot from the same password file.
    wallet-unlock-password-file=${pwFile}
  '';

  # Admin-friendly wrapper: no arguments needed to hit the right
  # rpcserver/cert/macaroon combo.
  lncliTest = pkgs.writeShellScriptBin "lncli-test" ''
    exec ${pkgs.lnd}/bin/lncli \
      -n regtest \
      --rpcserver=127.0.0.1:${toString rpcPort} \
      --tlscertpath=${dataDir}/tls.cert \
      --macaroonpath=${networkDir}/admin.macaroon \
      "$@"
  '';
in {
  options.features.system.testLnd = {
    enable =
      lib.mkEnableOption
      "secondary LND instance for regtest testing — NOT for production";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = bitcoind.regtest;
        message =
          "features.system.testLnd requires bitcoind running on regtest. "
          + "Set features.apps.bitcoind.network = \"regtest\" first.";
      }
    ];

    users.users.${user} = {
      isSystemUser = true;
      group = group;
      home = dataDir;
      description = "lnd-test (regtest-only secondary LND)";
      # Need the bitcoin group to read bitcoind's regtest cookie file.
      extraGroups = [bitcoind.group];
    };
    users.groups.${group} = {};

    # Admin gets group-read access to the macaroon so `lncli-test`
    # works without sudo.
    users.users.admin.extraGroups = [group];

    systemd.services.lnd-test = {
      wantedBy = ["multi-user.target"];
      requires = ["bitcoind.service"];
      after = ["bitcoind.service"];
      description = "lnd-test (regtest-only secondary LND)";
      preStart = ''
        set -eu
        # Trace every command so the journal shows exactly what ran.
        set -x

        # Debug snapshot of state on entry.
        ${pkgs.coreutils}/bin/ls -la ${dataDir} \
          || echo "(dataDir doesn't exist yet)"

        # One-time wallet password seed; persists across reboots and
        # rebuilds so the wallet stays unlockable.
        if [ ! -s ${pwFile} ]; then
          ${pkgs.coreutils}/bin/tr -dc '[:alnum:]' < /dev/urandom \
            | ${pkgs.coreutils}/bin/head -c 64 > ${pwFile}
          chmod 600 ${pwFile}
        fi

        # Headless wallet init on first boot. LND's `wallet-unlock-password-file`
        # only *unlocks* an existing wallet — creation has to happen out
        # of band via lndinit. Use a marker file we only touch after a
        # successful init so stale wallet fragments from a previous
        # broken attempt force a clean re-init.
        if [ ! -f ${initMarker} ]; then
          echo "lnd-test: wallet not initialized, running lndinit"

          # Nuke any leftover chain state so lndinit starts from
          # scratch. Also clear the bogus `data/` subdir left behind
          # by earlier broken runs of this module.
          ${pkgs.coreutils}/bin/rm -rf \
            ${dataDir}/chain \
            ${dataDir}/data \
            ${dataDir}/graph \
            ${dataDir}/.lnd

          if [ ! -s ${seedFile} ]; then
            (umask 0077; ${lndinit} gen-seed > ${seedFile})
          fi
          ${pkgs.coreutils}/bin/mkdir -p ${networkDir}

          ${lndinit} -v init-wallet \
            --file.seed=${seedFile} \
            --file.wallet-password=${pwFile} \
            --init-file.output-wallet-dir=${networkDir}

          ${pkgs.coreutils}/bin/ls -la ${networkDir}
          ${pkgs.coreutils}/bin/touch ${initMarker}
          echo "lnd-test: wallet init complete, marker written"
        else
          echo "lnd-test: wallet already initialized (marker present)"
        fi
      '';
      serviceConfig = {
        Type = "notify";
        ExecStart = "${pkgs.lnd}/bin/lnd --configfile=${configFile}";
        # The ReadWritePaths on StateDirectory gives us the dataDir.
        StateDirectory = "lnd-test";
        StateDirectoryMode = "0750";
        User = user;
        Group = group;
        TimeoutStartSec = "15min";
        Restart = "on-failure";
        RestartSec = "10s";
        # LND generates tls.cert very early (before wallet unlock) and
        # admin.macaroon shortly after. Chgrp both to the lnd-test group
        # so the admin user (member of that group) can use lncli-test.
        # tls.cert is chmod'd as soon as it appears; macaroon chmod
        # waits for the wallet to finish unlocking.
        ExecStartPost = pkgs.writeShellScript "lnd-test-perms" ''
          cert=${dataDir}/tls.cert
          mac=${networkDir}/admin.macaroon

          # tls.cert: relax perms immediately once LND has written it.
          for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
            if [ -f "$cert" ]; then
              ${pkgs.coreutils}/bin/chgrp ${group} "$cert" || true
              ${pkgs.coreutils}/bin/chmod 640 "$cert" || true
              break
            fi
            ${pkgs.coreutils}/bin/sleep 0.5
          done

          # admin.macaroon: appears after wallet unlock. Also unlock the
          # intermediate dirs so group traversal works.
          for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
            if [ -f "$mac" ]; then
              ${pkgs.coreutils}/bin/chgrp ${group} "$mac" || true
              ${pkgs.coreutils}/bin/chmod 640 "$mac" || true
              ${pkgs.coreutils}/bin/chmod g+rx \
                ${dataDir}/chain \
                ${dataDir}/chain/bitcoin \
                ${networkDir} || true
              exit 0
            fi
            ${pkgs.coreutils}/bin/sleep 0.5
          done
          # Best-effort; don't fail startup if macaroon isn't there yet.
          exit 0
        '';
      };
    };

    environment.systemPackages = [lncliTest];
  };
}
