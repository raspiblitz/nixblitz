# Bitcoin Family Plugin Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract bitcoind / lnd / cln from `templates/modules/apps/*` into three fully self-contained plugins matching the blitz-api / blitz-web / lnbits pattern, so the TUI binary has zero hardcoded knowledge of which apps exist.

**Architecture:** Each new plugin owns its `plugin.json` (config_schema), `plugin.nix` (NixOS module body), tile manifest(s), and bash + jq streamer. NixOS modules pull `nix-bitcoin` via `builtins.getFlake` at a coordinated rev (CI enforces all three plugins agree). `nix-bitcoin` drops out of `templates/flake.nix`. The setup wizard gains an `installBitcoindPlugin` auto-step + `selectLightningBackend` SelectPopup step before `setLightningAlias`. No migration code (manual cutover for the one existing operator).

**Tech Stack:** Dart (Riverpod, nocterm), Nix flakes, bash + jq for streamers, Forgejo for plugin hosting (`forge.f44.fyi/f44/nixblitz_official_plugins`).

---

## File Structure

**New files (per plugin under `examples_redesign/nixblitz_official_plugins/<id>/`):**

```
bitcoind/
├── plugin.json              ← manifest header + config_schema + tile_manifests + streamers
├── plugin.nix               ← getFlake(nix-bitcoin) + cfg → services.bitcoind.*
├── tile-bitcoin.json        ← DSL manifest (moved from bundled)
├── streamers/
│   └── bitcoin_stream.sh    ← bash + jq wrapper around bitcoin-cli
└── README.md

lnd/
├── plugin.json
├── plugin.nix               ← cfg → services.lnd.*
├── tile-lightning.json      ← DSL manifest
├── streamers/
│   └── lnd_stream.sh
└── README.md

cln/
├── plugin.json
├── plugin.nix               ← cfg → services.clightning.*
├── tile-lightning.json      ← byte-identical to lnd's
├── streamers/
│   └── cln_stream.sh
└── README.md
```

**Modified files:**

- `common/lib/src/models/plugin/plugin_manifest.dart` — add `tileManifests` field; bump `currentPluginManifestVersion` 2 → 3.
- `common/lib/src/models/plugin/plugin_manifest_test.dart` — coverage for new field.
- `common/lib/src/providers/dashboard_provider.dart` — `tileManifestsProvider` reads bundled + plugin-owned tile manifest paths.
- `common/lib/src/models/nixblitz_config.dart` — `defaults()` drops bitcoind/lnd/cln.
- `common/test/models/nixblitz_config_test.dart` — defaults assertions.
- `common/test/services/configure/bundled/registry_test.dart` — built-in app set shrinks.
- `common/test/services/configure/bundled/manifests_test.dart` — same.
- `templates/flake.nix` — drop `nix-bitcoin` input + outputs arg + import.
- `templates/hosts/installed.nix` — drop `features.apps.{bitcoind,lnd,cln}.*` block; helpers stay.
- `templates/modules/system/base.nix` — drop `nix-bitcoin.generateSecrets = true` (moves into plugins).
- `tui/lib/src/ui/views/setup_view.dart` — new `SetupStep` values + their `_build*` methods.

**Deleted files:**

- `templates/modules/apps/bitcoind.nix`
- `templates/modules/apps/lnd.nix`
- `templates/modules/apps/cln.nix`
- `common/lib/src/services/configure/bundled/manifests/bitcoind.json`
- `common/lib/src/services/configure/bundled/manifests/lnd.json`
- `common/lib/src/services/configure/bundled/manifests/cln.json`
- `common/lib/src/services/dashboard/bundled/manifests/bitcoin.json`
- `common/lib/src/services/dashboard/bundled/manifests/lightning.json`

**Regenerated codegen outputs (after deletions):**

- `common/lib/src/services/embedded_templates.g.dart` (via `just gen-templates`)
- `common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart` (via `just gen-manifests`)
- `common/lib/src/services/configure/bundled/embedded_schemas.g.dart` (via `just gen-app-schemas`)

---

### Task 1: Pin the nix-bitcoin rev for the three plugins

The three plugin.nix files all `getFlake "github:fort-nix/nix-bitcoin/${rev}"`. They must share the same rev so the operator's nix store doesn't end up with two simultaneous copies of nix-bitcoin (closure bloat, eval ambiguity). Decide the pin once here; later tasks use it.

**Files:**
- Test: `tests/scripts/check-nix-bitcoin-rev-consistency.sh` (created later in Task 11)

- [ ] **Step 1: Get the current nix-bitcoin master rev**

```bash
NIX_BITCOIN_REV=$(git ls-remote https://github.com/fort-nix/nix-bitcoin.git HEAD | cut -f1)
echo "Using nix-bitcoin rev: $NIX_BITCOIN_REV"
```

Expected: a 40-character SHA prints. Save it — every later task that writes a `plugin.nix` substitutes this exact value.

- [ ] **Step 2: Smoke-test the rev resolves**

```bash
nix flake metadata "github:fort-nix/nix-bitcoin/${NIX_BITCOIN_REV}" --no-write-lock-file 2>&1 | head -5
```

Expected: prints "Resolved URL", "Locked URL", and "Last modified" without errors. If the rev isn't reachable, pick a recent tagged release instead (`git ls-remote --tags https://github.com/fort-nix/nix-bitcoin.git | tail -5`).

- [ ] **Step 3: Record the chosen rev**

Write the rev to a temporary file the rest of the plan reads from:

```bash
echo "$NIX_BITCOIN_REV" > /tmp/nix-bitcoin-rev.txt
```

No commit yet — the rev gets baked into plugin.nix files in subsequent tasks.

---

### Task 2: PluginManifest gains a `tileManifests` field

The new field is a `List<String>` of paths (relative to the plugin root) pointing at DSL tile manifest JSON files. Loaded only when the plugin is enabled.

**Files:**
- Modify: `common/lib/src/models/plugin/plugin_manifest.dart`
- Test: `common/test/models/plugin/plugin_manifest_test.dart`

- [ ] **Step 1: Write a failing test for parsing `tile_manifests`**

Add to `common/test/models/plugin/plugin_manifest_test.dart`:

```dart
test('parses tile_manifests as a list of relative paths', () {
  final json = {
    'manifest': {
      'schema_version': 3,
      'min_tui_version': 3,
      'name': 'Test',
    },
    'id': 'test',
    'tile_manifests': ['tile-foo.json', 'tile-bar.json'],
  };
  final m = PluginManifest.fromJson(json);
  expect(m.tileManifests, ['tile-foo.json', 'tile-bar.json']);
});

test('tile_manifests defaults to empty when absent', () {
  final json = {
    'manifest': {
      'schema_version': 2,
      'min_tui_version': 1,
      'name': 'Test',
    },
    'id': 'test',
  };
  final m = PluginManifest.fromJson(json);
  expect(m.tileManifests, isEmpty);
});

test('rejects non-list tile_manifests', () {
  final json = {
    'manifest': {
      'schema_version': 3,
      'min_tui_version': 3,
      'name': 'Test',
    },
    'id': 'test',
    'tile_manifests': 'tile-foo.json',
  };
  expect(
    () => PluginManifest.fromJson(json),
    throwsA(isA<PluginManifestError>()),
  );
});
```

- [ ] **Step 2: Run tests — expect failure**

```bash
cd common && dart test test/models/plugin/plugin_manifest_test.dart -p vm 2>&1 | tail -10
```

Expected: three new tests fail with "tileManifests not defined" or similar.

- [ ] **Step 3: Add the field to PluginManifest**

In `common/lib/src/models/plugin/plugin_manifest.dart`:

Bump version constant near the top:

```dart
const int currentPluginManifestVersion = 3;
```

Add field declaration in the class (after `streamers`):

```dart
/// DSL tile manifest paths shipped by this plugin. Each entry is a
/// path relative to the plugin's source root (e.g. `tile-bitcoin.json`).
/// The dashboard registers these into the global tile manifest pool
/// only when the plugin is enabled, alongside the bundled manifests.
final List<String> tileManifests;
```

Add to constructor:

```dart
this.tileManifests = const [],
```

Parse it in `fromJson` (after the `streamers` parsing block):

```dart
final rawTileManifests = json['tile_manifests'];
final tileManifestsList = <String>[];
if (rawTileManifests != null) {
  if (rawTileManifests is! List) {
    throw const PluginManifestError(
      'manifest.tile_manifests must be a list of relative path strings',
    );
  }
  for (final entry in rawTileManifests) {
    if (entry is! String || entry.isEmpty) {
      throw const PluginManifestError(
        'manifest.tile_manifests entries must be non-empty strings',
      );
    }
    tileManifestsList.add(entry);
  }
}
```

Pass to constructor at the bottom of `fromJson`:

```dart
tileManifests: List.unmodifiable(tileManifestsList),
```

Emit in `toJson`:

```dart
if (tileManifests.isNotEmpty) 'tile_manifests': tileManifests,
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd common && dart test test/models/plugin/plugin_manifest_test.dart -p vm 2>&1 | tail -10
```

Expected: all tests pass including the three new ones. Existing tests (no `tile_manifests` field in their fixtures) should still pass — the field defaults to empty.

- [ ] **Step 5: Commit**

```bash
git add common/lib/src/models/plugin/plugin_manifest.dart \
        common/test/models/plugin/plugin_manifest_test.dart
git commit -m "$(cat <<'EOF'
feat(plugin): tile_manifests field on PluginManifest

Adds a List<String> field carrying paths to DSL tile manifests
shipped by the plugin. Bumps currentPluginManifestVersion to 3.
Existing manifests without the field default to empty list, so
already-installed plugins are unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Dashboard provider merges plugin tile manifests

`tileManifestsProvider` currently returns just the bundled list. Extend it so each enabled plugin's `tileManifests` paths get loaded from `~/nixblitz/plugins/<id>/<path>` and appended.

**Files:**
- Modify: `common/lib/src/providers/dashboard_provider.dart`
- Test: `common/test/providers/dashboard_provider_tile_manifests_test.dart` (new)

- [ ] **Step 1: Write a failing test**

Create `common/test/providers/dashboard_provider_tile_manifests_test.dart`:

```dart
import 'dart:io';
import 'package:common/common.dart';
import 'package:common/src/providers/dashboard_provider.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  test('tileManifestsProvider includes enabled plugin tile manifests', () async {
    final tmp = Directory.systemTemp.createTempSync('plugin-tile-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // Synthetic plugin layout
    final pluginDir = Directory('${tmp.path}/plugins/foo')..createSync(recursive: true);
    File('${pluginDir.path}/plugin.json').writeAsStringSync('''
{
  "manifest": {"schema_version": 3, "min_tui_version": 3, "name": "Foo"},
  "id": "foo",
  "tile_manifests": ["tile-foo.json"]
}
''');
    File('${pluginDir.path}/tile-foo.json').writeAsStringSync('''
{"id": "foo", "title": "Foo", "accent_color": "#ff0000", "layout": []}
''');
    File('${tmp.path}/plugins.list').writeAsStringSync('foo\n');
    File('${tmp.path}/config.json').writeAsStringSync('''
{"schema_version": 19, "min_compatible_version": 1, "initialized": true,
 "system": {"hostname": "h", "timezone": "UTC", "platform": "vm"},
 "app_configs": {"foo": {"enabled": true}}}
''');

    final container = ProviderContainer(
      overrides: [baseDirProvider.overrideWithValue(tmp.path)],
    );
    addTearDown(container.dispose);

    final manifests = container.read(tileManifestsProvider);
    final ids = manifests.map((m) => m.id).toList();
    expect(ids, contains('foo'));
  });

  test('disabled plugin tile manifests are excluded', () async {
    final tmp = Directory.systemTemp.createTempSync('plugin-tile-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final pluginDir = Directory('${tmp.path}/plugins/foo')..createSync(recursive: true);
    File('${pluginDir.path}/plugin.json').writeAsStringSync('''
{
  "manifest": {"schema_version": 3, "min_tui_version": 3, "name": "Foo"},
  "id": "foo",
  "tile_manifests": ["tile-foo.json"]
}
''');
    File('${pluginDir.path}/tile-foo.json').writeAsStringSync('''
{"id": "foo", "title": "Foo", "accent_color": "#ff0000", "layout": []}
''');
    File('${tmp.path}/plugins.list').writeAsStringSync('foo\n');
    File('${tmp.path}/config.json').writeAsStringSync('''
{"schema_version": 19, "min_compatible_version": 1, "initialized": true,
 "system": {"hostname": "h", "timezone": "UTC", "platform": "vm"},
 "app_configs": {"foo": {"enabled": false}}}
''');

    final container = ProviderContainer(
      overrides: [baseDirProvider.overrideWithValue(tmp.path)],
    );
    addTearDown(container.dispose);

    final manifests = container.read(tileManifestsProvider);
    final ids = manifests.map((m) => m.id).toList();
    expect(ids, isNot(contains('foo')));
  });
}
```

- [ ] **Step 2: Run test — expect failure**

```bash
cd common && dart test test/providers/dashboard_provider_tile_manifests_test.dart -p vm 2>&1 | tail -10
```

Expected: tests fail because the provider only returns bundled manifests today.

- [ ] **Step 3: Modify the provider**

In `common/lib/src/providers/dashboard_provider.dart`, find the `tileManifestsProvider` definition and replace it with:

```dart
/// Bundled manifests + every enabled plugin's declared `tile_manifests`.
/// Paths are resolved relative to `<baseDir>/plugins/<id>/`. A plugin
/// whose manifest declares `tile_manifests` but whose `app_configs[id]
/// .enabled` is false contributes nothing — same gating as streamers.
///
/// Per-plugin manifests are filtered: parse failures and missing files
/// log a warning and skip rather than blowing up the dashboard. The
/// final list is sorted by tile id for stable order across rebuilds.
final tileManifestsProvider = Provider<List<TileManifest>>((ref) {
  final base = ref.watch(baseDirProvider);
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final plugins = ref.watch(installedPluginsProvider);

  final out = <TileManifest>[...bundledManifests];

  for (final plugin in plugins) {
    if (plugin.tileManifests.isEmpty) continue;
    if (config == null || !config.isAppEnabled(plugin.id)) continue;

    for (final relPath in plugin.tileManifests) {
      final path = '$base/plugins/${plugin.id}/$relPath';
      try {
        final content = File(path).readAsStringSync();
        out.add(TileManifest.fromJsonString(content));
      } catch (e, st) {
        LogService.warn(
          'plugin ${plugin.id}: failed to load tile manifest $relPath: $e',
        );
        LogService.error('plugin tile manifest load trace', e, st);
      }
    }
  }

  out.sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(out);
});
```

You'll need imports at the top of the file:

```dart
import 'dart:io';
```

(if not already present).

- [ ] **Step 4: Run test — expect pass**

```bash
cd common && dart test test/providers/dashboard_provider_tile_manifests_test.dart -p vm 2>&1 | tail -10
```

Expected: both tests pass.

- [ ] **Step 5: Run full common test suite**

```bash
cd common && dart test 2>&1 | tail -5
```

Expected: All tests passed.

- [ ] **Step 6: Commit**

```bash
git add common/lib/src/providers/dashboard_provider.dart \
        common/test/providers/dashboard_provider_tile_manifests_test.dart
git commit -m "$(cat <<'EOF'
feat(dashboard): merge plugin-owned tile manifests into the registry

Each enabled plugin's tile_manifests entries are loaded from
~/nixblitz/plugins/<id>/<path> and joined with the bundled set.
Disabled plugins contribute nothing — same gating as streamers.
Parse failures log + skip rather than blowing up the dashboard.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: bitcoind plugin scaffolding

Creates the bitcoind plugin tree under `examples_redesign/nixblitz_official_plugins/bitcoind/`.

**Files:**
- Create: `examples_redesign/nixblitz_official_plugins/bitcoind/plugin.json`
- Create: `examples_redesign/nixblitz_official_plugins/bitcoind/plugin.nix`
- Create: `examples_redesign/nixblitz_official_plugins/bitcoind/tile-bitcoin.json`
- Create: `examples_redesign/nixblitz_official_plugins/bitcoind/streamers/bitcoin_stream.sh`
- Create: `examples_redesign/nixblitz_official_plugins/bitcoind/README.md`

- [ ] **Step 1: Write `plugin.json`**

```json
{
  "manifest": {
    "schema_version": 3,
    "min_tui_version": 3,
    "name": "Bitcoin Core",
    "description": "Bitcoin reference client (full or pruned node) backed by nix-bitcoin's services.bitcoind module."
  },

  "id": "bitcoind",
  "version": "0.1.0",
  "url": "forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/bitcoind",

  "module": "plugin.nix",

  "tile_manifests": ["tile-bitcoin.json"],

  "streamers": [
    {
      "name": "bitcoin-stream",
      "command": "bash",
      "args": ["streamers/bitcoin_stream.sh"],
      "tile_ids": ["bitcoin"]
    }
  ],

  "config_schema": {
    "label": "Bitcoin Core",
    "description": "Bitcoin reference client (full or pruned node).",
    "capabilities": [],
    "fields": [
      { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
      { "name": "network", "type": "enum", "label": "Network",
        "choices": ["mainnet", "regtest"], "default": "mainnet" },
      { "name": "pruned", "type": "bool", "label": "Prune mode", "default": true },
      { "name": "prune_size_gb", "type": "int", "label": "Prune size (GB)",
        "default": 550, "min": 0 }
    ]
  }
}
```

- [ ] **Step 2: Write `plugin.nix`**

Substitute `__NIX_BITCOIN_REV__` with the SHA from Task 1:

```nix
{pluginCfg ? {}}: {
  config,
  lib,
  pkgs,
  ...
}: let
  enabled = pluginCfg.enabled or false;
  network = pluginCfg.network or "mainnet";
  pruned = pluginCfg.pruned or false;
  pruneSizeGb = pluginCfg.prune_size_gb or 0;

  # Pinned in lockstep across the bitcoind / lnd / cln plugins (see
  # docs/superpowers/plans/2026-05-10-bitcoin-family-plugin-extraction.md).
  # Bumps require updating all three at the same SHA — CI enforces.
  nixBitcoinRev = "__NIX_BITCOIN_REV__";
  nixBitcoinFlake = builtins.getFlake "github:fort-nix/nix-bitcoin/${nixBitcoinRev}";
in {
  imports = lib.optional enabled nixBitcoinFlake.nixosModules.default;

  config = lib.mkIf enabled {
    nix-bitcoin.generateSecrets = lib.mkDefault true;

    services.bitcoind = {
      enable = true;
      dataDir = "/mnt/data/bitcoind";
      regtest = network == "regtest";
      prune =
        if pruned
        then pruneSizeGb * 1000
        else 0;
      # Regtest has no real fee history; without a fallback, sendtoaddress /
      # fundrawtx refuse with "Fee estimation failed". 0.0002 BTC/kvB ≈ 20
      # sat/vB — fine for test flows.
      extraConfig = lib.optionalString (network == "regtest") ''
        fallbackfee=0.0002
      '';
    };
  };
}
```

Then substitute the rev:

```bash
NIX_BITCOIN_REV=$(cat /tmp/nix-bitcoin-rev.txt)
sed -i "s|__NIX_BITCOIN_REV__|${NIX_BITCOIN_REV}|" \
  examples_redesign/nixblitz_official_plugins/bitcoind/plugin.nix
grep nixBitcoinRev examples_redesign/nixblitz_official_plugins/bitcoind/plugin.nix
```

Expected: prints `nixBitcoinRev = "<40-char SHA>";` with the rev from Task 1.

- [ ] **Step 3: Write `tile-bitcoin.json` (verbatim from the existing bundled manifest)**

```json
{
  "id": "bitcoin",
  "title": "Bitcoin",
  "accent_color": "#f7931a",
  "layout": [
    {
      "StatusRow": {
        "label": "Network",
        "value": { "$data": "chain_name" },
        "color": { "$data": "chain_color" }
      }
    },
    {
      "ProgressBar": {
        "label": "Sync",
        "value": { "$data": "verification_progress" },
        "format": "percent"
      }
    },
    {
      "Row": { "label": "Blocks", "value": { "$format": "{blocks}/{headers}" } }
    },
    { "Row": { "label": "Peers", "value": { "$data": "peers" } } },
    { "Row": { "label": "Disk", "value": { "$bytes": "size_on_disk" } } },
    {
      "Row": { "label": "Mempool", "value": { "$format": "{mempool_txs} txs" } }
    }
  ],
  "footer": {
    "$status": {
      "$on": "sync_state",
      "synced": { "Footer": { "text": "synced", "color": "ok" } },
      "syncing": { "Footer": { "text": "syncing", "color": "warn" } },
      "stalled": { "Footer": { "text": "stalled", "color": "error" } }
    }
  }
}
```

- [ ] **Step 4: Write `streamers/bitcoin_stream.sh`**

```bash
#!/usr/bin/env bash
# streamers/bitcoin_stream.sh
#
# Polls bitcoin-cli every 5s and emits JSON-line tile events on stdout
# in the NixBlitz tile-event format:
#
#     {"tile":"bitcoin","data":{...},"ts":<unix_ms>}
#
# Run as the operator user (member of `bitcoin` group via
# nix-bitcoin.operator). bitcoin-cli wraps the auth via the
# user's group membership; no extra creds needed.

set -euo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-5}"

emit_data() {
  local data="$1"
  jq -n -c \
    --argjson d "$data" \
    --arg t bitcoin \
    '{tile:$t, data:$d, ts:(now*1000|floor)}'
}

while true; do
  blockchain=$(bitcoin-cli getblockchaininfo 2>/dev/null || echo '{}')
  network=$(bitcoin-cli getnetworkinfo 2>/dev/null || echo '{}')
  mempool=$(bitcoin-cli getmempoolinfo 2>/dev/null || echo '{}')

  data=$(jq -n \
    --argjson bc "$blockchain" \
    --argjson nw "$network" \
    --argjson mp "$mempool" \
    '{
      blocks: ($bc.blocks // 0),
      headers: ($bc.headers // 0),
      verification_progress: ($bc.verificationprogress // 0),
      chain_name: ($bc.chain // "—"),
      chain_color: (if ($bc.chain == "main") then "ok"
                    elif ($bc.chain == "regtest") then "warn"
                    else "info" end),
      sync_state: (if ($bc.initialblockdownload // false)
                   then "syncing" else "synced" end),
      peers: ($nw.connections // 0),
      mempool_txs: ($mp.size // 0),
      size_on_disk: ($bc.size_on_disk // 0)
    }')

  emit_data "$data"
  sleep "$POLL_INTERVAL"
done
```

Make executable:

```bash
chmod +x examples_redesign/nixblitz_official_plugins/bitcoind/streamers/bitcoin_stream.sh
```

- [ ] **Step 5: Write `README.md`**

```markdown
# nixblitz-plugin-bitcoind

NixBlitz plugin: Bitcoin Core full / pruned node, backed by
nix-bitcoin's `services.bitcoind` module.

This plugin provides:

- A NixOS module that pulls nix-bitcoin via `builtins.getFlake` at
  a coordinated rev and configures `services.bitcoind` from
  `app_configs.bitcoind` (network, pruned, prune_size_gb).
- A tile manifest (`tile-bitcoin.json`) for the Bitcoin tile on the
  dashboard.
- A bash streamer that polls `bitcoin-cli` every 5s and emits
  JSON-line tile events.

## Install

In NixBlitz: Configure → Plugins → Install from URL →
`forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/bitcoind`.

The setup wizard auto-installs this plugin on a fresh first boot.

## License

MIT.
```

- [ ] **Step 6: Validate Nix syntax + format**

```bash
nix-instantiate --parse \
  examples_redesign/nixblitz_official_plugins/bitcoind/plugin.nix \
  > /dev/null && echo "syntax ok"
alejandra examples_redesign/nixblitz_official_plugins/bitcoind/plugin.nix 2>&1 | tail -3
```

Expected: prints "syntax ok" + "Congratulations! Your code complies with the Alejandra style."

- [ ] **Step 7: Validate JSON shape via PluginManifest parser**

```bash
cd common && dart run -e '
import "dart:io";
import "package:common/src/models/plugin/plugin_manifest.dart";
void main() {
  final s = File("../examples_redesign/nixblitz_official_plugins/bitcoind/plugin.json").readAsStringSync();
  final m = PluginManifest.fromJsonString(s);
  print("id=${m.id} v=${m.schemaVersion} tile_manifests=${m.tileManifests} streamers=${m.streamers.length}");
}
' 2>&1 | tail -3
```

Expected: prints `id=bitcoind v=3 tile_manifests=[tile-bitcoin.json] streamers=1`.

- [ ] **Step 8: Smoke-test the streamer (skip if no local bitcoin-cli)**

```bash
cd examples_redesign/nixblitz_official_plugins/bitcoind
if command -v bitcoin-cli >/dev/null 2>&1; then
  POLL_INTERVAL=1 timeout 3 bash streamers/bitcoin_stream.sh 2>/dev/null | head -1 | jq .tile
fi
```

Expected (if bitcoin-cli is available): prints `"bitcoin"`. If not, skip — VM validation will exercise it.

- [ ] **Step 9: Commit**

```bash
git add examples_redesign/nixblitz_official_plugins/bitcoind/
git commit -m "$(cat <<'EOF'
feat(plugins): add bitcoind plugin (Bitcoin Core node + tile)

Self-contained plugin matching the blitz-api / lnbits pattern:
- plugin.nix pulls nix-bitcoin via builtins.getFlake at a pinned rev
  shared with the lnd + cln plugins (CI enforces consistency).
- tile-bitcoin.json moved verbatim from bundled.
- streamers/bitcoin_stream.sh polls bitcoin-cli every 5s and emits
  JSON-line tile events (sync state, peer count, mempool, etc.).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: lnd plugin scaffolding

Same shape as bitcoind. Streamer wraps `lncli`.

**Files:**
- Create: `examples_redesign/nixblitz_official_plugins/lnd/plugin.json`
- Create: `examples_redesign/nixblitz_official_plugins/lnd/plugin.nix`
- Create: `examples_redesign/nixblitz_official_plugins/lnd/tile-lightning.json`
- Create: `examples_redesign/nixblitz_official_plugins/lnd/streamers/lnd_stream.sh`
- Create: `examples_redesign/nixblitz_official_plugins/lnd/README.md`

- [ ] **Step 1: Write `plugin.json`**

```json
{
  "manifest": {
    "schema_version": 3,
    "min_tui_version": 3,
    "name": "Lightning Network Daemon",
    "description": "LND lightning implementation backed by nix-bitcoin's services.lnd module."
  },

  "id": "lnd",
  "version": "0.1.0",
  "url": "forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/lnd",

  "module": "plugin.nix",

  "tile_manifests": ["tile-lightning.json"],

  "streamers": [
    {
      "name": "lnd-stream",
      "command": "bash",
      "args": ["streamers/lnd_stream.sh"],
      "tile_ids": ["lightning"]
    }
  ],

  "requires": [{ "type": "app", "id": "bitcoind" }],

  "config_schema": {
    "label": "Lightning (LND)",
    "description": "Lightning Network Daemon (LND) — most common LN implementation.",
    "capabilities": ["lightning_backend"],
    "fields": [
      { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
      { "name": "alias", "type": "str", "label": "Node alias", "default": "" }
    ]
  }
}
```

- [ ] **Step 2: Write `plugin.nix`**

```nix
{pluginCfg ? {}}: {
  config,
  lib,
  pkgs,
  ...
}: let
  enabled = pluginCfg.enabled or false;
  alias = pluginCfg.alias or "";

  # Coordinated rev across bitcoind / lnd / cln plugins (CI enforces).
  nixBitcoinRev = "__NIX_BITCOIN_REV__";
  nixBitcoinFlake = builtins.getFlake "github:fort-nix/nix-bitcoin/${nixBitcoinRev}";
in {
  imports = lib.optional enabled nixBitcoinFlake.nixosModules.default;

  config = lib.mkIf enabled {
    nix-bitcoin.generateSecrets = lib.mkDefault true;

    services.lnd = {
      enable = true;
      dataDir = "/mnt/data/lnd";
      extraConfig = ''
        ${lib.optionalString (alias != "") "alias=${alias}"}
      '';
    };
  };
}
```

Substitute the rev:

```bash
NIX_BITCOIN_REV=$(cat /tmp/nix-bitcoin-rev.txt)
sed -i "s|__NIX_BITCOIN_REV__|${NIX_BITCOIN_REV}|" \
  examples_redesign/nixblitz_official_plugins/lnd/plugin.nix
grep nixBitcoinRev examples_redesign/nixblitz_official_plugins/lnd/plugin.nix
```

Expected: prints `nixBitcoinRev = "<same SHA as bitcoind>";`.

- [ ] **Step 3: Write `tile-lightning.json` (verbatim from existing bundled manifest)**

```json
{
  "id": "lightning",
  "title": "Lightning",
  "accent_color": "#9b6cf2",
  "layout": [
    { "Row": { "label": "Alias", "value": { "$data": "alias" } } },
    {
      "Row": {
        "label": "Pubkey",
        "value": { "$truncate": { "key": "pubkey", "len": 12 } }
      }
    },
    {
      "StatusRow": {
        "label": "Synced",
        "value": { "$data": "synced_label" },
        "color": { "$data": "synced_color" }
      }
    },
    {
      "Row": {
        "label": "Channels",
        "value": { "$format": "{active}/{pending}" }
      }
    },
    { "Row": { "label": "Peers", "value": { "$data": "peers" } } },
    {
      "Row": {
        "label": "On-chain",
        "value": { "$format": "{onchain_sats} sat" }
      }
    },
    {
      "Row": {
        "label": "In-channel",
        "value": { "$format": "{channel_sats} sat" }
      }
    }
  ]
}
```

- [ ] **Step 4: Write `streamers/lnd_stream.sh`**

```bash
#!/usr/bin/env bash
# streamers/lnd_stream.sh
#
# Polls lncli every 5s and emits JSON-line lightning tile events.
# Runs as the operator user (member of `lnd` group via
# nix-bitcoin.operator). lncli reads the local TLS cert + admin
# macaroon automatically via `~/.lnd/`.

set -euo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-5}"

emit_data() {
  local data="$1"
  jq -n -c \
    --argjson d "$data" \
    --arg t lightning \
    '{tile:$t, data:$d, ts:(now*1000|floor)}'
}

while true; do
  info=$(lncli getinfo 2>/dev/null || echo '{}')
  wallet=$(lncli walletbalance 2>/dev/null || echo '{}')
  channel_balance=$(lncli channelbalance 2>/dev/null || echo '{}')
  peers=$(lncli listpeers 2>/dev/null || echo '{"peers":[]}')

  data=$(jq -n \
    --argjson info "$info" \
    --argjson wallet "$wallet" \
    --argjson cb "$channel_balance" \
    --argjson peers "$peers" \
    '{
      alias: ($info.alias // "—"),
      pubkey: ($info.identity_pubkey // "—"),
      synced_label: (if ($info.synced_to_chain // false)
                     then "yes" else "no" end),
      synced_color: (if ($info.synced_to_chain // false)
                     then "ok" else "warn" end),
      active: ($info.num_active_channels // 0),
      pending: ($info.num_pending_channels // 0),
      peers: (($peers.peers // []) | length),
      onchain_sats: (($wallet.confirmed_balance // "0") | tonumber),
      channel_sats: ((($cb.local_balance.sat // "0") | tonumber))
    }')

  emit_data "$data"
  sleep "$POLL_INTERVAL"
done
```

Make executable:

```bash
chmod +x examples_redesign/nixblitz_official_plugins/lnd/streamers/lnd_stream.sh
```

- [ ] **Step 5: Write `README.md`**

```markdown
# nixblitz-plugin-lnd

NixBlitz plugin: Lightning Network Daemon (LND), backed by
nix-bitcoin's `services.lnd` module.

This plugin provides:

- A NixOS module pulling nix-bitcoin via `builtins.getFlake` at a
  rev coordinated with the bitcoind + cln plugins.
- A tile manifest (`tile-lightning.json`) for the Lightning tile on
  the dashboard.
- A bash streamer polling `lncli` every 5s.

## Install

In NixBlitz: Configure → Plugins → Install from URL →
`forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/lnd`.

The setup wizard installs this when "lnd" is selected as the
Lightning backend.

## Mutual exclusion with cln

Don't enable both `lnd` and `cln` simultaneously — each tries to
own the lightning tile + bitcoind connection. nix-bitcoin's modules
will assert/fail in that case.

## License

MIT.
```

- [ ] **Step 6: Validate**

```bash
nix-instantiate --parse \
  examples_redesign/nixblitz_official_plugins/lnd/plugin.nix \
  > /dev/null && echo "syntax ok"
alejandra examples_redesign/nixblitz_official_plugins/lnd/plugin.nix 2>&1 | tail -3
```

Expected: "syntax ok" + alejandra-clean.

- [ ] **Step 7: Validate JSON shape**

```bash
cd common && dart run -e '
import "dart:io";
import "package:common/src/models/plugin/plugin_manifest.dart";
void main() {
  final s = File("../examples_redesign/nixblitz_official_plugins/lnd/plugin.json").readAsStringSync();
  final m = PluginManifest.fromJsonString(s);
  print("id=${m.id} tile_manifests=${m.tileManifests}");
}
' 2>&1 | tail -3
```

Expected: prints `id=lnd tile_manifests=[tile-lightning.json]`.

- [ ] **Step 8: Commit**

```bash
git add examples_redesign/nixblitz_official_plugins/lnd/
git commit -m "$(cat <<'EOF'
feat(plugins): add lnd plugin (Lightning Network Daemon + tile)

Self-contained plugin: NixOS module pulls nix-bitcoin via getFlake
at the same rev as the bitcoind plugin, configures services.lnd,
ships the lightning tile manifest, and polls lncli via a bash
streamer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: cln plugin scaffolding

Same shape as lnd, but wrapping `services.clightning`. Tile manifest is **byte-identical** to lnd's so a single CI check enforces the equivalence.

**Files:**
- Create: `examples_redesign/nixblitz_official_plugins/cln/plugin.json`
- Create: `examples_redesign/nixblitz_official_plugins/cln/plugin.nix`
- Create: `examples_redesign/nixblitz_official_plugins/cln/tile-lightning.json`
- Create: `examples_redesign/nixblitz_official_plugins/cln/streamers/cln_stream.sh`
- Create: `examples_redesign/nixblitz_official_plugins/cln/README.md`

- [ ] **Step 1: Write `plugin.json`**

```json
{
  "manifest": {
    "schema_version": 3,
    "min_tui_version": 3,
    "name": "Core Lightning",
    "description": "CLN (Core Lightning) implementation backed by nix-bitcoin's services.clightning module."
  },

  "id": "cln",
  "version": "0.1.0",
  "url": "forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/cln",

  "module": "plugin.nix",

  "tile_manifests": ["tile-lightning.json"],

  "streamers": [
    {
      "name": "cln-stream",
      "command": "bash",
      "args": ["streamers/cln_stream.sh"],
      "tile_ids": ["lightning"]
    }
  ],

  "requires": [{ "type": "app", "id": "bitcoind" }],

  "config_schema": {
    "label": "Lightning (CLN)",
    "description": "Core Lightning (CLN) — Blockstream's LN implementation.",
    "capabilities": ["lightning_backend"],
    "fields": [
      { "name": "enabled", "type": "bool", "label": "Enabled", "default": false }
    ]
  }
}
```

- [ ] **Step 2: Write `plugin.nix`**

```nix
{pluginCfg ? {}}: {
  config,
  lib,
  pkgs,
  ...
}: let
  enabled = pluginCfg.enabled or false;

  # Coordinated rev across bitcoind / lnd / cln plugins (CI enforces).
  nixBitcoinRev = "__NIX_BITCOIN_REV__";
  nixBitcoinFlake = builtins.getFlake "github:fort-nix/nix-bitcoin/${nixBitcoinRev}";
in {
  imports = lib.optional enabled nixBitcoinFlake.nixosModules.default;

  config = lib.mkIf enabled {
    nix-bitcoin.generateSecrets = lib.mkDefault true;

    services.clightning = {
      enable = true;
      dataDir = "/mnt/data/clightning";
    };
  };
}
```

Substitute the rev:

```bash
NIX_BITCOIN_REV=$(cat /tmp/nix-bitcoin-rev.txt)
sed -i "s|__NIX_BITCOIN_REV__|${NIX_BITCOIN_REV}|" \
  examples_redesign/nixblitz_official_plugins/cln/plugin.nix
```

- [ ] **Step 3: Copy `tile-lightning.json` byte-for-byte from the lnd plugin**

```bash
cp examples_redesign/nixblitz_official_plugins/lnd/tile-lightning.json \
   examples_redesign/nixblitz_official_plugins/cln/tile-lightning.json
```

- [ ] **Step 4: Write `streamers/cln_stream.sh`**

```bash
#!/usr/bin/env bash
# streamers/cln_stream.sh
#
# Polls lightning-cli every 5s and emits JSON-line lightning tile
# events. Runs as the operator user (member of `clightning` group
# via nix-bitcoin.operator).

set -euo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-5}"

emit_data() {
  local data="$1"
  jq -n -c \
    --argjson d "$data" \
    --arg t lightning \
    '{tile:$t, data:$d, ts:(now*1000|floor)}'
}

while true; do
  info=$(lightning-cli getinfo 2>/dev/null || echo '{}')
  funds=$(lightning-cli listfunds 2>/dev/null || echo '{}')
  peers=$(lightning-cli listpeers 2>/dev/null || echo '{"peers":[]}')
  channels=$(lightning-cli listchannels 2>/dev/null || echo '{"channels":[]}')

  data=$(jq -n \
    --argjson info "$info" \
    --argjson funds "$funds" \
    --argjson peers "$peers" \
    --argjson channels "$channels" \
    '{
      alias: ($info.alias // "—"),
      pubkey: ($info.id // "—"),
      synced_label: (if ($info.warning_bitcoind_sync // null) then "no"
                     elif ($info.warning_lightningd_sync // null) then "no"
                     else "yes" end),
      synced_color: (if (($info.warning_bitcoind_sync // null) or
                         ($info.warning_lightningd_sync // null))
                     then "warn" else "ok" end),
      active: ($info.num_active_channels // 0),
      pending: ($info.num_pending_channels // 0),
      peers: (($peers.peers // []) | length),
      onchain_sats: ([(($funds.outputs // [])[] |
                       select(.status=="confirmed") | (.amount_msat // 0) / 1000)] | add // 0),
      channel_sats: ([(($funds.channels // [])[] |
                       (.our_amount_msat // 0) / 1000)] | add // 0)
    }')

  emit_data "$data"
  sleep "$POLL_INTERVAL"
done
```

Make executable:

```bash
chmod +x examples_redesign/nixblitz_official_plugins/cln/streamers/cln_stream.sh
```

- [ ] **Step 5: Write `README.md`**

```markdown
# nixblitz-plugin-cln

NixBlitz plugin: Core Lightning (CLN), backed by nix-bitcoin's
`services.clightning` module.

This plugin provides:

- A NixOS module pulling nix-bitcoin via `builtins.getFlake` at a
  rev coordinated with the bitcoind + lnd plugins.
- A tile manifest (`tile-lightning.json`, byte-identical to the
  lnd plugin's — same lightning tile, different streamer).
- A bash streamer polling `lightning-cli` every 5s.

## Install

In NixBlitz: Configure → Plugins → Install from URL →
`forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/cln`.

The setup wizard installs this when "cln" is selected as the
Lightning backend.

## Mutual exclusion with lnd

Don't enable both `lnd` and `cln` simultaneously.

## License

MIT.
```

- [ ] **Step 6: Validate**

```bash
nix-instantiate --parse \
  examples_redesign/nixblitz_official_plugins/cln/plugin.nix \
  > /dev/null && echo "syntax ok"
alejandra examples_redesign/nixblitz_official_plugins/cln/plugin.nix 2>&1 | tail -3
diff examples_redesign/nixblitz_official_plugins/lnd/tile-lightning.json \
     examples_redesign/nixblitz_official_plugins/cln/tile-lightning.json && echo "tile-lightning.json identical"
```

Expected: "syntax ok", alejandra-clean, "tile-lightning.json identical".

- [ ] **Step 7: Commit**

```bash
git add examples_redesign/nixblitz_official_plugins/cln/
git commit -m "$(cat <<'EOF'
feat(plugins): add cln plugin (Core Lightning + tile)

Self-contained plugin: NixOS module pulls nix-bitcoin via getFlake
at the same coordinated rev, configures services.clightning, and
ships a byte-identical lightning tile manifest as the lnd plugin
(CI check verifies). Streamer polls lightning-cli.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Setup wizard — installBitcoindPlugin step

Adds an auto-step that fires after `setPassword`. Calls `PluginService.install` for the bitcoind plugin URL. Renders progress like the existing `buildServices` step (streaming log + retry on failure).

**Files:**
- Modify: `tui/lib/src/ui/views/setup_view.dart`

- [ ] **Step 1: Add the new SetupStep enum value**

In `tui/lib/src/ui/views/setup_view.dart`, find the `enum SetupStep` block (around line 24-31) and update to:

```dart
enum SetupStep {
  setPassword,
  installBitcoindPlugin,
  selectLightningBackend,
  setLightningAlias,
  buildServices,
  waitBitcoind,
  initLightning,
  summary,
}
```

The order matters — `_stepAfter` walks `SetupStep.values` in declaration order to advance.

- [ ] **Step 2: Add a state provider for plugin install status**

After the existing `_buildServicesElapsedProvider` declaration (around line 37-46), add:

```dart
/// Holds the state of the in-flight plugin install during the
/// installBitcoindPlugin / selectLightningBackend wizard steps.
final _pluginInstallStatusProvider = StateProvider<({String? message, bool error})>(
  (ref) => (message: null, error: false),
);
```

- [ ] **Step 3: Wire the new step into the build dispatch**

Find the switch-on-step block (around line 383-388 in `build()`) and update to include the new cases:

```dart
return switch (step) {
  SetupStep.setPassword => _buildSetPassword(),
  SetupStep.installBitcoindPlugin => _buildInstallBitcoindPlugin(),
  SetupStep.selectLightningBackend => _buildSelectLightningBackend(),
  SetupStep.setLightningAlias => _buildSetLightningAlias(),
  SetupStep.buildServices => _buildBuildServices(),
  SetupStep.waitBitcoind => _buildWaitBitcoind(),
  SetupStep.initLightning => _buildInitLightning(),
  SetupStep.summary => _buildSummary(),
};
```

- [ ] **Step 4: Wire the post-setPassword transition**

Find the line that advances from setPassword (currently around line 442 — `_markStepCompleted(SetupStep.setPassword)` followed by setting `_setupStepProvider.notifier.state` to the next step). Update the next-step assignment to:

```dart
_markStepCompleted(SetupStep.setPassword);
context.read(_setupStepProvider.notifier).state =
    SetupStep.installBitcoindPlugin;
```

- [ ] **Step 5: Add the install method**

Add a new method to `_SetupViewState` (place it near `_startBuildServices` around line 134):

```dart
/// Auto-fires when entering the [SetupStep.installBitcoindPlugin]
/// step. Installs the bitcoind plugin via the standard
/// PluginService.install flow. On success advances to
/// selectLightningBackend; on failure leaves the operator on this
/// step with an error + retry affordance.
bool _installBitcoindPluginStarted = false;

void _startInstallBitcoindPlugin() {
  if (_installBitcoindPluginStarted) return;
  _installBitcoindPluginStarted = true;

  context.read(_pluginInstallStatusProvider.notifier).state = (
    message: 'Fetching bitcoind plugin from forge…',
    error: false,
  );

  final pluginService = context.read(pluginServiceProvider);
  pluginService
      .install(
        'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/bitcoind',
      )
      .then((marker) {
        if (!mounted) return;
        LogService.info('installBitcoindPlugin: success (rev=${marker.rev})');

        // Seed app_configs.bitcoind from defaults if absent. The plugin
        // ships a config_schema with sane defaults; we want them on the
        // operator's config.json so subsequent steps see "bitcoind
        // enabled".
        final configService = context.read(configServiceProvider);
        final cfg = context.read(configProvider).value;
        if (cfg != null) {
          final apps = Map<String, Map<String, dynamic>>.from(cfg.appConfigs);
          apps['bitcoind'] = {
            'enabled': true,
            'network': 'mainnet',
            'pruned': true,
            'prune_size_gb': 550,
            ...?apps['bitcoind'],
          };
          final updated = cfg.copyWith(appConfigs: apps);
          configService.writeConfigSync(updated);
          context.read(configProvider.notifier).updateConfig(updated);
        }

        _markStepCompleted(SetupStep.installBitcoindPlugin);
        context.read(_setupStepProvider.notifier).state =
            SetupStep.selectLightningBackend;
      })
      .catchError((e, st) {
        LogService.error('installBitcoindPlugin failed', e, st);
        if (!mounted) return;
        context.read(_pluginInstallStatusProvider.notifier).state = (
          message: 'Install failed: $e',
          error: true,
        );
        _installBitcoindPluginStarted = false; // allow retry
      });
}
```

- [ ] **Step 6: Add the build method**

Add to `_SetupViewState` (place near `_buildBuildServices`):

```dart
Component _buildInstallBitcoindPlugin() {
  // Auto-fire on first render. The handler guards against re-entry
  // via _installBitcoindPluginStarted.
  Future.microtask(_startInstallBitcoindPlugin);

  final status = context.watch(_pluginInstallStatusProvider);
  return Focusable(
    focused: true,
    onKeyEvent: (event) {
      try {
        if (status.error && event.logicalKey == LogicalKey.keyR) {
          _startInstallBitcoindPlugin();
          return true;
        }
        if (event.matches(LogicalKey.keyC, ctrl: true)) {
          shutdownApp(0);
          return true;
        }
        return false;
      } catch (e, st) {
        LogService.error('installBitcoindPlugin key handler failed', e, st);
        return true;
      }
    },
    child: Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Installing bitcoind plugin',
            style: TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            status.message ?? 'starting…',
            style: TextStyle(
              color: status.error
                  ? const Color.fromRGB(255, 80, 80)
                  : const Color.fromRGB(220, 220, 220),
            ),
          ),
          if (status.error) ...[
            const SizedBox(height: 1),
            const Text(
              '[r] retry   [Ctrl+C] quit',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ],
      ),
    ),
  );
}
```

- [ ] **Step 7: Verify the wizard test compiles**

```bash
cd tui && dart analyze 2>&1 | tail -5
```

Expected: zero new analyzer errors. (Pre-existing `implementation_imports` infos in dashboard files are fine.)

- [ ] **Step 8: Commit**

```bash
git add tui/lib/src/ui/views/setup_view.dart
git commit -m "$(cat <<'EOF'
feat(setup): installBitcoindPlugin auto-step before LN backend pick

After setPassword the wizard now fetches the bitcoind plugin via
PluginService.install. On success seeds app_configs.bitcoind with
sane defaults (mainnet, pruned, 550 GB) and advances to the new
selectLightningBackend step. On failure shows the error with [r]
retry — same recovery posture as buildServices today.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Setup wizard — selectLightningBackend step

Adds a SelectPopup-driven step that lets the operator pick lnd / cln / none. Selected option triggers a `PluginService.install` for the matching plugin.

**Files:**
- Modify: `tui/lib/src/ui/views/setup_view.dart`

- [ ] **Step 1: Add a state provider for the selection**

Near `_pluginInstallStatusProvider`:

```dart
/// Holds the operator's selection from the SelectPopup. null until
/// they pick something.
final _lightningBackendChoiceProvider = StateProvider<String?>((ref) => null);
```

- [ ] **Step 2: Add the install method**

```dart
bool _selectLightningStarted = false;

void _startInstallLightningBackend(String backend) {
  if (_selectLightningStarted) return;
  _selectLightningStarted = true;

  if (backend == 'none') {
    LogService.info('selectLightningBackend: operator chose none');
    _markStepCompleted(SetupStep.selectLightningBackend);
    context.read(_setupStepProvider.notifier).state = SetupStep.buildServices;
    return;
  }

  final url = backend == 'lnd'
      ? 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/lnd'
      : 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/cln';

  context.read(_pluginInstallStatusProvider.notifier).state = (
    message: 'Fetching $backend plugin from forge…',
    error: false,
  );

  final pluginService = context.read(pluginServiceProvider);
  pluginService
      .install(url)
      .then((marker) {
        if (!mounted) return;
        LogService.info(
          'selectLightningBackend: installed $backend (rev=${marker.rev})',
        );

        // Seed app_configs.<backend>.enabled = true.
        final configService = context.read(configServiceProvider);
        final cfg = context.read(configProvider).value;
        if (cfg != null) {
          final apps = Map<String, Map<String, dynamic>>.from(cfg.appConfigs);
          apps[backend] = {
            'enabled': true,
            ...?apps[backend],
          };
          final updated = cfg.copyWith(appConfigs: apps);
          configService.writeConfigSync(updated);
          context.read(configProvider.notifier).updateConfig(updated);
        }

        _markStepCompleted(SetupStep.selectLightningBackend);
        context.read(_setupStepProvider.notifier).state =
            // Skip alias step for cln (no alias config field).
            backend == 'lnd'
                ? SetupStep.setLightningAlias
                : SetupStep.buildServices;
      })
      .catchError((e, st) {
        LogService.error('selectLightningBackend failed for $backend', e, st);
        if (!mounted) return;
        context.read(_pluginInstallStatusProvider.notifier).state = (
          message: 'Install failed: $e',
          error: true,
        );
        _selectLightningStarted = false; // allow retry
      });
}
```

- [ ] **Step 3: Add the build method**

```dart
Component _buildSelectLightningBackend() {
  final status = context.watch(_pluginInstallStatusProvider);
  final choice = context.watch(_lightningBackendChoiceProvider);

  // If a choice has been made and install is in flight or errored,
  // show the install status. Otherwise show the picker.
  if (choice != null && status.message != null) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (status.error && event.logicalKey == LogicalKey.keyR) {
            _startInstallLightningBackend(choice);
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('selectLightningBackend retry failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installing $choice plugin',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              status.message ?? '',
              style: TextStyle(
                color: status.error
                    ? const Color.fromRGB(255, 80, 80)
                    : const Color.fromRGB(220, 220, 220),
              ),
            ),
            if (status.error) ...[
              const SizedBox(height: 1),
              const Text(
                '[r] retry',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  return SelectPopup(
    title: 'Choose Lightning backend',
    description:
        'Pick the Lightning Network implementation for this node. '
        'You can change it later by enabling/disabling plugins.',
    options: const [
      SelectPopupOption(value: 'lnd', label: 'LND (Lightning Network Daemon)'),
      SelectPopupOption(value: 'cln', label: 'Core Lightning (CLN)'),
      SelectPopupOption(value: 'none', label: 'None — bitcoin-only node'),
    ],
    onSelect: (value) {
      context.read(_lightningBackendChoiceProvider.notifier).state = value;
      _startInstallLightningBackend(value);
    },
  );
}
```

- [ ] **Step 4: Verify SelectPopup's API**

The exact `SelectPopup` constructor / option type may differ; check before committing:

```bash
grep -nE "class SelectPopup|class SelectPopupOption" tui/lib/src/ui/widgets/select_popup.dart 2>&1 | head -5
```

If the option type is named differently, update the build method accordingly. The flow (title + description + options + onSelect) is the contract.

- [ ] **Step 5: Run analyzer**

```bash
just analyze 2>&1 | tail -5
```

Expected: 6 pre-existing infos, no new errors.

- [ ] **Step 6: Run tests**

```bash
just test 2>&1 | tail -3
```

Expected: All tests passed.

- [ ] **Step 7: Commit**

```bash
git add tui/lib/src/ui/views/setup_view.dart
git commit -m "$(cat <<'EOF'
feat(setup): selectLightningBackend SelectPopup step

After installBitcoindPlugin the wizard pops a SelectPopup with
lnd / cln / none. Selection installs the matching plugin via
PluginService.install (or no-ops for "none") and seeds
app_configs.<id>.enabled = true. lnd advances to setLightningAlias
for the alias prompt; cln/none skip directly to buildServices.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Drop bundled bitcoin/lightning tile manifests + bundled bitcoind/lnd/cln config schemas

The plugins now own these. Delete the bundled copies and regenerate the codegen outputs.

**Files:**
- Delete: `common/lib/src/services/dashboard/bundled/manifests/bitcoin.json`
- Delete: `common/lib/src/services/dashboard/bundled/manifests/lightning.json`
- Delete: `common/lib/src/services/configure/bundled/manifests/bitcoind.json`
- Delete: `common/lib/src/services/configure/bundled/manifests/lnd.json`
- Delete: `common/lib/src/services/configure/bundled/manifests/cln.json`
- Modify: `common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart` (regenerated)
- Modify: `common/lib/src/services/configure/bundled/embedded_schemas.g.dart` (regenerated)
- Modify: `common/test/services/configure/bundled/registry_test.dart`
- Modify: `common/test/services/configure/bundled/manifests_test.dart`

- [ ] **Step 1: Delete the bundled manifests**

```bash
rm common/lib/src/services/dashboard/bundled/manifests/bitcoin.json
rm common/lib/src/services/dashboard/bundled/manifests/lightning.json
rm common/lib/src/services/configure/bundled/manifests/bitcoind.json
rm common/lib/src/services/configure/bundled/manifests/lnd.json
rm common/lib/src/services/configure/bundled/manifests/cln.json
ls common/lib/src/services/dashboard/bundled/manifests/
ls common/lib/src/services/configure/bundled/manifests/
```

Expected: dashboard/bundled/manifests/ shows only `hardware.json` + `system.json`. configure/bundled/manifests/ is empty.

- [ ] **Step 2: Regenerate codegen**

```bash
just gen-manifests
just gen-app-schemas
```

Expected: prints "Generated 2 manifests" (hardware + system) and "Generated 0 app manifests".

- [ ] **Step 3: Update the registry test**

Edit `common/test/services/configure/bundled/registry_test.dart` to drop the now-deleted entries. The expected list shrinks to empty:

```dart
import 'package:common/src/services/configure/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledAppManifests', () {
    test('is empty after bitcoind/lnd/cln were extracted to plugins', () {
      // bitcoind, lnd, cln, blitz_api, blitz_web all live as plugins
      // (nixblitz_official_plugins/{bitcoind,lnd,cln,blitz-api,blitz-web}).
      // Nothing ships as a built-in app any more.
      expect(bundledAppManifests, isEmpty);
    });
  });
}
```

- [ ] **Step 4: Update the manifests test**

Edit `common/test/services/configure/bundled/manifests_test.dart` to drop everything. The remaining body should be:

```dart
import 'package:test/test.dart';

void main() {
  test('no bundled app manifests ship in the binary', () {
    // All apps have been extracted into plugins. This file's
    // existence preserves the test path so future bundled-shape
    // additions land here, but the body is intentionally minimal.
    expect(true, isTrue);
  });
}
```

- [ ] **Step 5: Run common tests**

```bash
cd common && dart test 2>&1 | tail -5
```

Expected: All tests passed.

- [ ] **Step 6: Commit**

```bash
git add -A common/lib/src/services/dashboard/bundled/manifests/ \
       common/lib/src/services/configure/bundled/manifests/ \
       common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart \
       common/lib/src/services/configure/bundled/embedded_schemas.g.dart \
       common/test/services/configure/bundled/registry_test.dart \
       common/test/services/configure/bundled/manifests_test.dart
git commit -m "$(cat <<'EOF'
refactor: drop bundled bitcoin/lightning tile + bitcoind/lnd/cln config

These ship inside the bitcoind / lnd / cln plugins now. The TUI
binary no longer carries built-in app manifests; the only
remaining bundled tile manifests are system + hardware (read
procfs, no plugin dep).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Drop `templates/modules/apps/{bitcoind,lnd,cln}.nix` + clean up flake / installed.nix

The plugin NixOS modules replace the templates wrappers. nix-bitcoin drops out of `templates/flake.nix` inputs entirely. `templates/hosts/installed.nix`'s `features.apps.{bitcoind,lnd,cln}.*` block goes away.

**Files:**
- Delete: `templates/modules/apps/bitcoind.nix`
- Delete: `templates/modules/apps/lnd.nix`
- Delete: `templates/modules/apps/cln.nix`
- Modify: `templates/flake.nix`
- Modify: `templates/hosts/installed.nix`
- Modify: `templates/modules/system/base.nix`
- Modify: `common/lib/src/services/embedded_templates.g.dart` (regenerated)

- [ ] **Step 1: Delete the wrapper modules**

```bash
rm templates/modules/apps/bitcoind.nix
rm templates/modules/apps/lnd.nix
rm templates/modules/apps/cln.nix
ls templates/modules/apps/
```

Expected: directory is empty (or doesn't exist depending on whether other apps were ever there).

- [ ] **Step 2: Drop the `features.apps.{bitcoind,lnd,cln}.*` block from `installed.nix`**

Edit `templates/hosts/installed.nix`. Find this block (around lines 63-72):

```nix
features.apps.bitcoind.enable = appEnabled "bitcoind";
features.apps.bitcoind.network = appOpt "bitcoind" "network" "mainnet";
features.apps.bitcoind.pruned = appOpt "bitcoind" "pruned" false;
features.apps.bitcoind.pruneSizeGb = appOpt "bitcoind" "prune_size_gb" 0;

features.apps.lnd.enable = appEnabled "lnd";
features.apps.lnd.alias = appOpt "lnd" "alias" "";

features.apps.cln.enable = appEnabled "cln";
```

Replace with a comment explaining the move:

```nix
# bitcoind / lnd / cln were built-in apps before; they're plugins
# now (forge.f44.fyi/f44/nixblitz_official_plugins/{bitcoind,lnd,cln}).
# The plugin loop in templates/flake.nix imports their plugin.nix
# files based on plugins.list + app_configs.<id>.enabled. Operators
# install via `nixblitz plugin add ...` or the setup wizard.
```

- [ ] **Step 3: Drop `nix-bitcoin.generateSecrets` from `base.nix`**

In `templates/modules/system/base.nix`, find:

```nix
# nix-bitcoin secrets management
nix-bitcoin.generateSecrets = true;
```

Delete those two lines. (The plugins set this with `mkDefault true` in their own config blocks.)

- [ ] **Step 4: Drop `nix-bitcoin` from `templates/flake.nix`**

In `templates/flake.nix`, remove:

1. The `nix-bitcoin = { url = ...; inputs.nixpkgs.follows = "nixpkgs"; };` block from `inputs`.
2. `nix-bitcoin,` from the `outputs = { ... }` argument list.
3. `nix-bitcoin.nixosModules.default` from the `nixosModules.default` imports list.

Replace each with a brief comment block:

```nix
# nix-bitcoin used to be an input here, but it's pulled by the
# bitcoind / lnd / cln plugins now via builtins.getFlake at a
# coordinated rev. The operator's flake input list is shorter for it.
```

- [ ] **Step 5: Validate Nix syntax**

```bash
nix-instantiate --parse templates/flake.nix > /dev/null && echo "flake ok"
nix-instantiate --parse templates/hosts/installed.nix > /dev/null && echo "installed ok"
nix-instantiate --parse templates/modules/system/base.nix > /dev/null && echo "base ok"
alejandra templates/flake.nix templates/hosts/installed.nix templates/modules/system/base.nix 2>&1 | tail -3
```

Expected: three "ok" lines + alejandra-clean.

- [ ] **Step 6: Regenerate embedded templates**

```bash
just gen-templates
```

Expected: prints "Generated N templates" with N reduced by 3 (the deleted apps modules).

- [ ] **Step 7: Run trio**

```bash
just analyze 2>&1 | tail -3
just test 2>&1 | tail -3
just format 2>&1 | tail -3
```

Expected: 6 analyzer infos (pre-existing), all tests pass, formatter clean.

- [ ] **Step 8: Commit**

```bash
git add -A templates/ common/lib/src/services/embedded_templates.g.dart
git commit -m "$(cat <<'EOF'
refactor(templates): drop nix-bitcoin input + bitcoind/lnd/cln wrappers

The bitcoind / lnd / cln plugins own their NixOS modules now and
pull nix-bitcoin via builtins.getFlake at a coordinated rev. So
templates/flake.nix loses the nix-bitcoin flake input entirely,
templates/hosts/installed.nix loses the features.apps.{...}.*
wiring block, and templates/modules/system/base.nix loses the
nix-bitcoin.generateSecrets call (each plugin sets it with
mkDefault). Wrapper modules deleted.

Operator's flake.lock will be one input shorter on the next
`nix flake update`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: NixblitzConfig.defaults() drops bitcoind/lnd/cln

Plugin scaffolds these on install; defaults() shouldn't pre-seed them. Empty appConfigs map matches the "fresh node has no apps yet" semantic.

**Files:**
- Modify: `common/lib/src/models/nixblitz_config.dart`
- Modify: `common/test/models/nixblitz_config_test.dart`

- [ ] **Step 1: Update defaults()**

In `common/lib/src/models/nixblitz_config.dart`, find `factory NixblitzConfig.defaults()` (around line 136-149) and change to:

```dart
factory NixblitzConfig.defaults() => NixblitzConfig(
  system: SystemConfig.defaults(),
  appConfigs: const {},
);
```

The seeding now happens in the wizard's `installBitcoindPlugin` step (which writes `app_configs.bitcoind` with sane defaults) and the `selectLightningBackend` step (which writes `app_configs.<backend>.enabled = true`).

- [ ] **Step 2: Update the defaults test**

In `common/test/models/nixblitz_config_test.dart`, find any test that asserts on the pre-existing default app entries (around line 175 in the v18 round-trip test) and update — defaults are now empty, but the round-trip test that constructs a config WITH app_configs entries should still pass since it provides them explicitly.

The most impacted test is likely the `defaults()` smoke test. Find it and update to:

```dart
test('defaults() has empty app_configs', () {
  final c = NixblitzConfig.defaults();
  expect(c.appConfigs, isEmpty);
  expect(c.system.hostname, 'nixblitz');
});
```

- [ ] **Step 3: Run common tests**

```bash
cd common && dart test test/models/nixblitz_config_test.dart 2>&1 | tail -5
```

Expected: All tests passed.

- [ ] **Step 4: Commit**

```bash
git add common/lib/src/models/nixblitz_config.dart \
        common/test/models/nixblitz_config_test.dart
git commit -m "$(cat <<'EOF'
refactor(config): defaults() drops bitcoind/lnd/cln from app_configs

Apps live as plugins now. The setup wizard's installBitcoindPlugin
step seeds app_configs.bitcoind with the right defaults; the
selectLightningBackend step seeds the chosen LN backend. defaults()
returns an empty app_configs map — same shape as a fresh
post-install before the wizard runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: CI consistency checks (nix-bitcoin rev + lightning tile byte-identity)

A small bash test ensuring the three plugins agree on `nix-bitcoin` rev + that `tile-lightning.json` is byte-identical between `lnd` and `cln`. Wired into `just test` so CI catches drift.

**Files:**
- Create: `tests/scripts/check-plugin-consistency.sh`
- Modify: `justfile`

- [ ] **Step 1: Write the script**

Create `tests/scripts/check-plugin-consistency.sh`:

```bash
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
```

Make executable:

```bash
chmod +x tests/scripts/check-plugin-consistency.sh
```

- [ ] **Step 2: Wire into the justfile**

Add a recipe to `justfile` (place near `test`):

```nu
# Check that bitcoind/lnd/cln plugins agree on nix-bitcoin rev + share
# the same lightning tile manifest (CI invariant).
check-plugin-consistency:
  bash tests/scripts/check-plugin-consistency.sh
```

Update the `test` recipe to also run this check. Find the existing `test` recipe (around line 14) and add at the end of its body (after the `dart test` line):

```nu
  # Plugin consistency invariants — bash script, fast.
  bash tests/scripts/check-plugin-consistency.sh
```

- [ ] **Step 3: Run the check**

```bash
just check-plugin-consistency
```

Expected:

```
==> Checking nix-bitcoin rev consistency
  bitcoind: <40-char SHA>
  lnd: <same SHA>
  cln: <same SHA>
  ✅ all three plugins agree on nix-bitcoin rev
==> Checking lnd/cln tile-lightning.json byte identity
  ✅ tile-lightning.json byte-identical
```

- [ ] **Step 4: Run full trio**

```bash
just test 2>&1 | tail -10
just analyze 2>&1 | tail -3
just format 2>&1 | tail -3
```

Expected: All tests pass (including the new consistency check), analyzer at the same 6 pre-existing infos, formatter clean.

- [ ] **Step 5: Commit**

```bash
git add tests/scripts/check-plugin-consistency.sh justfile
git commit -m "$(cat <<'EOF'
test(plugins): CI check for nix-bitcoin rev + lightning tile consistency

Asserts the bitcoind/lnd/cln plugins all pin the same
nix-bitcoin rev (otherwise the operator ends up with multiple
nixpkgs snapshots from each plugin's getFlake, bloating the
closure). Also asserts the lnd/cln lightning tile manifest is
byte-identical so operators on either backend see the same tile.
Wired into `just test`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: VM validation walk-through

Manually exercise the full install + wizard flow on a clean x86 VM to confirm the architecture works end-to-end.

**Files:**
- None (this is operator validation, not a code change)

- [ ] **Step 1: Clean VM**

```bash
just vm-clean
just vm-boot
```

Wait for the VM to boot to the live ISO shell.

- [ ] **Step 2: Run the installer TUI from the live ISO**

```bash
just vm-ssh-installer
```

Inside the SSH session:

```bash
nix run github:fusion44/nixblitz_ng
```

Verify the wizard steps:
- setPassword prompts (works as before)
- **NEW:** installBitcoindPlugin auto-fires after password set, fetches plugin from forge, advances. If forge unreachable, error + retry shown.
- **NEW:** selectLightningBackend pops a SelectPopup with three options. Pick `lnd`.
- setLightningAlias prompts for alias (or skipped for cln/none).
- buildServices runs nixos-rebuild. Should succeed.

- [ ] **Step 3: Reboot into installed system**

```bash
just vm-ssh
```

Inside, run:

```bash
nixblitz
```

Verify:
- Dashboard renders.
- Bitcoin tile + Lightning tile both populate (data from the new bash streamers, not blitz-api).
- `~/nixblitz/plugins/` contains `bitcoind/` and `lnd/` (or `cln/`) directories.
- `~/nixblitz/plugins.list` lists both.
- `cat ~/nixblitz/config.json` shows `app_configs.bitcoind.enabled = true` and `app_configs.lnd.enabled = true`.

- [ ] **Step 4: Verify plugin services are running**

```bash
systemctl status bitcoind lnd  # or clightning
```

Expected: both active (running).

- [ ] **Step 5: Document any gaps**

If anything fails, capture:
- `~/nixblitz.log` from the VM
- `journalctl -b -p err`
- The state of `~/nixblitz/` (plugins.list, config.json, plugins/ tree)

File issues for any blocker; small adjustments can be folded into a follow-up commit.

- [ ] **Step 6: Clean up**

```bash
just vm-clean
```

No commit — this task is just validation.

---

## Self-review

**Spec coverage check** (against the design summary in the plan invocation):

- Wide scope: each plugin owns config schema, NixOS module body, tile manifest, streamer ✅ (Tasks 4-6)
- nix-bitcoin via getFlake at coordinated rev ✅ (Tasks 4, 5, 6, 1, 12)
- nix-bitcoin dropped from templates/flake.nix ✅ (Task 10)
- mkDefault on nix-bitcoin.generateSecrets in plugins ✅ (Tasks 4, 5, 6)
- Wizard installBitcoindPlugin step ✅ (Task 7)
- Wizard selectLightningBackend SelectPopup step ✅ (Task 8)
- setLightningAlias skip for cln/none ✅ (Task 8 — done via the next-step branching)
- Resumability via setup_step_completed ✅ (Tasks 7, 8 — both call _markStepCompleted)
- plugin.json gains tile_manifests[] field ✅ (Task 2)
- schema_version 2 → 3 ✅ (Task 2)
- Streamer language: bash + jq ✅ (Tasks 4-6)
- lightning tile byte-identical CI check ✅ (Task 12)
- test-lnd untouched ✅ (no task touches `templates/modules/system/test-lnd.nix`)
- system + hardware bundled tile manifests stay ✅ (Task 9 only deletes bitcoin + lightning)
- No migration code ✅ (no migration task)
- features.apps.{bitcoind,lnd,cln}.* deleted ✅ (Task 10)
- appEnabled / appOpt helpers stay ✅ (Task 10 only touches the wiring block, not helpers)
- Plugin id matches existing app_configs key ✅ (Tasks 4, 5, 6 — plugin id = `bitcoind` / `lnd` / `cln`)

**Placeholder scan:** No `TBD`, `TODO`, `add error handling`, or `similar to Task N`-style references. The `__NIX_BITCOIN_REV__` token is a substitution marker explicitly resolved in each task via `sed` against `/tmp/nix-bitcoin-rev.txt` (set in Task 1) — concrete mechanism, not a placeholder.

**Type consistency:** `tileManifests` field name used in Tasks 2, 3 (camelCase), corresponding JSON key `tile_manifests` (snake_case) used in Tasks 4-6. `currentPluginManifestVersion` bumped to 3 in Task 2 and referenced consistently. `pluginCfg`, `enabled`, `nixBitcoinRev` names match across the three plugin.nix files.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-10-bitcoin-family-plugin-extraction.md`. Two execution options:

1. **Subagent-Driven** (recommended) — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — I execute tasks in this session via executing-plans, batch with checkpoints for review.

Which approach?
