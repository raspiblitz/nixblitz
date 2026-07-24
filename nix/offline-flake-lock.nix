# Generates a fully path-locked templates/flake.lock inside a Nix build
# sandbox (no network). Every input in offlineInputs.overrides is force-
# resolved to a `type = "path"` store path already fetched by the ROOT
# flake's own lock — so `disko-install --flake` on the live ISO never tries
# to re-resolve anything from the network. A missed override here means
# `nix flake lock` tries to fetch that input for real, which fails loudly
# in the sandbox (no network) — that failure IS the offline-safety proof.
#
# Pattern mirrors clan-core's checks/flash/flake-module.nix `flashTestFlake`
# (nix-in-sandbox `nix flake lock --override-input ...` recipe), adapted
# because templates/flake.nix (unlike clan-core) isn't itself a git
# checkout — `nix flake lock` refuses to lock a bare directory that isn't
# inside a git work tree, so this stages one with a throwaway `git init`.
{
  pkgs,
  offlineInputs,
}:
pkgs.runCommand "nixblitz-offline-flake.lock"
{
  nativeBuildInputs = [pkgs.nix pkgs.git];
} ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"

  mkdir flake
  cp ${../templates/flake.nix} flake/flake.nix

  # nix flake lock requires the target to live inside a git work tree
  # (bare directories are rejected); a staged-but-uncommitted index is
  # sufficient, no commit needed.
  git -C flake init -q
  git -C flake add -A

  nix flake lock ./flake \
    --extra-experimental-features 'nix-command flakes' \
    --flake-registry "" \
    --store "$TMPDIR/store" \
    ${pkgs.lib.concatMapStringsSep " \\\n    "
    (o: "--override-input ${o.name} ${o.path}")
    offlineInputs.overrides}

  cp flake/flake.lock $out
''
