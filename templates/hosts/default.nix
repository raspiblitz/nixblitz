{...}: {
  # Back-compat shim for any external flake referrers that still target
  # ./hosts/default.nix. The flake's nixosConfigurations now point
  # directly at installer.nix (live ISO) and installed.nix (post-install)
  # — see ../flake.nix.
  imports = [./installed.nix];
}
