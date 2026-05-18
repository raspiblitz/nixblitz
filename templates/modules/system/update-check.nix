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
      Periodic upstream-update check for the dashboard banner. Runs
      `nix flake update` + `nix build --dry-run` + `nvd diff` against
      the operator's `~/nixblitz/` in a tmpdir, then stages any
      candidate `flake.lock` + plugin pin moves at
      /var/lib/nixblitz-tui/staging/ so Apply can promote them.
      Daily timer; ~125 MB tarball traffic per run.
    '';
  };

  config = lib.mkIf cfg.enable {
    # Owned by admin so the timer-driven `nixblitz check`
    # invocations (run as User=admin) can write their results here.
    # `staging/` is provisioned with the same ownership so the
    # check service can drop candidate artifacts in without sudo.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 admin users -"
      "d ${stateDir}/staging 0755 admin users -"
    ];

    systemd.services.nixblitz-check = {
      description = "NixBlitz: probe upstream + stage candidate updates";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "admin";
        # Resolve nixblitz via the system PATH so the wrapper
        # picks up disko + git like an interactive shell would.
        ExecStart = "${pkgs.runtimeShell} -lc 'nixblitz check'";
        # The check pulls tarballs + evaluates a NixOS system —
        # 5-10 min on a Pi, ~1-2 min on x86. Cap so a stuck run
        # doesn't keep the timer locked indefinitely.
        TimeoutStartSec = "30min";
      };
    };

    systemd.timers.nixblitz-check = {
      description = "NixBlitz update check (daily)";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        # Spread up to 6h so simultaneous evaluations don't all
        # land on cache.nixos.org / nixos-raspberrypi.cachix.org
        # at the same minute.
        RandomizedDelaySec = "6h";
      };
    };
  };
}
