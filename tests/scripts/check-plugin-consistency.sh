#!/usr/bin/env bash
# tests/scripts/check-plugin-consistency.sh
#
# Asserts:
# 1. The bitcoind / lnd / cln plugins all pin the same nix-bitcoin
#    rev. They share a binary (`getFlake` at the same SHA = same store
#    entry) and dual / triple-pinning would bloat the operator's
#    closure with multiple copies of nix-bitcoin's nixpkgs snapshot.
# 2. The lnd / cln tile-lightning.json files are byte-identical.
#    They render the same Lightning tile; an edit to one without the
#    other produces visible drift between operators on different LN
#    backends.

set -euo pipefail

PLUGINS_ROOT="examples_redesign/nixblitz_official_plugins"
fail=0

echo "==> Checking nix-bitcoin rev consistency"
declare -a revs
for id in bitcoind lnd cln; do
  rev=$(grep -E '^\s*nixBitcoinRev = ' "${PLUGINS_ROOT}/${id}/plugin.nix" \
        | sed -E 's/.*"([0-9a-f]{40})".*/\1/')
  if [[ -z "${rev}" || ${#rev} -ne 40 ]]; then
    echo "  ❌ ${id}/plugin.nix: failed to extract nixBitcoinRev (got '${rev}')"
    fail=1
    continue
  fi
  echo "  ${id}: ${rev}"
  revs+=("${rev}")
done

if [[ ${#revs[@]} -eq 3 ]]; then
  if [[ "${revs[0]}" == "${revs[1]}" && "${revs[1]}" == "${revs[2]}" ]]; then
    echo "  ✅ all three plugins agree on nix-bitcoin rev"
  else
    echo "  ❌ nix-bitcoin rev divergence — bump all three plugins together"
    fail=1
  fi
fi

echo "==> Checking lnd/cln tile-lightning.json byte identity"
if diff -q "${PLUGINS_ROOT}/lnd/tile-lightning.json" \
          "${PLUGINS_ROOT}/cln/tile-lightning.json" >/dev/null; then
  echo "  ✅ tile-lightning.json byte-identical"
else
  echo "  ❌ tile-lightning.json differs between lnd and cln"
  diff "${PLUGINS_ROOT}/lnd/tile-lightning.json" \
       "${PLUGINS_ROOT}/cln/tile-lightning.json" || true
  fail=1
fi

exit ${fail}
