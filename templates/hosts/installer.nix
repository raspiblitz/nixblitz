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
