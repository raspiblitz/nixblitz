# The minimal installer-system closure, baked into the installer ISO
# (nix/iso.nix `isoImage.storeContents`) so disko-install runs offline — every
# leaf package it needs is already in the live medium's /nix/store.
#
# Unlike the old parallel eval this file used to do (its own
# `nixpkgs.lib.nixosSystem` call + a duplicated `findModules` + a
# hand-assembled profile dir), this now evaluates THROUGH
# `templates/flake.nix`'s own `outputs` function — the exact same function
# `disko-install --flake ~/nixblitz#nixblitz-installer` evaluates on the live
# ISO. That parallel eval produced a closure ("closure A") that could
# silently diverge from the real install-time closure ("closure B"): a
# module added to templates/flake.nix's `nixosModules.default` wiring, or a
# change to how `nixosConfigurations.nixblitz-installer` is assembled, would
# show up in B but never in A, defeating the whole point of baking a closure
# offline. Evaluating through the real outputs function makes A == B by
# construction.
#
# This is IFD (import-from-derivation) — the `fixtureDir` runCommand must
# build before `templatesFlake.outputs` can be evaluated. That's acceptable
# here: it's forced only when producing image outputs (installer-iso,
# pi5-installer-image), not on every eval of the root flake.
#
# `nixblitz-installer` (inside templates/flake.nix) reads `./config.json`
# and (transitively, via hosts/installed.nix) imports
# `./hardware-configuration.nix`, both generated per-machine at install and
# absent from source. We assemble a fixture flake directory — a full copy of
# `templates/` plus the committed test fixture config.json (forced
# `initialized = false`, same as before) and an empty
# hardware-configuration.nix fixture — so those sibling reads resolve.
# `initialized = false` is the bootstrap-gate state disko-install actually
# builds (all services off), which is exactly the closure the install needs
# and keeps the bake small.
#
# Representative, not byte-exact: the real install uses the operator's
# hardware config, so the final per-machine system derivation builds locally
# at install time — offline, because its leaves are baked. A forced leaf
# rebuild (e.g. a kernel rebuild) is an accepted offline-miss.
{
  self,
  disko,
  nixos-raspberrypi,
  system ? "x86_64-linux",
}: let
  offlineInputs = import ./offline-inputs.nix {inherit self nixos-raspberrypi disko;};
  inherit (offlineInputs.templatesInputs) nixpkgs;

  pkgs = nixpkgs.legacyPackages.${system};
  lib = nixpkgs.lib;

  installerConfig =
    (lib.importJSON ../tests/config/fixtures/base/config.json)
    // {initialized = false;};

  # Full copy of templates/ plus the fixture config.json +
  # hardware-configuration.nix, so templates/flake.nix's own
  # `./config.json` read and hosts/installed.nix's `../hardware-configuration.nix`
  # import both resolve inside the fixture dir, exactly like they resolve
  # against the operator's real ~/nixblitz at install time.
  fixtureDir = pkgs.runCommand "nixblitz-installer-fixture" {} ''
    mkdir -p $out
    cp -r ${../templates}/. $out/
    cp ${pkgs.writeText "config.json" (builtins.toJSON installerConfig)} $out/config.json
    cp ${../tests/config/fixtures/base/hardware-configuration.nix} $out/hardware-configuration.nix
  '';

  templatesFlake = import (fixtureDir + "/flake.nix");

  # Fix-point: templates/flake.nix's `outputs` takes `self` as an argument
  # (used for `self.nixosModules.default` and, transitively, `self.inputs`
  # is NOT used — `nixblitz` is passed as its own input below). We tie the
  # knot the same way `nix flake` itself does: `self` is the eventual
  # result of calling `outputs`, with `outPath` pointed at the fixture dir
  # so any `./relative` reads inside the templates flake resolve there.
  outputs = let
    result =
      templatesFlake.outputs (offlineInputs.templatesInputs
        // {
          self = result // {outPath = fixtureDir;};
        });
  in
    result;

  installerSystem = outputs.nixosConfigurations.nixblitz-installer;
in {
  toplevel = installerSystem.config.system.build.toplevel;
  diskoScript = installerSystem.config.system.build.diskoScript;
}
