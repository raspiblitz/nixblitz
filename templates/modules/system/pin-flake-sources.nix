# Pin the flake input SOURCE trees into the system closure so the
# path-locked flake.lock written by the offline installer keeps
# resolving forever: disko-install copies these to the target, each
# generation pins the sources it was built from, GC frees old ones
# with old generations. ~600 MB — the COMPLETE offline lock graph
# (every `type = "path"` node), dominated by the three nixpkgs snapshots
# (stable + the two unstable forks, ~200 MB each). See the
# offline-installer spec §4.3.
#
# Completeness is not optional. `flakeInputs` (templates/flake.nix's
# `pinnedFlakeInputs`) must mirror the offline lock graph node-for-node:
# first-boot eval of the path-locked `~/nixblitz` forces the FULL
# transitive source set (nixblitz.packages -> root outputs ->
# flake-utils.lib.eachDefaultSystem -> flake-utils -> its `systems`
# input; nix-filter; both unstable nixpkgs; nixos-raspberrypi's
# argononed/flake-compat/nixos-images). Any node the ISO bakes but this
# pin omits is absent on the installed node and bricks first boot offline
# with `path '/nix/store/…-source' does not exist` — the `systems`
# (nix-systems/default) incident. attrValues pins whatever it's given;
# the completeness guarantee lives at the call site.
{
  lib,
  flakeInputs ? null,
  ...
}: {
  config = lib.mkIf (flakeInputs != null) {
    environment.etc."nixblitz/flake-inputs".text =
      lib.concatMapStrings (p: "${p}\n") (lib.attrValues flakeInputs);
  };
}
