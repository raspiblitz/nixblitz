// GENERATED — do not edit. Run 'just gen-templates' to regenerate.
// Source: templates/

part of 'embedded_templates.dart';

const String _flake = r'''
{
  description = "NixBlitz node configuration";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-bitcoin = {
      url = "github:fort-nix/nix-bitcoin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixblitz = {
      url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
    };
    blitz-api = {
      url = "github:fusion44/blitz_api";
    };
    blitz-web = {
      # Tracks the branch with the nix packaging in place (pending PR
      # back to raspiblitz/raspiblitz-web). Once merged upstream this
      # can point at github:raspiblitz/raspiblitz-web directly.
      url = "github:fusion44/raspiblitz-web";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    nix-bitcoin,
    nixblitz,
    blitz-api,
    blitz-web,
  }: let
    inherit (nixpkgs) lib;

    excludedFiles = ["package.nix" "flake.nix"];

    findModules = dir: let
      entries = builtins.readDir dir;
      processEntry = name: type: let
        path = dir + "/${name}";
      in
        if type == "directory"
        then findModules path
        else if type == "regular" && lib.hasSuffix ".nix" name && !builtins.elem name excludedFiles
        then [path]
        else [];
    in
      lib.concatLists (lib.mapAttrsToList processEntry entries);

    # User-installed plugins (see docs/decisions/plugins.md D14).
    # Each plugin dir has its own plugin.nix (NixOS module) + config.json
    # (user-editable settings edited via the TUI Configure view).
    #
    # Plugin ABI: plugin.nix is a TWO-STAGE function:
    #   { pluginCfg ? {} }: { config, lib, pkgs, ... }: { … }
    # The outer stage receives the plugin's own config.json; the
    # inner is a standard NixOS module function. We deliver
    # pluginCfg via closure on the outer stage, NOT as a named arg
    # on the inner — because NixOS's module system routes every
    # named module-function arg through `_module.args.<name>`, and
    # that namespace is global: two plugins both declaring
    # `pluginCfg` as a module arg would collide with
    #   `_module.args.pluginCfg' is defined multiple times`.
    # Two-stage isolates each plugin's cfg inside its own closure.
    pluginModules = let
      pluginDirs = builtins.attrNames (builtins.readDir ./plugins);
      isPluginDir = name: let
        entries = builtins.readDir ./plugins;
        isDir = (entries.${name} or null) == "directory";
      in
        isDir && builtins.pathExists (./plugins + "/${name}/plugin.nix");
      mkPluginModule = name: let
        pluginPath = ./plugins + "/${name}/plugin.nix";
        configPath = ./plugins + "/${name}/config.json";
        cfg =
          if builtins.pathExists configPath
          then builtins.fromJSON (builtins.readFile configPath)
          else {};
      in
        # `import pluginPath` returns the outer function; calling it
        # with {pluginCfg = cfg} returns the inner module function
        # (no pluginCfg in that signature), which the module system
        # treats as a normal NixOS module.
        (import pluginPath) {pluginCfg = cfg;};
    in
      map mkPluginModule (builtins.filter isPluginDir pluginDirs);
  in {
    nixosModules.default = {
      imports =
        (findModules ./modules)
        ++ (
          if builtins.pathExists ./plugins
          then pluginModules
          else []
        )
        ++ [
          disko.nixosModules.default
          nix-bitcoin.nixosModules.default
          blitz-api.nixosModules.default
          blitz-web.nixosModules.default
        ];
    };

    nixosConfigurations.nixblitz = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {inherit nixblitz;};
      modules = [
        ./hosts/installed.nix
        self.nixosModules.default
      ];
    };

    # Live-ISO config used by `disko-install --flake .#nixblitz-installer`.
    # Identical to nixosConfigurations.nixblitz except for passwordless
    # sudo. See docs/decisions/plugins.md (sudo posture).
    nixosConfigurations.nixblitz-installer = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {inherit nixblitz;};
      modules = [
        ./hosts/installer.nix
        self.nixosModules.default
      ];
    };
  };
}
''';

const String _hardwarePi5 = r'''
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  hardware.enableRedistributableFirmware = true;
}
''';

const String _hardwareVm = r'''
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd = {
      availableKernelModules = ["ata_piix" "uhci_hcd" "virtio_pci" "floppy" "sr_mod" "virtio_blk"];
      kernelModules = [];
    };
    kernelModules = ["kvm-amd"];
    extraModulePackages = [];
  };

  disko.devices.disk.main = {
    device = lib.mkDefault "/dev/vda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot.loader.grub = {
    enable = true;
    devices = ["/dev/vda"];
  };

  swapDevices = [];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  services.qemuGuest.enable = true;
}
''';

const String _hardwareX86 = r'''
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  disko.devices.disk.main = {
    device = lib.mkDefault "/dev/sda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02";
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot.loader.grub.enable = true;
}
''';

const String _hostsDefault = r'''
{...}: {
  # Back-compat shim for any external flake referrers that still target
  # ./hosts/default.nix. The flake's nixosConfigurations now point
  # directly at installer.nix (live ISO) and installed.nix (post-install)
  # — see ../flake.nix.
  imports = [./installed.nix];
}
''';

const String _hostsInstalled = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = builtins.fromJSON (builtins.readFile ../config.json);
  sys = cfg.system;
  # Bootstrap gate: during initial install, `initialized` is false and all
  # services are forced off so disko-install builds a minimal system that
  # fits in the live ISO's tmpfs. After first-boot setup, `initialized`
  # flips to true and the real service configuration is built on the
  # installed system's disk (plenty of space).
  initialized = cfg.initialized or false;
in {
  imports = [
    ../hardware-configuration.nix
  ];

  networking.hostName = sys.hostname;
  time.timeZone = sys.timezone;

  features.system.base.enable = true;

  # Two background timers (daily light + weekly heavy) populate
  # ~/.local/state/nixblitz/update-status.json so the dashboard can
  # surface "X updates available" without the user kicking off a
  # rebuild. See templates/modules/system/update-check.nix.
  features.system.updateCheck.enable = initialized;

  # Disk layout — enable the appropriate disko config for the platform
  features.system.disko-vm.enable = sys.platform == "vm" || sys.platform == "x86";

  features.apps.bitcoind.enable = initialized && cfg.bitcoind.enabled;
  features.apps.bitcoind.network = cfg.bitcoind.network;
  features.apps.bitcoind.pruned = cfg.bitcoind.pruned;
  features.apps.bitcoind.pruneSizeGb = cfg.bitcoind.prune_size_gb;

  features.apps.lnd.enable = initialized && cfg.lnd.enabled;
  features.apps.lnd.alias = cfg.lnd.alias;

  features.apps.cln.enable = initialized && cfg.cln.enabled;

  features.apps.blitz-api.enable = initialized && cfg.blitz_api.enabled;
  features.apps.blitz-web.enable = initialized && cfg.blitz_web.enabled;

  # Grant admin access to bitcoin-cli / lncli / lightning-cli once services
  # are up. Needs at least one service enabled — nix-bitcoin.operator adds
  # the user to groups that only exist when the relevant service runs.
  features.system.operator.enable =
    initialized
    && (cfg.bitcoind.enabled || cfg.lnd.enabled || cfg.cln.enabled);

  # Test-LND: secondary regtest-only LND instance for opening channels
  # against the primary node and dry-running payments via `lncli-test`.
  # Auto-enabled whenever bitcoind is on regtest; off on any real network.
  features.system.testLnd.enable =
    initialized
    && cfg.bitcoind.enabled
    && cfg.bitcoind.network == "regtest";

  users.users.admin = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    initialPassword = "nixblitz";
  };

  # NixOS default: wheelNeedsPassword = true. The TUI authenticates
  # sudo via the SudoSession service (sudo -S -v + ~10 min keepalive),
  # so all privileged flows still work non-interactively after one
  # password prompt per session of activity.
  services.openssh.enable = true;

  system.stateVersion = "25.11";
}
''';

const String _hostsInstaller = r'''
{
  config,
  lib,
  pkgs,
  ...
}: {
  # Live ISO host config, used by `disko-install --flake .#nixblitz-installer`.
  # Differs from the installed system in exactly one place: passwordless sudo,
  # so the TUI's install-time wizard (disko-install, nixos-generate-config,
  # mount, cp, chown, …) can run non-interactively. The live ISO is
  # ephemeral and has no persistent attacker, so this is the right default
  # here. The installed system uses NixOS's wheelNeedsPassword=true default.
  imports = [./installed.nix];

  security.sudo.wheelNeedsPassword = false;
}
''';

const String _modulesAppsBitcoind = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.bitcoind;
in {
  options.features.apps.bitcoind = {
    enable = lib.mkEnableOption "Bitcoin daemon";
    network = lib.mkOption {
      # testnet / signet are parked until nix-bitcoin grows section-aware
      # config generation (top-level rpcbind/rpcport are rejected by
      # Bitcoin Core on non-main networks). See IDEAS.md.
      type = lib.types.enum ["mainnet" "regtest"];
      default = "mainnet";
      description = "Bitcoin network to connect to.";
    };
    pruned = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to prune the blockchain.";
    };
    pruneSizeGb = lib.mkOption {
      type = lib.types.int;
      default = 550;
      description = "Prune target size in GB (minimum 550).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.bitcoind = {
      enable = true;
      dataDir = "/mnt/data/bitcoind";
      regtest = cfg.network == "regtest";
      prune = if cfg.pruned then cfg.pruneSizeGb * 1000 else 0;
      # nix-bitcoin writes `[regtest]` and the regtest-scoped options
      # before our extraConfig, so anything here lands inside the
      # regtest section.
      extraConfig = lib.optionalString (cfg.network == "regtest") ''
        # Regtest has no real tx activity for bitcoind to infer fee
        # rates from; without a fallback, sendtoaddress / fundrawtx
        # refuse with "Fee estimation failed. Fallbackfee is disabled."
        # 0.0002 BTC/kvB ≈ 20 sat/vB, plenty for test flows.
        fallbackfee=0.0002
      '';
    };
  };
}
''';

const String _modulesAppsBlitzApi = r'''
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
''';

const String _modulesAppsBlitzWeb = r'''
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
''';

const String _modulesAppsCln = r'''
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
''';

const String _modulesAppsLnd = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.lnd;
in {
  options.features.apps.lnd = {
    enable = lib.mkEnableOption "Lightning Network Daemon (LND)";
    alias = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Node alias visible on the Lightning Network.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.lnd = {
      enable = true;
      dataDir = "/mnt/data/lnd";
      extraConfig = ''
        ${lib.optionalString (cfg.alias != "") "alias=${cfg.alias}"}
      '';
    };
  };
}
''';

const String _modulesSystemBase = r'''
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
''';

const String _modulesSystemDiskoVm = r'''
{
  config,
  lib,
  ...
}: let
  cfg = config.features.system.disko-vm;
in {
  options.features.system.disko-vm.enable = lib.mkEnableOption "VM disk layout (virtio, single ext4 partition)";

  config = lib.mkIf cfg.enable {
    disko.devices.disk.main = {
      device = lib.mkDefault "/dev/vda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "1M";
            type = "EF02";
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };

    # Note: disko automatically configures boot.loader.grub.devices
    # based on the disko.devices.disk.* definitions above. Setting it
    # explicitly here would cause a "duplicated devices in mirroredBoots" error.
    boot.loader.grub.enable = true;
  };
}
''';

const String _modulesSystemOperator = r'''
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
''';

const String _modulesSystemTestLnd = r'''
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
''';

const String _modulesSystemUpdateCheck = r'''
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.system.updateCheck;
  # Where the checker writes its result. The TUI dashboard banner
  # reads from this. Path mirrored in
  # `common/lib/src/models/update_status.dart` (`updateStatusPath`).
  stateDir = "/var/lib/nixblitz-tui";
in {
  options.features.system.updateCheck = {
    enable = lib.mkEnableOption ''
      Periodic upstream-update checks for the dashboard banner.
      Two timers: a daily lightweight one (GitHub/Forgejo HEAD via
      API; ~kB transfer) and a weekly heavy one (full
      `nix flake update` + `nvd diff` in a tmpdir; ~125 MB).
    '';
  };

  config = lib.mkIf cfg.enable {
    # Owned by admin so the timer-driven `nixblitz check ...`
    # invocations (run as User=admin) can write their results here.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 admin users -"
    ];

    systemd.services.nixblitz-check-light = {
      description = "NixBlitz: query upstream HEAD for each flake input";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "admin";
        # Resolve nixblitz via the system PATH so the wrapper
        # picks up disko + git like an interactive shell would.
        ExecStart = "${pkgs.runtimeShell} -lc 'nixblitz check light'";
      };
    };

    systemd.timers.nixblitz-check-light = {
      description = "NixBlitz lightweight update check (daily)";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        # Avoid every NixBlitz on the planet hitting GitHub at
        # exactly midnight — spread the load up to an hour.
        RandomizedDelaySec = "1h";
      };
    };

    systemd.services.nixblitz-check-heavy = {
      description = "NixBlitz: weekly nix flake update + nvd diff in tmpdir";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "admin";
        ExecStart = "${pkgs.runtimeShell} -lc 'nixblitz check heavy'";
        # Heavy check pulls tarballs + evaluates a NixOS system —
        # 5-10 min on a Pi, ~1-2 min on x86. Cap so a stuck run
        # doesn't keep a timer locked indefinitely.
        TimeoutStartSec = "30min";
      };
    };

    systemd.timers.nixblitz-check-heavy = {
      description = "NixBlitz heavy update check (weekly)";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        # Spread up to 6h so simultaneous evaluations don't
        # thrash binary caches.
        RandomizedDelaySec = "6h";
      };
    };
  };
}
''';

Map<String, String> _getAllTemplates() {
  return {
    'flake.nix': _flake,
    'hardware/pi5.nix': _hardwarePi5,
    'hardware/vm.nix': _hardwareVm,
    'hardware/x86.nix': _hardwareX86,
    'hosts/default.nix': _hostsDefault,
    'hosts/installed.nix': _hostsInstalled,
    'hosts/installer.nix': _hostsInstaller,
    'modules/apps/bitcoind.nix': _modulesAppsBitcoind,
    'modules/apps/blitz-api.nix': _modulesAppsBlitzApi,
    'modules/apps/blitz-web.nix': _modulesAppsBlitzWeb,
    'modules/apps/cln.nix': _modulesAppsCln,
    'modules/apps/lnd.nix': _modulesAppsLnd,
    'modules/system/base.nix': _modulesSystemBase,
    'modules/system/disko-vm.nix': _modulesSystemDiskoVm,
    'modules/system/operator.nix': _modulesSystemOperator,
    'modules/system/test-lnd.nix': _modulesSystemTestLnd,
    'modules/system/update-check.nix': _modulesSystemUpdateCheck,
  };
}
