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

  # Generic helpers for the v18 app_configs shape.
  # `apps` is the map of app-name → config-map from config.json.
  apps = cfg.app_configs or {};

  # Read a single option from apps.<name>.<key>, falling back to `default`
  # when the app entry or the key is absent.
  appOpt = name: key: default: let
    m = apps.${name} or {};
  in
    m.${key} or default;

  # An app is active only when the system has been initialized AND the app's
  # own `enabled` flag is true.
  appEnabled = name: initialized && (appOpt name "enabled" false);
in {
  imports = [
    ../hardware-configuration.nix
  ];

  networking.hostName = sys.hostname;
  time.timeZone = sys.timezone;

  features.system.base.enable = true;
  # Operator's choice of login shell. Older configs (pre-v16) don't
  # have the field — fall back to bash, the new default.
  features.system.base.shell = sys.shell or "bash";

  # Two background timers (daily light + weekly heavy) populate
  # ~/.local/state/nixblitz/update-status.json so the dashboard can
  # surface "X updates available" without the user kicking off a
  # rebuild. See templates/modules/system/update-check.nix.
  features.system.updateCheck.enable = initialized;

  # Disk layout — enable the appropriate disko config for the platform.
  # `disk_device` carries the operator's choice from the install wizard
  # forward to subsequent rebuilds; without it, post-install rebuilds
  # default the disko `device` to `/dev/vda` and grub-install fails on
  # bare metal where the disk is `/dev/sda`. Empty string falls back to
  # the disko module's per-platform default for VMs that pre-date the
  # field.
  features.system.disko-x86.enable = sys.platform == "vm" || sys.platform == "x86";
  features.system.disko-x86.device =
    if (sys.disk_device or "") != ""
    then sys.disk_device
    else "/dev/vda";
  features.system.disko-pi5.enable = sys.platform == "pi5";

  features.apps.bitcoind.enable = appEnabled "bitcoind";
  features.apps.bitcoind.network = appOpt "bitcoind" "network" "mainnet";
  features.apps.bitcoind.pruned = appOpt "bitcoind" "pruned" false;
  features.apps.bitcoind.pruneSizeGb = appOpt "bitcoind" "prune_size_gb" 0;

  features.apps.lnd.enable = appEnabled "lnd";
  features.apps.lnd.alias = appOpt "lnd" "alias" "";

  features.apps.cln.enable = appEnabled "cln";

  # blitz-api is no longer a built-in app — it lives as a plugin
  # (forge.f44.fyi/f44/nixblitz-plugin-blitz-api). Operator runs
  # `nixblitz plugin add ...` (or [i] in the TUI) to install it.
  features.apps.blitz-web.enable = appEnabled "blitz_web";

  # Grant admin access to bitcoin-cli / lncli / lightning-cli once services
  # are up. Needs at least one service enabled — nix-bitcoin.operator adds
  # the user to groups that only exist when the relevant service runs.
  features.system.operator.enable =
    (appEnabled "bitcoind") || (appEnabled "lnd") || (appEnabled "cln");

  # Test-LND: secondary regtest-only LND instance for opening channels
  # against the primary node and dry-running payments via `lncli-test`.
  # Auto-enabled whenever bitcoind is on regtest; off on any real network.
  features.system.testLnd.enable =
    (appEnabled "bitcoind")
    && (appOpt "bitcoind" "network" "mainnet") == "regtest"
    && (appEnabled "lnd");

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
