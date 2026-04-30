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
      inputs.nixpkgs.follows = "nixpkgs";
    };
    blitz-api = {
      url = "github:fusion44/blitz_api";
      # CRITICAL on Pi 5: without this follows, blitz-api pulls
      # in its own pinned nixos-unstable, captures `pkgs` from
      # there at flake-eval time, and bakes a uv path into its
      # pyproject install hook that we can't override. With the
      # follows, blitz-api's eval uses our nixpkgs and our
      # uv override (in installed-pi5.nix's `nixpkgs.overlays`)
      # actually reaches the install hook. See the rule in
      # CLAUDE.md about always following nixpkgs on new inputs.
      inputs.nixpkgs.follows = "nixpkgs";
    };
    blitz-web = {
      # Tracks the branch with the nix packaging in place (pending PR
      # back to raspiblitz/raspiblitz-web). Once merged upstream this
      # can point at github:raspiblitz/raspiblitz-web directly.
      url = "github:fusion44/raspiblitz-web";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pi 5 isn't supported by upstream NixOS — vendor kernel + firmware
    # come from this third-party flake. Pinned to a tag so refreshes
    # are explicit; bump deliberately rather than tracking `main`.
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/v1.20260411.0";
      inputs.nixpkgs.follows = "nixpkgs";
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
    nixos-raspberrypi,
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

    # Read enough of the operator's config to know which platform
    # we're targeting. Used to alias `nixosConfigurations.${hostname}`
    # to the platform-correct build below — without it, a plain
    # `nixos-rebuild switch --flake .` defaults to
    # `.#${hostname}` and the Pi 5 case grabs the x86 attribute,
    # failing with `boot.loader.grub.devices` unset.
    blitzCfg =
      if builtins.pathExists ./config.json
      then builtins.fromJSON (builtins.readFile ./config.json)
      else {};
    blitzPlatform = blitzCfg.system.platform or "x86";
    blitzHostname = blitzCfg.system.hostname or "nixblitz";
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

    # Build the four canonical configurations as a separate
    # attrset, then merge in the hostname-keyed alias below. The
    # split is purely so the alias can overwrite an existing key
    # (e.g. operator's hostname is the default `nixblitz` on Pi
    # 5 — alias overrides the x86 build under that name) without
    # tripping Nix's "attribute already defined" error from two
    # static assignments to the same key.
    nixosConfigurations = let
      canonical = {
        nixblitz = nixpkgs.lib.nixosSystem {
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
        nixblitz-installer = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {inherit nixblitz;};
          modules = [
            ./hosts/installer.nix
            self.nixosModules.default
          ];
        };

        # Pi 5 build target. Use `nixos-raspberrypi.lib.nixosSystem`
        # (not `nixpkgs.lib.nixosSystem`) so the upstream's bootloader
        # / vendor-kernel / vendor-firmware / kernel-and-firmware
        # overlays are auto-applied. The opt-in `pkgs` overlay
        # (ffmpeg, kodi, etc.) is NOT applied — `nixosSystem` is the
        # node-friendly variant; `nixosSystemFull` would pull in the
        # media stack, which is wasted on a headless node.
        nixblitz-pi5 = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {inherit nixblitz nixos-raspberrypi;};
          modules = [
            ./hosts/installed-pi5.nix
            self.nixosModules.default
          ];
        };

        # Pi 5 install target. Used by
        # `disko-install --flake .#nixblitz-pi5-installer` from inside
        # the live image (typically the upstream
        # `nvmd/nixos-raspberrypi#installerImages.rpi5` flashed to a
        # USB stick). Differs from `nixblitz-pi5` only in
        # `installer-pi5.nix`'s passwordless sudo override; same
        # bootloader / kernel / firmware / disko layout.
        nixblitz-pi5-installer = nixos-raspberrypi.lib.nixosSystem {
          specialArgs = {inherit nixblitz nixos-raspberrypi;};
          modules = [
            ./hosts/installer-pi5.nix
            self.nixosModules.default
          ];
        };
      };

      # Hostname-keyed alias. NixOS rebuild defaults to
      # `${flake}#nixosConfigurations.${hostname}` when no `#attr`
      # is given; without this alias a Pi 5 system whose hostname
      # is the default `nixblitz` resolves to the x86 attribute
      # and fails with `boot.loader.grub.devices` unset. Aliasing
      # the hostname to the platform-correct build makes the bare
      # `sudo nixos-rebuild switch --flake .` (and the TUI's
      # update / apply paths that rely on the same default) DTRT
      # on every platform without the operator having to know the
      # `-pi5` attribute name.
      #
      # Default hostname `nixblitz` on x86: alias overwrites the
      # canonical `nixblitz` with the same value — no-op.
      # Default hostname `nixblitz` on Pi 5: alias overwrites the
      # canonical x86 `nixblitz` to point at the Pi 5 build —
      # exactly the footgun fix.
      # Custom hostname (e.g. `loki`) on either platform: alias
      # adds a new key pointing at the platform-correct build;
      # canonical names stay available for explicit `#nixblitz-*`.
      aliasTarget =
        if blitzPlatform == "pi5"
        then canonical.nixblitz-pi5
        else canonical.nixblitz;
    in
      canonical
      // {
        ${blitzHostname} = aliasTarget;
      };
  };
}
