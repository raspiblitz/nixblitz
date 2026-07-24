# Single source of truth mapping `templates/flake.nix`'s lock-node graph to
# the root flake's already-fetched input store paths. Consumed by:
#   - offline-flake-lock.nix (this task): generates a fully path-locked
#     templates/flake.lock at ISO build time so `disko-install --flake`
#     never touches the network.
#   - installer-system.nix (later task): needs the identical input set baked
#     into the ISO closure so the path-locked flake.lock's store-path
#     references actually resolve on the live medium (the "A==B keystone" —
#     the set of inputs we lock against MUST equal the set of inputs we bake).
#
# The node list below is the authoritative output of running
# `nix flake lock` against a pristine copy of templates/flake.nix (verified
# against templates/flake.nix's `inputs` block, cross-checked against this
# root flake's own `inputs`). Every node that is NOT a `follows` edge in that
# lock graph needs an explicit override here; `follows` edges resolve
# transitively through whatever node they point at and need no entry.
{
  self,
  nixos-raspberrypi,
  disko,
}: let
  # Minimal, dependency-free `unique` — avoids pulling in nixpkgs.lib just
  # for this one list dedup. NOTE: must not round-trip elements through
  # `listToAttrs`/`toString` as an attribute *name* — attribute names can't
  # carry Nix string context, and these elements are store-path strings
  # whose context is exactly what downstream consumers (isoImage.storeContents)
  # need; Nix refuses a name string that looks like a store path but lost its
  # context. `elem`-based membership checks preserve context on every
  # retained element instead.
  unique = builtins.foldl' (acc: x:
    if builtins.elem x acc
    then acc
    else acc ++ [x]) [];
in rec {
  # The exact input set templates/flake.nix's `outputs` function receives,
  # mirroring templates/flake.nix's own `inputs` block (nixpkgs follows
  # nvmd's nixpkgs; disko and nixos-raspberrypi are direct; nixblitz is
  # this very repo, published at forge.f44.fyi/f44/nixblitz_ng and pulled
  # back in by templates/flake.nix as a git+https input).
  templatesInputs = {
    nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
    inherit disko nixos-raspberrypi;
    nixblitz = self;
  };

  # Every non-follows node in templates/flake.lock's graph, mapped to the
  # root-flake store path that already holds identical (or override-
  # compatible) content. `nix flake lock --override-input <name> <path>`
  # takes dot-separated node paths exactly as they appear in the lock file's
  # node graph (see `templates/flake.lock` node names, or regenerate via
  # `nix flake lock` against a throwaway copy of templates/flake.nix).
  overrides = [
    # Top-level templates/flake.nix inputs.
    {
      name = "nixpkgs"; # follows nixos-raspberrypi/nixpkgs in flake.nix;
      # overridden explicitly anyway for a self-contained,
      # order-independent override list.
      path = nixos-raspberrypi.inputs.nixpkgs;
    }
    {
      name = "disko";
      path = disko;
    }
    {
      name = "nixos-raspberrypi";
      path = nixos-raspberrypi;
    }
    # nixos-raspberrypi's own transitive inputs (real nodes; nixos-images'
    # nixos-stable/nixos-unstable sub-nodes are follows and need no entry).
    {
      name = "nixos-raspberrypi/argononed";
      path = nixos-raspberrypi.inputs.argononed;
    }
    {
      name = "nixos-raspberrypi/flake-compat";
      path = nixos-raspberrypi.inputs.flake-compat;
    }
    {
      name = "nixos-raspberrypi/nixos-images";
      path = nixos-raspberrypi.inputs.nixos-images;
    }
    {
      name = "nixos-raspberrypi/nixpkgs";
      path = nixos-raspberrypi.inputs.nixpkgs;
    }
    # The `nixblitz` input in templates/flake.nix is this very repo
    # (git+https://forge.f44.fyi/f44/nixblitz_ng) — i.e. `self`.
    {
      name = "nixblitz";
      path = self;
    }
    # nixblitz's (= this repo's) own inputs, as seen through templates'
    # lock graph. nixblitz/nixpkgs is a follows (-> root nixpkgs) and
    # needs no entry; nixblitz/disko/nixpkgs likewise follows
    # nixblitz/nixpkgs.
    {
      name = "nixblitz/disko";
      path = self.inputs.disko;
    }
    {
      name = "nixblitz/flake-utils";
      path = self.inputs.flake-utils;
    }
    {
      name = "nixblitz/flake-utils/systems";
      path = self.inputs.flake-utils.inputs.systems;
    }
    {
      name = "nixblitz/nix-filter";
      path = self.inputs.nix-filter;
    }
    {
      name = "nixblitz/nixos-raspberrypi";
      path = self.inputs.nixos-raspberrypi;
    }
    # nixblitz/nixos-raspberrypi's transitive nodes — distinct lock nodes
    # from the top-level nixos-raspberrypi/* ones above (nixblitz pins its
    # own nixos-raspberrypi input independently; they happen to resolve to
    # the same tag today, but are separate nodes in the graph).
    {
      name = "nixblitz/nixos-raspberrypi/argononed";
      path = self.inputs.nixos-raspberrypi.inputs.argononed;
    }
    {
      name = "nixblitz/nixos-raspberrypi/flake-compat";
      path = self.inputs.nixos-raspberrypi.inputs.flake-compat;
    }
    {
      name = "nixblitz/nixos-raspberrypi/nixos-images";
      path = self.inputs.nixos-raspberrypi.inputs.nixos-images;
    }
    {
      name = "nixblitz/nixos-raspberrypi/nixpkgs";
      path = self.inputs.nixos-raspberrypi.inputs.nixpkgs;
    }
    {
      name = "nixblitz/nixpkgs-unstable";
      path = self.inputs.nixpkgs-unstable;
    }
    {
      name = "nixblitz/nixpkgs-vanilla-unstable";
      path = self.inputs.nixpkgs-vanilla-unstable;
    }
  ];

  # Convenience for later tasks (e.g. installer-system.nix's baked closure):
  # every distinct store path referenced by `overrides`, deduplicated.
  sourcePaths = unique (map (o: o.path.outPath or o.path) overrides);
}
