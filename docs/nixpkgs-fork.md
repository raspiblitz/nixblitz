# The nixpkgs fork (dart-workspace-member-filter)

The TUI build depends on a **custom nixpkgs fork**:

```
nixpkgs-unstable.url = "github:fusion44/nixpkgs/dart-workspace-member-filter";
```

The branch carries the `dart-workspace-member-filter` patch to
`buildDartApplication`, which vanilla nixpkgs lacks: it lets the Dart builder
evaluate a **pub workspace** (our repo root + `common` / `tui` members) instead
of assuming a single-package layout. Without it, `nix build` of the TUI fails.
This is the one documented exception to the "every input follows nixpkgs" rule
(see CLAUDE.md → Flake input rules).

## Why this needs periodic care

The branch is pinned in `flake.lock` and drifts behind upstream
nixos-unstable. The longer it drifts, the staler every package the TUI build
pulls from it (Dart SDK included) and the hairier the eventual rebase. Rebase
whenever you need a newer Dart / package set, or roughly once per NixOS
release cycle.

## Rebase procedure

```bash
# One-time setup
git clone git@github.com:fusion44/nixpkgs.git
cd nixpkgs
git remote add upstream https://github.com/NixOS/nixpkgs.git

# Each rebase
git fetch upstream
git checkout dart-workspace-member-filter

# See what we carry (should be a small patch series on buildDartApplication —
# pkgs/build-support/dart/…):
git log --oneline upstream/nixos-unstable..HEAD

git rebase upstream/nixos-unstable
# Conflicts, if any, will be inside pkgs/build-support/dart/ — the builder
# does get refactored upstream occasionally. Re-read the surrounding code
# rather than force-applying the old hunks.
```

## Verify BEFORE pushing

Point this repo's input at the local checkout and run the build + gate:

```bash
cd ~/dev/blitz/nixblitz
nix build .#nixblitz-unwrapped \
  --override-input nixpkgs-unstable path:/path/to/nixpkgs
just ci
```

If the Dart SDK jumped, `dart pub get` + `just gen-locks` may be needed first
(pubspec.lock / workspace lock files feed the Nix build — see dev-loop.md).

## Publish

```bash
cd /path/to/nixpkgs
git push -f origin dart-workspace-member-filter

cd ~/dev/blitz/nixblitz
nix flake update nixpkgs-unstable
just ci && just test-config
```

Commit the `flake.lock` bump like any other input advance.

## Exit strategy

The standing goal is to **upstream the patch** so the fork disappears.
Until a nixpkgs PR lands, this doc is the bus-factor mitigation: anyone with
push access to the fork can perform the rebase with the steps above.
