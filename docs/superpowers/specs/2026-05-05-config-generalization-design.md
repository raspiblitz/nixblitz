# Config Generalization — Phase 2 Design

**Date:** 2026-05-05
**Status:** Draft
**Tracking:** Phase 2 of "extract bitcoind/lnd/cln/blitz-api/blitz-web into plugins"

## Goal

Drop the typed `bitcoind`, `lnd`, `cln`, `blitzApi`, `blitzWeb` fields from
`NixblitzConfig` and route their config through a generic
`Map<String, Map<String, dynamic>> appConfigs` storage. After Phase 2 the
`NixblitzConfig` model carries only `system` (always-on identity) plus
`appConfigs`. The five typed config classes are deleted. The JSON config-file
shape changes correspondingly via a v17→v18 migration. Nix templates iterate
the generic shape instead of reading named keys.

This phase makes the code structurally agnostic to which apps are installed:
laying the groundwork for Phases 4–6 to actually move each app's `.nix` module
into a plugin. After Phase 2, nixblitz can in principle boot without bitcoind
(or lnd, or any of them) — useful long-term for "homelab base" use cases the
user wants to enable.

## Non-goals (deferred)

- **Moving any Nix module into a plugin.** Phases 4–6. The five apps' `.nix`
  files stay in `templates/modules/apps/` for now.
- **Plugin dependencies.** No plugin exists yet in Phase 2; the question of
  how lnd declares "I need bitcoind" is settled when Phase 4 actually creates
  inter-plugin deps.
- **Generalising `configure_view.dart`'s 900-line switch tree.** Phase 3.
  Phase 2 only mechanically updates its data-access call sites to the generic
  API; the structural rewrite (manifest-driven field rendering, dynamic menu
  items) is Phase 3.
- **Generalising the install wizard.** Phase 3 — install_view.dart's hardcoded
  `_LightningChoice { lnd, cln, none }` enum stays for Phase 2; the wizard's
  data writes go through the generic API but the structure stays.
- **Removing the regtest auto-enable logic for `test-lnd`.** Stays as Nix-level
  coupling until Phase 4.

## Architecture

### Today

```
NixblitzConfig
├── system          : SystemConfig    (typed)
├── bitcoind        : BitcoindConfig  (typed: enabled, network, pruned, prune_size_gb)
├── lnd             : LndConfig       (typed: enabled, alias)
├── cln             : ClnConfig       (typed: enabled)
├── blitzApi        : BlitzApiConfig  (typed: enabled)
└── blitzWeb        : BlitzWebConfig  (typed: enabled)
```

JSON:

```jsonc
{
  "schema_version": 17,
  "system": { "hostname": "...", "platform": "..." },
  "bitcoind": {
    "enabled": true,
    "network": "regtest",
    "pruned": false,
    "prune_size_gb": 0,
  },
  "lnd": { "enabled": true, "alias": "..." },
  "cln": { "enabled": false },
  "blitz_api": { "enabled": true },
  "blitz_web": { "enabled": true },
}
```

### After Phase 2

```
NixblitzConfig
├── schemaVersion : int                                          (typed)
├── system        : SystemConfig                                  (typed, unchanged)
└── appConfigs    : Map<String, Map<String, dynamic>>            (generic)
```

JSON:

```jsonc
{
  "schema_version": 18,
  "system": { "hostname": "...", "platform": "..." },
  "app_configs": {
    "bitcoind": {
      "enabled": true,
      "network": "regtest",
      "pruned": false,
      "prune_size_gb": 0,
    },
    "lnd": { "enabled": true, "alias": "..." },
    "cln": { "enabled": false },
    "blitz_api": { "enabled": true },
    "blitz_web": { "enabled": true },
  },
}
```

`SystemConfig` keeps its typed fields and `fromJson`/`toJson`. The five
extracted apps lose their typed wrappers entirely; they're just nested maps.

## JSON migration v17 → v18

`common/lib/src/models/config_migrations.dart` already has 16 migrations
shaped as `(json) => json'` functions. Add v17→v18:

```dart
// migrations[17] = (json) { … move 5 top-level keys into app_configs … };
Map<String, dynamic> _migrateV17ToV18(Map<String, dynamic> json) {
  final apps = <String, dynamic>{};
  for (final key in const ['bitcoind', 'lnd', 'cln', 'blitz_api', 'blitz_web']) {
    if (json.containsKey(key)) {
      apps[key] = json[key];
      json.remove(key);
    }
  }
  json['app_configs'] = apps;
  return json;
}
```

Idempotent: running on a v18-shaped JSON is a no-op (the keys won't be at the
root). Test corpus covers (a) full v17 with all five keys, (b) partial v17
(some keys missing — which can happen on installs that disabled an app
before-bump), (c) re-running on v18 (no-op).

## `NixblitzConfig` refactor

```dart
@immutable
class NixblitzConfig {
  final int schemaVersion;
  final SystemConfig system;
  final Map<String, Map<String, dynamic>> appConfigs;

  const NixblitzConfig({
    required this.schemaVersion,
    required this.system,
    this.appConfigs = const {},
  });

  /// Read a single config value for an app. Returns null if the app or key
  /// is missing, OR if the stored value's type doesn't match T.
  T? appOption<T>(String app, String key) {
    final m = appConfigs[app];
    if (m == null) return null;
    final v = m[key];
    return v is T ? v : null;
  }

  /// Read an app's whole config map (empty map if app is absent).
  Map<String, dynamic> appConfig(String app) =>
      appConfigs[app] ?? const {};

  /// Returns whether an app is enabled. Convenience over
  /// `appOption<bool>(app, 'enabled') ?? false`.
  bool isAppEnabled(String app) => appOption<bool>(app, 'enabled') ?? false;

  /// Set a single value, returning a new NixblitzConfig. Creates the app
  /// entry if absent.
  NixblitzConfig setAppOption(String app, String key, dynamic value) {
    final next = {
      ...appConfigs,
      app: {...appConfigs[app] ?? const {}, key: value},
    };
    return copyWith(appConfigs: next);
  }

  /// Toggle a bool option; convenience over read+set.
  NixblitzConfig toggleAppOption(String app, String key) {
    final current = appOption<bool>(app, key) ?? false;
    return setAppOption(app, key, !current);
  }

  /// Replace an app's whole config.
  NixblitzConfig setAppConfig(String app, Map<String, dynamic> config) {
    final next = {...appConfigs, app: config};
    return copyWith(appConfigs: next);
  }

  /// Remove an app's config entirely (for plugin-uninstall scenarios in
  /// later phases; harmless if app is absent).
  NixblitzConfig removeAppConfig(String app) {
    if (!appConfigs.containsKey(app)) return this;
    final next = {...appConfigs}..remove(app);
    return copyWith(appConfigs: next);
  }

  NixblitzConfig copyWith({
    int? schemaVersion,
    SystemConfig? system,
    Map<String, Map<String, dynamic>>? appConfigs,
  }) => NixblitzConfig(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    system: system ?? this.system,
    appConfigs: appConfigs ?? this.appConfigs,
  );

  factory NixblitzConfig.fromJson(Map<String, dynamic> json) { … }
  Map<String, dynamic> toJson() { … }
  // … equality & hashCode …
}
```

## Deleted typed classes

The following classes are **deleted** in Phase 2:

- `BitcoindConfig` (and its `BitcoinNetwork` enum lives somewhere shared — see
  below)
- `LndConfig`
- `ClnConfig`
- `BlitzApiConfig`
- `BlitzWebConfig`

`BitcoinNetwork` (the `mainnet | testnet | regtest | signet` enum) is **kept**
under a new home at `common/lib/src/models/bitcoin_network.dart`. It's
referenced by the install wizard (network choice menu), the dashboard chrome
(network indicator), and Nix template generation. Moving it out of
`BitcoindConfig` lets it survive the typed-class deletion.

## Call-site updates

Mechanical rewrite of every `config.X.field` → `config.appOption('X', 'field')`
and `config.copyWith(X: …)` → `config.setAppOption('X', 'field', value)`.

Call sites by file:

- `tui/lib/src/ui/views/configure_view.dart` (~30 typed-field reads, ~20
  copyWith chains): mechanical rewrite. Switch tree structure stays —
  Phase 3 does the structural generalization.
- `tui/lib/src/ui/views/install_view.dart` (`_LightningChoice` apply path,
  bitcoind network choice): rewrite to `setAppOption`.
- `tui/lib/src/ui/views/setup_view.dart` (lnd seed display gates on
  `config.lnd.enabled`): rewrite to `isAppEnabled('lnd')`. The seed-file path
  (`/mnt/data/lnd/lnd-seed-mnemonic`) stays hardcoded for Phase 2 — it's a
  Nix-side path, only relevant once lnd is enabled.
- `tui/lib/src/ui/views/dashboard_view.dart` chrome construction (currently
  reads `config.bitcoind.network`): rewrite to
  `config.appOption<String>('bitcoind', 'network')`. Returns null if the
  bitcoind app isn't configured; chrome already accepts a nullable network
  and drops the segment when null.
- `common/lib/src/services/system_service.dart` (status polling list — uses
  named services): no change to data structure, but the unit list will
  eventually be derived from `appConfigs.keys`. Phase 2 hardcodes it (matches
  current behaviour); Phase 3 generalises.

## Nix template rewrite

`templates/hosts/installed.nix` currently has:

```nix
{
  config = let
    cfg = builtins.fromJSON (builtins.readFile ./config.json);
  in {
    features.apps.bitcoind.enable = initialized && cfg.bitcoind.enabled;
    features.apps.bitcoind.network = cfg.bitcoind.network;
    features.apps.bitcoind.pruned = cfg.bitcoind.pruned;
    features.apps.bitcoind.pruneSizeGb = cfg.bitcoind.prune_size_gb;
    features.apps.lnd.enable = initialized && cfg.lnd.enabled;
    features.apps.lnd.alias = cfg.lnd.alias;
    # … etc for cln, blitz_api, blitz_web …
  };
}
```

After Phase 2:

```nix
{
  config = let
    cfg = builtins.fromJSON (builtins.readFile ./config.json);
    apps = cfg.app_configs or {};
    appOpt = name: key: default:
      let m = apps.${name} or {}; in m.${key} or default;
    appEnabled = name: initialized && (appOpt name "enabled" false);
  in {
    features.apps.bitcoind.enable      = appEnabled "bitcoind";
    features.apps.bitcoind.network     = appOpt "bitcoind" "network" "mainnet";
    features.apps.bitcoind.pruned      = appOpt "bitcoind" "pruned" false;
    features.apps.bitcoind.pruneSizeGb = appOpt "bitcoind" "prune_size_gb" 0;
    features.apps.lnd.enable           = appEnabled "lnd";
    features.apps.lnd.alias            = appOpt "lnd" "alias" "";
    features.apps.cln.enable           = appEnabled "cln";
    features.apps.blitz-api.enable     = appEnabled "blitz_api";
    features.apps.blitz-web.enable     = appEnabled "blitz_web";
    # …regtest auto-enable for test-lnd, etc., stays as-is, just reading
    # the appOpt-derived values…
  };
}
```

The `appOpt` / `appEnabled` helpers are local-let lambdas; no Nix-level
"plugin" concept yet, just cleaner JSON access.

`templates/configuration.nix` and `templates/modules/apps/*.nix` don't change
— they consume `features.apps.X.*` options that are still set per-named-app
above. Phases 4–6 lift those module imports out into plugins.

## Dashboard chrome adaptation

`tui/lib/src/ui/views/dashboard_view.dart` constructs `DashboardChrome` with:

```dart
DashboardChrome(
  hostname: config?.system.hostname ?? '?',
  platform: config?.system.platform ?? '?',
  network:  config?.bitcoind.network ?? 'unknown',
  …
)
```

Becomes:

```dart
DashboardChrome(
  hostname: config?.system.hostname ?? '?',
  platform: config?.system.platform ?? '?',
  network:  config?.appOption<String>('bitcoind', 'network'),
  …
)
```

`DashboardChrome` accepts `String? network` (nullable) and drops the network
segment from line 1 when null. This means the homelab base case (no bitcoind
configured) shows just `hostname · platform`. Realistic and correct.

## File-level changes

**Modified:**

- `common/lib/src/models/nixblitz_config.dart` — full rewrite of
  `NixblitzConfig`; deletion of typed config classes.
- `common/lib/src/models/config_migrations.dart` — add v17→v18 migration.
- `common/lib/src/services/config_service.dart` — verify still works against
  the new model (it shouldn't have hardcoded knowledge of the typed apps; if
  it does, simplify).
- `common/lib/src/services/scaffold_service.dart` — initialises
  `app_configs: {}` on fresh installs; previously created the five typed
  blocks.
- `templates/hosts/installed.nix` — generic `appOpt` / `appEnabled` helpers,
  iterate the five known apps.
- `tui/lib/src/ui/views/configure_view.dart` — mechanical call-site rewrite
  (~50 sites).
- `tui/lib/src/ui/views/install_view.dart` — wizard writes via `setAppOption`.
- `tui/lib/src/ui/views/setup_view.dart` — `isAppEnabled('lnd')` etc.
- `tui/lib/src/ui/views/dashboard_view.dart` — chrome `network` arg via
  `appOption`.
- `tui/lib/src/ui/views/dashboard/dashboard_chrome.dart` — accept nullable
  network; drop segment when null.

**New:**

- `common/lib/src/models/bitcoin_network.dart` — relocated `BitcoinNetwork`
  enum + helpers.
- `common/test/models/nixblitz_config_test.dart` (extended) — appOption,
  setAppOption, toggleAppOption, removeAppConfig coverage.
- `common/test/models/config_migrations_test.dart` (extended) — v17→v18
  migration cases (full, partial, idempotent).

**Deleted:**

- `BitcoindConfig`, `LndConfig`, `ClnConfig`, `BlitzApiConfig`,
  `BlitzWebConfig` — class definitions inside
  `common/lib/src/models/nixblitz_config.dart` (the file stays; the classes
  go).
- Their unit tests, if separately filed.

**Untouched:**

- `templates/modules/apps/*.nix` — the per-app NixOS modules still work
  unchanged, since they consume `features.apps.X.*` options that
  `installed.nix` continues to set.
- Plugin-related code (`PluginConfigService`, `PluginManifest`, etc.). Phase 2
  doesn't touch the plugin system; the five extracted apps don't become
  plugins until Phase 4–6.

## Testing strategy

### NixblitzConfig

- `appOption` returns null for missing app, missing key, type mismatch.
- `setAppOption` creates app entry when absent; preserves other apps;
  preserves other keys within the same app.
- `toggleAppOption` flips `false` ↔ `true`; missing key starts as `false`
  → `true`.
- `removeAppConfig` is a no-op when app is absent; removes only that app.
- `copyWith` preserves non-overridden fields.
- `fromJson` / `toJson` round-trips, including empty `app_configs`.

### Migrations

- v17 with all five keys → v18 with `app_configs` populated, top-level keys
  removed.
- v17 with three keys present and two missing → v18 with three entries in
  `app_configs`.
- v18 input → v18 output (idempotent).
- Migration chain v0..v18 still works on a real captured fixture from a v0
  fresh install.

### Configure view

- Existing tests should still pass after the call-site rewrite. The view's
  observable behaviour (which options appear, what toggle does) is unchanged
  in Phase 2.

### Install wizard

- LightningChoice apply: `none` writes empty `app_configs.lnd` and
  `app_configs.cln`; `lnd` writes `lnd.enabled = true`, `cln.enabled = false`;
  `cln` writes the inverse.
- Bitcoind network choice writes `app_configs.bitcoind.network`.

### Manual smoke

- Run `nixblitz` against a v17 config.json; verify auto-migration writes back
  v18 shape.
- Verify the dashboard renders correctly post-migration (network indicator
  shows mainnet/regtest based on the migrated value).
- Apply via `[u]: Update`; verify the generated NixOS config builds and
  produces the same `features.apps.*` settings as before the refactor.

## Verification

```bash
just test
just analyze
just format
```

Plus a Pi 5 smoke: deploy, observe auto-migration, check dashboard, apply.

## Phasing handoff

| Phase               | Work                                                                                                                                                                              | Depends on |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| **2** _(this spec)_ | Drop typed config fields, generic `appConfigs`, v17→v18 migration, Nix template generic-loop rewrite                                                                              | 1          |
| 3                   | Generalise `configure_view.dart`: dynamic field rendering from manifests; install wizard discovers LN-capable apps from a registry; debug views read service list from a registry | 2          |
| 4                   | Move blitz-api Nix module into a plugin; rip out `InProcessAdapterSource`; ship `blitz-api-bridge` as a real subprocess streamer in the plugin                                    | 1, 2       |
| 5                   | Move blitz-web Nix module into a plugin (mostly Nix; almost no Dart-side change)                                                                                                  | 2, 4       |
| 6                   | Move lnd, cln Nix modules into plugins                                                                                                                                            | 2, 3, 4    |
| ?                   | Move bitcoind Nix module into a plugin (last because every other LN/api plugin transitively depends on it)                                                                        | 4, 5, 6    |

After Phase 2 alone the dashboard and install flow keep working unchanged
(JSON shape changes are invisible to the UI; the Configure view's structure
is preserved; the Nix template wires the same five apps with the same
options). The big payoff is that NEXT phases have a clean, generic data layer
to build on.

## Decisions (locked in 2026-05-05)

1. **Full restructure (Dart + JSON + Nix templates).** No partial migration.
2. **Auto-migrate via `config_migrations.dart` v17→v18.** Existing test
   install upgrades cleanly; no fresh-install required.
3. **Configure view: mechanical call-site rewrite, no shim, structure
   preserved.** Phase 3 generalises the structure.
4. **Bitcoind config also moves to generic storage** in Phase 2 (consistent
   with the four other extracted apps). Bitcoind's `.nix` module stays in
   core for Phase 2; plugin extraction is a separate, much-later phase.
5. **`SystemConfig` stays as a typed field on `NixblitzConfig`.** Always
   present, always known, dashboard chrome reads it.
6. **`BitcoinNetwork` enum survives `BitcoindConfig` deletion** by relocating
   to its own file. Used by install wizard, dashboard chrome, Nix templates.
7. **Plugin dependency declaration is deferred to Phase 4** when the first
   inter-plugin dep actually exists.
