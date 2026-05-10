#!/usr/bin/env bash
# tests/scripts/check-plugin-consistency.sh
#
# Asserts:
# 1. Only the bitcoind plugin pins nix-bitcoin; lnd / cln must NOT. They
#    rely on bitcoind's import for the shared nix-bitcoin option tree —
#    importing the anonymous `nixosModules.default` from multiple plugins
#    triggers double-declaration of options like `nix-bitcoin.useVersionLockedPkgs`
#    (the module system can't dedupe anonymous inline modules), and the
#    rebuild fails.
# 2. The lnd / cln tile-lightning.json files are byte-identical. They
#    render the same Lightning tile; an edit to one without the other
#    produces visible drift between operators on different LN backends.

set -euo pipefail

PLUGINS_ROOT="examples_redesign/nixblitz_official_plugins"
fail=0

echo "==> Checking nix-bitcoin pin lives ONLY in bitcoind"

bitcoind_rev=$(grep -E '^\s*nixBitcoinRev = ' \
                "${PLUGINS_ROOT}/bitcoind/plugin.nix" \
              | sed -E 's/.*"([0-9a-f]{40})".*/\1/' || true)
if [[ -z "${bitcoind_rev}" || ${#bitcoind_rev} -ne 40 ]]; then
  echo "  ❌ bitcoind/plugin.nix: failed to extract nixBitcoinRev (got '${bitcoind_rev}')"
  fail=1
else
  echo "  bitcoind: ${bitcoind_rev}"
fi

for id in lnd cln; do
  if grep -qE '^\s*nixBitcoinRev = ' "${PLUGINS_ROOT}/${id}/plugin.nix"; then
    echo "  ❌ ${id}/plugin.nix pins nixBitcoinRev — it must not."
    echo "     Only the bitcoind plugin imports nix-bitcoin. lnd and cln"
    echo "     rely on it transitively; importing nix-bitcoin from multiple"
    echo "     plugins double-declares nix-bitcoin.* options."
    fail=1
  else
    echo "  ${id}: no nix-bitcoin pin (correct)"
  fi
done

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
