#!/usr/bin/env bash
# tests/scripts/check-wasm-plugins.sh
#
# Fails if a plugin's committed .wasm is stale vs a fresh nix build.
# Mirrors the tile-manifest freshness invariant in
# check-plugin-consistency.sh, but for compiled wasm guests.
#
# Dev-local guard, NOT part of `just ci`: node-summary lives in
# nixblitz_official_plugins, a separate repo checked out (optionally) at
# examples_redesign/, which is gitignored in this repo (see .gitignore)
# and absent on a clean main checkout / CI runner. The plugins repo owns
# its own CI; this script just gives plugin authors on this machine a
# fast way to catch a stale committed .wasm before pushing there.
#
# Honest caveat: a mismatch on a different toolchain/nixpkgs pin is
# expected, not necessarily tampering — wasm builds are not guaranteed
# bit-reproducible across rustc/LLVM versions. If bit-reproducibility
# proves too flaky in practice, switch this to comparing the wasm's
# exports/imports signature (e.g. via `wasm-tools print` or `wasm2wat`
# + a stripped diff) instead of raw bytes.
set -euo pipefail

plugin="examples_redesign/nixblitz_official_plugins/node-summary"
if [ ! -d "$plugin" ]; then
  echo "node-summary plugin not found (examples_redesign not checked out); skipping wasm freshness check"
  exit 0
fi

built=$(nix build "path:$plugin" --no-link --print-out-paths)/summary.wasm
if ! cmp -s "$built" "$plugin/actions/summary.wasm"; then
  echo "STALE: $plugin/actions/summary.wasm differs from a fresh build."
  echo "Rebuild: (cd $plugin && nix build && cp result/summary.wasm actions/summary.wasm)"
  echo "Note: wasm builds are not guaranteed bit-reproducible — review the diff."
  exit 1
fi
echo "node-summary summary.wasm is in sync."
