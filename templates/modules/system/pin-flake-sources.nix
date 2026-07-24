# Pin the flake input SOURCE trees into the system closure so the
# path-locked flake.lock written by the offline installer keeps
# resolving forever: disko-install copies these to the target, each
# generation pins the sources it was built from, GC frees old ones
# with old generations. ~250-300 MB. See the offline-installer spec §4.3.
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
