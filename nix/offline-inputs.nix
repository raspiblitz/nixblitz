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
  # Host platform the stamped source copy (below) is built for. Threaded from
  # every call site (root flake.nix's per-system blocks, installer-system.nix,
  # pi5-installer-system.nix) so `stampedSelf` resolves to ONE store path per
  # platform — see the note on `pkgs` below for why that identity is
  # load-bearing.
  system ? "x86_64-linux",
}: let
  # The stamped-source `runCommand` builds against the SAME nixpkgs the
  # templates flake locks against (nixos-raspberrypi's pinned rev, = the
  # `nixpkgs` in templatesInputs below), NOT the root flake's nixpkgs. That
  # keeps `stampedSelf` byte-identical across every call site that imports
  # this file: if root flake.nix built it with nixos-25.11 coreutils while
  # installer-system.nix built it with the raspberrypi nixpkgs, the baked
  # closure's nixblitz would be compiled from one copy while the path-locked
  # lock pointed at the other — the exact drv divergence this whole mechanism
  # exists to prevent.
  pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.${system};
  lib = pkgs.lib;

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

  # Real metadata-derived version suffix, computed HERE at bake time from the
  # ROOT flake's `self` — which still carries `rev`/`dirtyShortRev` +
  # `lastModifiedDate`. This mirrors flake.nix's own metadata-fallback
  # expression EXACTLY (`${lastModifiedDate}-${shortRev|dirtyShortRev}`); the
  # two must stay in lockstep or the assert below fires.
  gitHash = self.shortRev or self.dirtyShortRev or "unknown";
  flakeDate = self.lastModifiedDate or "0";
  versionStamp = "${flakeDate}-${gitHash}";

  # Content-borne version stamp: a copy of the ROOT source with the real
  # metadata suffix written into `.nixblitz-version-stamp`. Path-locking
  # preserves content perfectly but drops flake metadata, so on the live
  # medium the `nixblitz` input has no rev/lastModified — flake.nix's version
  # block would otherwise compute a DIFFERENT derivationVersion than this
  # baked closure and rebuild the TUI from source (fatal offline). With the
  # stamp file present, that version block reads it VERBATIM, so the baked
  # eval (nixblitzFlake, below) and the install-time eval (a path-getFlake of
  # this same store path) agree on the drv by content.
  #
  # The runCommand name MUST be "source" so the store-path shape matches what
  # a path-input re-fetch of it produces (the name component participates in
  # store-path identity if nix ever re-adds it; keep it consistent).
  stampedSelf = pkgs.runCommand "source" {} ''
    cp -a ${self} $out
    chmod -R u+w $out
    printf '%s' ${lib.escapeShellArg versionStamp} > $out/.nixblitz-version-stamp
  '';

  # A FLAKE OBJECT evaluated from the stamped copy with install-time metadata
  # shape — this is what templates/flake.nix receives as its `nixblitz` input
  # (base.nix reads `nixblitz.packages.<sys>.nixblitz-unwrapped`). A manual
  # fix-point over the ROOT flake's own `outputs`, tying the knot the same way
  # `nix flake` itself does: `self` is the eventual result of calling
  # `outputs`, with `outPath` pointed at the stamped copy (so `./nix/...` and
  # the TUI src root resolve INSIDE it — identical to a path-getFlake) and the
  # git-metadata attrs deliberately absent (so the version block is forced
  # down the stamp-file path exactly as it is on the live medium).
  nixblitzFlake = let
    rootFlake = import (stampedSelf + "/flake.nix");
    rootInputs = {
      inherit
        (self.inputs)
        nixpkgs-unstable
        nixpkgs-vanilla-unstable
        flake-utils
        nix-filter
        disko
        nixos-raspberrypi
        ;
      # NOT self.inputs.nixpkgs: at install time templates/flake.nix forces
      # `nixblitz.inputs.nixpkgs.follows = "nixpkgs"`, and templates' nixpkgs
      # follows nvmd's — so the on-ISO eval of the nixblitz input sees
      # nixos-raspberrypi's nixpkgs, not root's own. wasmtimePinned (baked
      # into the TUI drv via --define WASMTIME_DART_LIB) is built from THIS
      # nixpkgs, so passing root's here diverged the baked TUI drv from the
      # install-time one — re-opening the offline-rebuild hole one level
      # below the metadata stamp. Mirror the follows resolution instead.
      nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
    };
    pathSelf =
      result
      // {
        outPath = stampedSelf;
        lastModified = 0;
        lastModifiedDate = "19700101000000";
        # `.inputs` is what a path-getFlake of the stamped copy exposes on
        # the live medium (resolved from the offline flake.lock). templates/
        # reads `nixblitz.inputs.nixpkgs-unstable` for pin-flake-sources; the
        # offline lock overrides `nixblitz/nixpkgs-unstable` to this SAME
        # store path, so bake and install agree.
        inherit (self) inputs;
        # deliberately NO rev/shortRev/dirtyRev/dirtyShortRev — mirrors a
        # path-locked input on the live medium. The version block reads the
        # stamp file instead, so these missing attrs are never touched.
      };
    result = rootFlake.outputs (rootInputs // {self = pathSelf;});
    # Build-time guardrail: the baked TUI drv (the very attr base.nix
    # consumes) MUST carry the real stamp. A miss means metadata drift snuck
    # back into the version block and the offline bake would diverge from the
    # install-time eval — turn that into a loud ISO-build failure forever.
    # Checks `pathSelf` directly (not `nixblitzFlake`) to avoid a self-cycle.
    checkDrv = pathSelf.packages.${system}.nixblitz-unwrapped;
  in
    assert lib.assertMsg (lib.hasInfix versionStamp checkDrv.name)
    "nixblitz offline bake would diverge from install-time eval: TUI derivation '${checkDrv.name}' does not contain version stamp '${versionStamp}'"; pathSelf;
in rec {
  # The exact input set templates/flake.nix's `outputs` function receives,
  # mirroring templates/flake.nix's own `inputs` block (nixpkgs follows
  # nvmd's nixpkgs; disko and nixos-raspberrypi are direct; nixblitz is
  # this very repo, published at forge.f44.fyi/f44/nixblitz_ng and pulled
  # back in by templates/flake.nix as a git+https input).
  templatesInputs = {
    nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
    inherit disko nixos-raspberrypi;
    # The content-stamped flake object (NOT the raw root `self`): its version
    # block reads the baked stamp, so the TUI drv it yields is identical to
    # the one the live medium builds from the path-locked stamped source.
    nixblitz = nixblitzFlake;
  };

  # Exposed for the drv-equality acceptance check (compare its `.outPath`
  # against a path-getFlake of it) and so downstream consumers can bake it.
  inherit stampedSelf;

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
    # (git+https://forge.f44.fyi/f44/nixblitz_ng). On the live medium it is
    # path-locked to the STAMPED source copy (not raw `self`) so its version
    # block reads the baked stamp and reproduces the baked TUI drv offline.
    {
      name = "nixblitz";
      path = stampedSelf;
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
