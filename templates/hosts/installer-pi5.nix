{
  config,
  lib,
  pkgs,
  ...
}: {
  # Live-image host config for Pi 5, used by
  # `disko-install --flake .#nixblitz-pi5-installer`. Mirrors
  # `installer.nix`: identical to the installed system except for
  # passwordless sudo so the install wizard's privileged steps
  # (disko-install, nixos-generate-config, mount, cp, …) run
  # non-interactively. The booted live image is ephemeral; the
  # installed system inherits NixOS's `wheelNeedsPassword=true`
  # default.
  imports = [./installed-pi5.nix];

  security.sudo.wheelNeedsPassword = false;
}
