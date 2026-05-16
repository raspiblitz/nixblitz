# NixOS module: services.nixblitz-cachepop
#
# Wires the cachepop binary into a systemd service+timer pair on a
# build host. The build host is expected to be a beefy x86 box with
# `boot.binfmt.emulatedSystems = ["aarch64-linux"];` set so it can
# compile the Pi 5 closure transparently.
#
# Usage in a consumer flake (the build host's NixOS config):
#
#   {
#     inputs.nixblitz.url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
#     outputs = inputs: {
#       nixosConfigurations.buildhost = inputs.nixpkgs.lib.nixosSystem {
#         modules = [
#           inputs.nixblitz.nixosModules.cachepop
#           {
#             services.nixblitz-cachepop = {
#               enable = true;
#               atticCache = "f44:nixblitz";
#               atticEndpoint = "https://attic.f44.fyi/";
#               atticTokenFile = "/run/secrets/cachepop-token";
#               targets = [
#                 { name = "pi5-mainnet"; flakeAttr = "nixblitz-pi5";
#                   platform = "pi5";
#                   plugins = ["bitcoind" "lnd" "blitz-api"]; }
#               ];
#             };
#           };
#         ];
#       };
#     };
#   }
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixblitz-cachepop;

  # Each target is shaped as a submodule so option type-checking
  # catches typos / missing fields at eval time instead of failing
  # mid-build inside cachepop.
  targetType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Per-target identifier; used as the state-dir subdirectory.";
      };
      flakeAttr = lib.mkOption {
        type = lib.types.str;
        description = "nixosConfigurations attribute to build (e.g. nixblitz-pi5).";
      };
      platform = lib.mkOption {
        type = lib.types.enum ["x86" "pi5"];
        description = "Platform the target is built for. Threaded into `nixblitz init`.";
      };
      plugins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["bitcoind" "lnd" "blitz-api" "blitz-web" "lnbits" "tailscale"];
        description = ''
          Plugin ids to install via `nixblitz plugin add` during bootstrap.
          Each id resolves to
          `forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/<id>`.
          Without plugins, the resulting closure is a bare nixblitz system
          with no Bitcoin/Lightning stack — useful for testing module
          eval, useless for populating a real cache.
        '';
      };
    };
  };

  # Render the cachepop config JSON to a store path. The systemd unit
  # points at it via --config; the same file is symlinked to
  # /etc/nixblitz-cachepop/config.json so the operator running
  # `cachepop status` etc. from their shell hits it via default
  # lookup. No secrets land here, so store-path visibility is fine.
  cachepopConfig = pkgs.writeText "cachepop-config.json" (builtins.toJSON {
    stateDir = cfg.stateDir;
    atticCache = cfg.atticCache;
    atticEndpoint = cfg.atticEndpoint;
    nixCores = cfg.cpuCores;
    nixMaxJobs = cfg.maxJobs;
    targets = cfg.targets;
  });

  cachepopPkg = self.packages.${pkgs.system}.cachepop;
in {
  options.services.nixblitz-cachepop = {
    enable = lib.mkEnableOption "the nixblitz Attic cache populator";

    user = lib.mkOption {
      type = lib.types.str;
      default = "cachepop";
      description = "System user the service runs as. Created if absent.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/nixblitz-cachepop";
      description = "Per-target profile dirs and status.json live here.";
    };

    atticCache = lib.mkOption {
      type = lib.types.str;
      example = "f44:nixblitz";
      description = "Attic cache identifier passed to `attic push`.";
    };

    atticEndpoint = lib.mkOption {
      type = lib.types.str;
      example = "https://attic.f44.fyi/";
      description = "Attic server endpoint URL.";
    };

    atticTokenFile = lib.mkOption {
      type = lib.types.path;
      example = "/run/secrets/cachepop-token";
      description = ''
        Path to a file containing the attic push token. Rendered into
        `~cachepop/.config/attic/config.toml` at service pre-start
        using attic's `token-file` config form (see
        `ServerTokenConfig::File`). The token itself never enters
        the nix store.
      '';
    };

    enableTimer = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to install a systemd timer that fires the service on
        [schedule]. Set to `false` for manual-only operation on a
        workstation that's actively used — the service unit is still
        installed and can be triggered with
        `systemctl start nixblitz-cachepop.service` when convenient.
      '';
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      example = "*-*-* 04:00:00";
      description = ''
        systemd OnCalendar expression for the build timer. Only
        honoured when [enableTimer] is true.
      '';
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1800;
      description = "Random jitter on each timer fire to spread upstream load.";
    };

    cpuCores = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      example = 12;
      description = ''
        Per-derivation parallelism cap for `nix build` (passed via
        `--cores`). `0` (the nix default) lets each derivation use
        every core the box has; positive values leave headroom so
        the operator's interactive use isn't starved.

        Also drives the service unit's `CPUQuota` hard cap at the
        cgroup level. e.g. `cpuCores = 12` on a 16-core box yields
        `CPUQuota=1200%` — even if a runaway subprocess ignores
        `--cores`, the kernel scheduler caps the cgroup.
      '';
    };

    maxJobs = lib.mkOption {
      type = lib.types.either lib.types.ints.unsigned (lib.types.enum ["auto"]);
      default = 1;
      description = ''
        `--max-jobs` value for `nix build`. Default `1` runs one
        derivation at a time, so [cpuCores] is the true ceiling on
        CPU pressure (otherwise total ≈ cores × max-jobs, and the
        daemon happily floods all cores). `"auto"` lets nix size to
        `nproc` — useful on a dedicated build host but the wrong
        default for the workstation-with-other-work shape this
        module is designed for. As a bonus, single-derivation
        builds keep `cachepop logs -f` readable; parallel
        derivations interleave their output into noise.
      '';
    };

    autoBootstrap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run `cachepop init` for each configured target on service
        pre-start if its profile dir is absent. Disable if you want
        to hand-bootstrap (e.g. for a stage-by-stage rollout).
      '';
    };

    targets = lib.mkOption {
      type = lib.types.listOf targetType;
      default = [];
      description = "Targets to build and push.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.targets != [];
        message = "services.nixblitz-cachepop.targets must list at least one target.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.stateDir;
      createHome = false; # StateDirectory handles it
      # A real shell is required for `sudo -u cachepop cachepop …`
      # to work: the CLI auto-elevates from the operator's
      # interactive user when it detects the stateDir is owned by a
      # different uid, otherwise libgit2's safe.directory check
      # blocks `nix build` from reading the per-target flake repo.
      # `nologin` would refuse the sudo target outright.
      shell = pkgs.bashInteractive;
    };
    users.groups.${cfg.user} = {};

    # Cachepop drives `nix build` / `nix flake update`, both of which
    # need the user to be trusted so the script can pass --extra-
    # substituters / --extra-trusted-public-keys without prompting.
    # mkAfter so the operator's own trusted-users list takes precedence
    # in ordering (additive — both are appended).
    nix.settings.trusted-users = lib.mkAfter [cfg.user];

    systemd.services.nixblitz-cachepop = {
      description = "nixblitz Attic cache populator";
      after = ["network-online.target"];
      wants = ["network-online.target"];

      path = [cachepopPkg];

      preStart = let
        # Token-file rendering: write a per-target server entry into
        # config.toml at service start. Keeps the secret out of the
        # nix store (only the *path* to the secret is in the rendered
        # file).
        renderAtticConfig = pkgs.writeShellScript "render-attic-config" ''
          set -euo pipefail
          conf_dir="${cfg.stateDir}/.config/attic"
          mkdir -p "$conf_dir"
          umask 077
          cat > "$conf_dir/config.toml" <<EOF
          default-server = "${builtins.head (lib.splitString ":" cfg.atticCache)}"

          [servers."${builtins.head (lib.splitString ":" cfg.atticCache)}"]
          endpoint = "${cfg.atticEndpoint}"
          token-file = "${cfg.atticTokenFile}"
          EOF
        '';
      in ''
        ${renderAtticConfig}
        ${lib.optionalString cfg.autoBootstrap (
          lib.concatMapStringsSep "\n" (t: ''
            if [ ! -f "${cfg.stateDir}/targets/${t.name}/home/nixblitz/config.json" ]; then
              echo "cachepop: bootstrapping ${t.name}"
              ${cachepopPkg}/bin/cachepop --config ${cachepopConfig} init ${t.name} \
                --flake-attr ${t.flakeAttr} \
                --platform ${t.platform} \
                ${lib.optionalString (t.plugins != [])
              "--plugins ${lib.concatStringsSep "," t.plugins}"}
            fi
          '')
          cfg.targets
        )}
      '';

      serviceConfig =
        {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.user;
          StateDirectory = "nixblitz-cachepop";
          Environment = [
            "HOME=${cfg.stateDir}"
            "XDG_CONFIG_HOME=${cfg.stateDir}/.config"
          ];
          ExecStart = "${cachepopPkg}/bin/cachepop --config ${cachepopConfig} sync";

          # Yield to interactive use. The service is long-running,
          # CPU-heavy, and runs on a workstation the operator is also
          # using. Nice 10 + best-effort IO priority 7 lets the
          # kernel's scheduler de-prioritise the build whenever the
          # operator (or their browser, etc.) wants CPU/IO.
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;

          # Hardening — leans toward conservative because the unit needs
          # to talk to nix-daemon (writable nix store via daemon socket,
          # not direct), spawn `nix build`, and read the token file.
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ReadWritePaths = [cfg.stateDir];
          ReadOnlyPaths = [cfg.atticTokenFile];
          LockPersonality = true;
          RestrictRealtime = true;
          # NoNewPrivileges intentionally NOT set: nix-daemon comms
          # work, but if a future build step needs setuid (unlikely
          # given we're not running setuid binaries here), this would
          # need re-evaluating.
        }
        # cgroup-level CPU cap. Only set when cpuCores > 0; the nix
        # default (use everything) maps to "no cap". 100% per core,
        # so 12 cores = "1200%".
        // lib.optionalAttrs (cfg.cpuCores > 0) {
          CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        };
    };

    systemd.timers = lib.mkIf cfg.enableTimer {
      nixblitz-cachepop = {
        description = "Periodic timer for nixblitz Attic cache population";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.schedule;
          RandomizedDelaySec = cfg.randomizedDelaySec;
          Persistent = true; # catch up if the host was down at scheduled fire
          Unit = "nixblitz-cachepop.service";
        };
      };
    };

    environment.systemPackages = [cachepopPkg];

    # Stable lookup path for the cachepop CLI when invoked from any
    # shell (`cachepop status`, `cachepop logs`, etc.). The script's
    # config-search order ends at `/etc/nixblitz-cachepop/config.json`;
    # this lands the same rendered JSON the service unit uses.
    environment.etc."nixblitz-cachepop/config.json".source = cachepopConfig;
  };
}
