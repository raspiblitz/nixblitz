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
}: let
  # The store path the `nixblitz` node MUST lock to — the content-addressed
  # stamped source (offline-inputs.nix's `stampedSelf`). Pulled from the same
  # override list the lock is generated from, so bake and lock can never drift.
  expectedNixblitzPath =
    (builtins.head
      (builtins.filter (o: o.name == "nixblitz") offlineInputs.overrides))
    .path;

  # Every store path the ISO actually bakes (offline-inputs.nix's
  # deduplicated source set). The lock-wide assert below checks that EVERY
  # `type = "path"` node in the generated lock resolves to one of these — a
  # node pointing at anything the ISO doesn't carry would die on first boot
  # offline with "path does not exist".
  bakedSourcePaths =
    pkgs.lib.concatStringsSep "\n"
    (map (p: p.outPath or p) offlineInputs.sourcePaths);
in
  pkgs.runCommand "nixblitz-offline-flake.lock"
  {
    nativeBuildInputs = [pkgs.nix pkgs.git pkgs.jq];
    inherit expectedNixblitzPath bakedSourcePaths;
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
      ${pkgs.lib.concatMapStringsSep " \\\n      "
      (o: "--override-input ${o.name} ${o.path}")
      offlineInputs.overrides}

    # Self-assert: the generated lock's `nixblitz` node MUST point at the very
    # stamped source path we baked into the ISO closure. If a content-stamp
    # regression (or any future change) let these diverge, a cross-eval mix
    # would break first boot with "path does not exist" — so make it a loud
    # ISO-build failure right here instead.
    lockedNixblitzPath=$(jq -r '.nodes.nixblitz.locked.path' flake/flake.lock)
    if [ "$lockedNixblitzPath" != "$expectedNixblitzPath" ]; then
      echo "offline lock's nixblitz node diverged from the baked source —" >&2
      echo "cross-eval mix would break first boot ('path does not exist')." >&2
      echo "  expected (baked stampedSelf): $expectedNixblitzPath" >&2
      echo "  got (locked in flake.lock):   $lockedNixblitzPath" >&2
      exit 1
    fi

    # Lock-wide completeness assert: EVERY path node the lock references must
    # be a source the ISO bakes. The nixblitz-specific check above is the
    # highest-signal special case; this generalizes it to the whole graph so a
    # future unpinned transitive node (the `systems` field failure) can't slip
    # through — first-boot eval forces the full transitive source set, and any
    # node absent from the baked closure bricks the node offline.
    printf '%s\n' "$bakedSourcePaths" > "$TMPDIR/baked-paths"
    jq -r '
      .nodes | to_entries[]
      | select(.value.locked.type == "path")
      | "\(.key) \(.value.locked.path)"
    ' flake/flake.lock > "$TMPDIR/path-nodes"

    lockAssertFail=0
    while read -r node path; do
      [ -z "$node" ] && continue
      if ! grep -Fxq "$path" "$TMPDIR/baked-paths"; then
        echo "offline lock node '$node' -> '$path'" >&2
        echo "  references a source the ISO doesn't bake" >&2
        echo "  (missing from offlineInputs.sourcePaths) — first boot would" >&2
        echo "  die offline with 'path does not exist'." >&2
        lockAssertFail=1
      fi
    done < "$TMPDIR/path-nodes"
    if [ "$lockAssertFail" -ne 0 ]; then
      exit 1
    fi

    cp flake/flake.lock $out
  ''
