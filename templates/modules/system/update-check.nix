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
