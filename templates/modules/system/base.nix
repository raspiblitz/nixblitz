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

      # NixBlitz's binary cache. Layered with `extra-` so the
      # operator's existing substituters (cache.nixos.org from
      # nixpkgs defaults, nixos-raspberrypi.cachix.org from the Pi
      # 5 vendor flake) stay intact.
      #
      # Baked into system nix.conf rather than relying solely on
      # `templates/flake.nix`'s `nixConfig.extra-substituters`,
      # because flake-level config is silently ignored when
      # `accept-flake-config = false` (the upstream default) — even
      # for trusted users on some nix builds. System-level
      # substituters work uniformly across every nix invocation:
      # nixos-rebuild, plain `nix build`, `nix-store --realise`,
      # and post-install nix-daemon work during plugin installs.
      #
      # If you ever want to opt OUT (e.g. run nixblitz against your
      # own private cache), `nix.settings.extra-substituters =
      # lib.mkForce [...];` in your host config wins.
      extra-substituters = ["https://attic.f44.fyi/nixblitz"];
      extra-trusted-public-keys = [
        "nixblitz:u7XgfZdWeXp1ilOIlzKzQbxWZZg9r2rVU0VBaffHtbw="
      ];
    };

    environment.systemPackages = with pkgs; [
      git
      jujutsu
      htop
      btop
      tree
      jq
      bat
      fd
      ripgrep
      neovim
      yazi
      systemctl-tui
      # Used by the TUI's Update view to render a per-package
      # version diff (`[U.] bitcoind 27.1, 27.2`) between the
      # running system and the dry-built next generation. Tiny
      # closure; also useful at the shell.
      nvd
      # sbomnix generates the CycloneDX SBOM (`sbom.cdx.json`) the TUI commits
      # after every successful rebuild — the node's package-version changelog.
      # It is baked in (rather than fetched via `nix run`) ON PURPOSE: an SBOM
      # failure now *blocks* the Apply commit (strict commit-on-success), so the
      # tool must be reliably present, including offline. CLOSURE-SIZE TRADE: it
      # pulls in sbomnix + its Python deps (~tens of MB on disk). That cost is
      # accepted for the reliability of a commit-blocking dependency; if it ever
      # becomes a problem, the alternatives are (a) make the SBOM best-effort
      # again and revert to `nix run nixpkgs#sbomnix`, or (b) gate it behind an
      # opt-in option. See docs/superpowers/specs/2026-06-28-sbom-version-tracking-design.md.
      sbomnix
      # Both shells are kept available regardless of the
      # `defaultUserShell` choice — operators flipping the option
      # via Configure shouldn't have to wait on a new closure
      # fetch, and a `nu` / `bash` invocation from a script keeps
      # working.
      bashInteractive
      nushell
      # ghostty terminfo for operators SSHing from a ghostty host —
      # without it, TERM=xterm-ghostty triggers "unknown terminal"
      # warnings from ncurses-using tools (htop, nvim, less). Tiny
      # closure; safe to ship as a default. Should move into the
      # operator-declared `extra_packages` list once #39 lands.
      ghostty.terminfo
      nixblitz.packages.${pkgs.system}.nixblitz-unwrapped
    ];

    users.defaultUserShell =
      if cfg.shell == "nushell"
      then pkgs.nushell
      else pkgs.bashInteractive;

    # Auto-launch the NixBlitz TUI on the first interactive login of
    # a session. Two snippets — one for each supported shell — both
    # installed unconditionally so a Configure → system → shell flip
    # works on the next login without re-activating the system. Only
    # the active shell sources its file.
    #
    # `NIXBLITZ_AUTOLAUNCHED` prevents recursion: nixblitz spawns
    # subshells (e.g. password change runs `chpasswd`) that would
    # otherwise re-trigger the auto-launch from inside themselves.
    # The bash variant additionally guards on `-t 0` / `-t 1` so
    # non-TTY contexts (`ssh admin@host nixos-rebuild switch`, cron,
    # build scripts) don't drop into the TUI. nushell's login.nu
    # only fires on login shells so the SSH-with-command path skips
    # naturally there.
    environment.etc."nixblitz/auto-launch.sh".text = ''
      if [ -z "''${NIXBLITZ_AUTOLAUNCHED:-}" ] && [ -t 0 ] && [ -t 1 ] \
          && command -v nixblitz >/dev/null 2>&1; then
        export NIXBLITZ_AUTOLAUNCHED=1
        nixblitz
      fi
    '';

    environment.etc."nixblitz/auto-launch.nu".text = ''
      if ($env.NIXBLITZ_AUTOLAUNCHED? | default "") == "" {
        $env.NIXBLITZ_AUTOLAUNCHED = "1"
        if (which nixblitz | length) > 0 {
          nixblitz
        }
      }
    '';

    programs.bash.interactiveShellInit = ''
      [ -r /etc/nixblitz/auto-launch.sh ] && . /etc/nixblitz/auto-launch.sh
    '';

    # NixOS has no `programs.nushell` module, so wire nushell up by
    # symlinking the system snippet into the admin user's config dir.
    # `login.nu` is nushell's analogue to `/etc/profile` — runs once
    # at login, not on every interactive `nu` subshell. The `d` rules
    # ensure the parent dirs exist; `L+` overwrites any existing
    # symlink so re-activations stay idempotent.
    systemd.tmpfiles.rules = [
      "d /home/admin/.config 0755 admin users -"
      "d /home/admin/.config/nushell 0755 admin users -"
      "L+ /home/admin/.config/nushell/login.nu - admin users - /etc/nixblitz/auto-launch.nu"
    ];
  };
}
