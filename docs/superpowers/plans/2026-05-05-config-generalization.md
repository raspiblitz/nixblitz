# Config Generalization — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop the typed `bitcoind`, `lnd`, `cln`, `blitzApi`, `blitzWeb` fields from `NixblitzConfig` and route their config through a generic `Map<String, Map<String, dynamic>> appConfigs`. Configuration JSON moves to v18 shape via auto-migration; Nix templates iterate the generic shape; Dart call sites use new generic accessors.

**Architecture:** `NixblitzConfig` ends up with `schemaVersion`, `system` (typed, unchanged), and `appConfigs` (generic). Five typed config classes (`BitcoindConfig`, `LndConfig`, `ClnConfig`, `BlitzApiConfig`, `BlitzWebConfig`) deleted outright; the `BitcoinNetwork` enum survives by relocating to its own file. `templates/hosts/installed.nix` iterates the generic shape via local Nix lambdas. The structural refactor of `configure_view.dart` (manifest-driven field rendering, dynamic menus) is **deferred to Phase 3** — Phase 2 only mechanically rewrites its data-access call sites.

**Tech Stack:** Dart, Riverpod, JSON config + migrations, Nix templating.

**Spec:** `docs/superpowers/specs/2026-05-05-config-generalization-design.md`

---

## File Structure

### Modified files

```
common/lib/src/models/
  nixblitz_config.dart                    # full rewrite of NixblitzConfig; deletion of 5 typed classes
  config_migrations.dart                  # add v17→v18 migration
common/lib/src/services/
  scaffold_service.dart                   # init `app_configs: {}` on fresh installs

tui/lib/src/ui/views/
  configure_view.dart                     # ~50 typed-field call sites → generic API
  install_view.dart                       # wizard writes via setAppOption
  setup_view.dart                         # `isAppEnabled('lnd')` etc.
  dashboard_view.dart                     # chrome network arg via appOption
  dashboard/dashboard_chrome.dart         # accept nullable `network`

templates/hosts/
  installed.nix                           # generic appOpt/appEnabled lambdas
```

### New files

```
common/lib/src/models/
  bitcoin_network.dart                    # relocated BitcoinNetwork enum + helpers
```

### Untouched

- `templates/modules/apps/*.nix` — per-app NixOS modules consume `features.apps.X.*`, which `installed.nix` continues to set per-named-app.
- `common/lib/src/services/dashboard/*` — Phase 1's dashboard pipeline reads through the same `NixblitzConfig` accessors, doesn't care about the underlying storage shape.
- Plugin code (`plugin_*`) — Phase 2 doesn't touch the plugin system; these apps don't become real plugins until Phases 4–6.

---

## Conventions

- **Trio gate** at the end of every task: `just test && just analyze && just format`. Some tasks (3–6) have **intentional intermediate red trio** while call sites catch up — flagged explicitly in those tasks. Trio must be fully green by the end of Task 7.
- **Per-test runs**: `cd common && dart test test/path/foo_test.dart` or `cd tui && dart test test/path/foo_test.dart`.
- **Commit format**: `<type>(<scope>): <subject>` + concise body focused on the why + `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` footer. **No issue refs**.
- **VCS**: jj. Subagents commit per task via `jj commit -m '...'` with HEREDOC.

---

## Task 1: Relocate `BitcoinNetwork` enum

**Files:**
- Create: `common/lib/src/models/bitcoin_network.dart`
- Modify: `common/lib/src/models/nixblitz_config.dart` (remove the enum from `BitcoindConfig`'s file; export from new home)
- Modify: any consumer (search for `BitcoinNetwork` references) — update import paths

**Spec reference:** "Deleted typed classes" section: `BitcoinNetwork` survives by relocation.

**Why first:** Independent prep work. The enum is referenced by the install wizard, dashboard chrome, and Nix template generation; relocating it now means later tasks (which delete `BitcoindConfig`) don't need to also handle the enum migration. Trio stays green.

- [ ] **Step 1: Find current location of `BitcoinNetwork`**

```bash
grep -rn 'enum BitcoinNetwork\|class BitcoinNetwork' common/lib/ tui/lib/ | head -5
grep -rn 'BitcoinNetwork' common/lib/ tui/lib/ | wc -l
```

The enum is currently inside `nixblitz_config.dart` near `BitcoindConfig`. Note all consumer locations.

- [ ] **Step 2: Create `bitcoin_network.dart` with the enum + helpers**

```dart
// common/lib/src/models/bitcoin_network.dart
/// Bitcoin network choice. Used by the install wizard (network choice menu),
/// the dashboard chrome (network indicator), and Nix template generation
/// (regtest auto-enables test-lnd, mainnet/testnet/signet/regtest each
/// drive different bitcoind config defaults).
enum BitcoinNetwork {
  mainnet,
  testnet,
  regtest,
  signet;

  /// Wire-form name (snake_case) — what gets written to JSON and read by
  /// Nix `cfg.app_configs.bitcoind.network`.
  String get wireName => switch (this) {
    BitcoinNetwork.mainnet => 'mainnet',
    BitcoinNetwork.testnet => 'testnet',
    BitcoinNetwork.regtest => 'regtest',
    BitcoinNetwork.signet  => 'signet',
  };

  /// Parse the wire-form name. Returns null on unknown input.
  static BitcoinNetwork? fromWireName(String s) => switch (s) {
    'mainnet' => BitcoinNetwork.mainnet,
    'testnet' => BitcoinNetwork.testnet,
    'regtest' => BitcoinNetwork.regtest,
    'signet'  => BitcoinNetwork.signet,
    _         => null,
  };
}
```

(If the existing enum had different field names — e.g. `name` instead of `wireName` — preserve the existing API to minimize call-site churn.)

- [ ] **Step 3: Remove the enum from its old location and re-import where needed**

Edit `nixblitz_config.dart` to remove the `BitcoinNetwork` enum definition. At the top of the file, add:

```dart
import 'package:common/src/models/bitcoin_network.dart';
```

Then update other consumers — find via:

```bash
grep -rn 'BitcoinNetwork' common/lib/ tui/lib/
```

For each file that uses the enum without already importing the new path, add the import. (Most consumers will already have `nixblitz_config.dart` imported, which transitively re-exports through `import 'package:common/src/models/bitcoin_network.dart';` if you `export` it from `nixblitz_config.dart` — but cleaner to import directly.)

- [ ] **Step 4: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
refactor(config): relocate BitcoinNetwork enum to its own file

BitcoinNetwork has consumers outside BitcoindConfig (install wizard,
dashboard chrome, Nix template generation). Moving it to its own file
lets those consumers import it directly and survives the upcoming
deletion of BitcoindConfig in Phase 2.

No behavior change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add v17→v18 migration to `config_migrations.dart`

**Files:**
- Modify: `common/lib/src/models/config_migrations.dart`
- Modify: `common/test/models/config_migrations_test.dart`

**Spec reference:** "JSON migration v17 → v18" section.

**Why now:** The migration is pure-function logic; can land independently of `NixblitzConfig` refactor. Tested in isolation. Trio green.

- [ ] **Step 1: Read `config_migrations.dart` to understand structure**

```bash
cat common/lib/src/models/config_migrations.dart | head -80
```

Note: the file has a `migrations` list (16 entries) and a `currentSchemaVersion` constant. The migration chain runs from `json['schema_version']` to `currentSchemaVersion`.

- [ ] **Step 2: Write failing tests for the migration**

```dart
// common/test/models/config_migrations_test.dart  (extend existing file)

group('v17 → v18', () {
  test('moves all five typed-app keys into app_configs', () {
    final v17 = <String, dynamic>{
      'schema_version': 17,
      'system': {'hostname': 'h', 'platform': 'p'},
      'bitcoind': {'enabled': true, 'network': 'regtest', 'pruned': false, 'prune_size_gb': 0},
      'lnd': {'enabled': true, 'alias': 'node-1'},
      'cln': {'enabled': false},
      'blitz_api': {'enabled': true},
      'blitz_web': {'enabled': true},
    };
    final v18 = migrateToCurrent(Map.from(v17));   // or whatever the public API is
    expect(v18['schema_version'], 18);
    expect(v18.containsKey('bitcoind'), isFalse);
    expect(v18.containsKey('lnd'), isFalse);
    expect(v18.containsKey('cln'), isFalse);
    expect(v18.containsKey('blitz_api'), isFalse);
    expect(v18.containsKey('blitz_web'), isFalse);
    expect(v18['app_configs'], isA<Map>());
    expect(v18['app_configs']['bitcoind']['enabled'], isTrue);
    expect(v18['app_configs']['lnd']['alias'], 'node-1');
    expect(v18['app_configs']['cln']['enabled'], isFalse);
  });

  test('handles partial v17 (some keys missing)', () {
    final v17 = <String, dynamic>{
      'schema_version': 17,
      'system': {'hostname': 'h', 'platform': 'p'},
      'bitcoind': {'enabled': true, 'network': 'mainnet'},
      // No lnd/cln/blitz_api/blitz_web
    };
    final v18 = migrateToCurrent(Map.from(v17));
    expect(v18['schema_version'], 18);
    expect(v18['app_configs']['bitcoind']['enabled'], isTrue);
    expect(v18['app_configs'].containsKey('lnd'), isFalse);
    expect(v18['app_configs'].containsKey('blitz_api'), isFalse);
  });

  test('idempotent on v18 input', () {
    final v18Input = <String, dynamic>{
      'schema_version': 18,
      'system': {'hostname': 'h', 'platform': 'p'},
      'app_configs': {
        'bitcoind': {'enabled': true, 'network': 'mainnet'},
      },
    };
    final result = migrateToCurrent(Map.from(v18Input));
    expect(result['schema_version'], 18);
    expect(result['app_configs']['bitcoind']['enabled'], isTrue);
    // Nothing accidentally restored at top level
    expect(result.containsKey('bitcoind'), isFalse);
  });
});
```

(Adapt `migrateToCurrent` and `currentSchemaVersion` to whatever the actual public API exposes. Check the existing file.)

- [ ] **Step 3: Implement the v17→v18 migration**

Add to `config_migrations.dart`:

```dart
// migrations[17] — produces v18
Map<String, dynamic> _migrateV17ToV18(Map<String, dynamic> json) {
  final apps = <String, dynamic>{};
  for (final key in const ['bitcoind', 'lnd', 'cln', 'blitz_api', 'blitz_web']) {
    if (json.containsKey(key)) {
      apps[key] = json[key];
      json.remove(key);
    }
  }
  json['app_configs'] = apps;
  json['schema_version'] = 18;
  return json;
}
```

Wire it into the migrations list at index 17 and bump `currentSchemaVersion` to 18.

- [ ] **Step 4: Run tests + trio + commit**

```bash
cd common && dart test test/models/config_migrations_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(config): add v17→v18 migration moving typed app keys to app_configs

Reshapes the five typed-app top-level keys (bitcoind, lnd, cln,
blitz_api, blitz_web) into a generic `app_configs` map. Idempotent on
v18 input. Handles partial v17 configs (some apps missing from old
shape).

NixblitzConfig itself still reads v17 typed shape — Task 3 swaps it to
read v18. Until then this migration logic exists but isn't yet exercised
by the live load path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Refactor `NixblitzConfig` — generic storage, drop typed classes

**Files:**
- Modify (full rewrite of relevant sections): `common/lib/src/models/nixblitz_config.dart`
- Modify: `common/test/models/nixblitz_config_test.dart`

**Spec reference:** `NixblitzConfig` refactor section + Deleted typed classes.

**Why now:** Migration is in place; can now drop typed fields. **Trio will be RED** after this task — every call site of `config.bitcoind`, `config.lnd`, `config.cln`, `config.blitzApi`, `config.blitzWeb` (and their `copyWith` flavors) will fail to compile. Tasks 4–7 fix those incrementally.

- [ ] **Step 1: Write failing tests for the new API**

```dart
// common/test/models/nixblitz_config_test.dart  (extend / rewrite)

group('NixblitzConfig generic accessors', () {
  test('appOption returns null for missing app', () {
    const c = NixblitzConfig(schemaVersion: 18, system: SystemConfig.fallback());
    expect(c.appOption<bool>('bitcoind', 'enabled'), isNull);
  });

  test('appOption returns null for missing key', () {
    final c = NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig.fallback(),
      appConfigs: const {'bitcoind': {'enabled': true}},
    );
    expect(c.appOption<String>('bitcoind', 'network'), isNull);
  });

  test('appOption returns null on type mismatch', () {
    final c = NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig.fallback(),
      appConfigs: const {'bitcoind': {'enabled': 'yes'}},   // String, not bool
    );
    expect(c.appOption<bool>('bitcoind', 'enabled'), isNull);
  });

  test('isAppEnabled reads from app_configs', () {
    final c = NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig.fallback(),
      appConfigs: const {'bitcoind': {'enabled': true}, 'lnd': {'enabled': false}},
    );
    expect(c.isAppEnabled('bitcoind'), isTrue);
    expect(c.isAppEnabled('lnd'), isFalse);
    expect(c.isAppEnabled('cln'), isFalse);   // missing app → false
  });

  test('setAppOption creates app entry when absent', () {
    const c0 = NixblitzConfig(schemaVersion: 18, system: SystemConfig.fallback());
    final c1 = c0.setAppOption('bitcoind', 'enabled', true);
    expect(c1.appOption<bool>('bitcoind', 'enabled'), isTrue);
  });

  test('setAppOption preserves other apps + other keys within same app', () {
    final c0 = NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig.fallback(),
      appConfigs: const {
        'bitcoind': {'enabled': true, 'network': 'regtest'},
        'lnd': {'enabled': true},
      },
    );
    final c1 = c0.setAppOption('bitcoind', 'pruned', true);
    expect(c1.appOption<bool>('bitcoind', 'enabled'), isTrue);
    expect(c1.appOption<String>('bitcoind', 'network'), 'regtest');
    expect(c1.appOption<bool>('bitcoind', 'pruned'), isTrue);
    expect(c1.isAppEnabled('lnd'), isTrue);
  });

  test('toggleAppOption flips bool', () {
    final c = NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig.fallback(),
      appConfigs: const {'bitcoind': {'enabled': true}},
    );
    expect(c.toggleAppOption('bitcoind', 'enabled').isAppEnabled('bitcoind'), isFalse);
  });

  test('toggleAppOption from missing → true', () {
    const c = NixblitzConfig(schemaVersion: 18, system: SystemConfig.fallback());
    expect(c.toggleAppOption('bitcoind', 'enabled').isAppEnabled('bitcoind'), isTrue);
  });

  test('removeAppConfig is no-op when app absent', () {
    final c = NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig.fallback(),
      appConfigs: const {'bitcoind': {'enabled': true}},
    );
    expect(identical(c.removeAppConfig('lnd').appConfigs, c.appConfigs)
        || c.removeAppConfig('lnd').appConfigs.length == c.appConfigs.length, isTrue);
  });

  test('removeAppConfig drops the named app, preserves others', () {
    final c = NixblitzConfig(
      schemaVersion: 18,
      system: const SystemConfig.fallback(),
      appConfigs: const {
        'bitcoind': {'enabled': true},
        'lnd': {'enabled': true},
      },
    );
    final c1 = c.removeAppConfig('bitcoind');
    expect(c1.appConfigs.containsKey('bitcoind'), isFalse);
    expect(c1.isAppEnabled('lnd'), isTrue);
  });
});

group('NixblitzConfig.fromJson v18', () {
  test('round-trip with five apps', () {
    final json = <String, dynamic>{
      'schema_version': 18,
      'system': {'hostname': 'nixblitz', 'platform': 'pi5'},
      'app_configs': {
        'bitcoind': {'enabled': true, 'network': 'regtest', 'pruned': false, 'prune_size_gb': 0},
        'lnd': {'enabled': true, 'alias': 'hello'},
        'cln': {'enabled': false},
        'blitz_api': {'enabled': true},
        'blitz_web': {'enabled': true},
      },
    };
    final c = NixblitzConfig.fromJson(json);
    expect(c.schemaVersion, 18);
    expect(c.isAppEnabled('bitcoind'), isTrue);
    expect(c.appOption<String>('bitcoind', 'network'), 'regtest');
    expect(c.appOption<String>('lnd', 'alias'), 'hello');
    expect(c.isAppEnabled('cln'), isFalse);

    final back = c.toJson();
    expect(back['schema_version'], 18);
    expect(back['app_configs']['bitcoind']['network'], 'regtest');
  });

  test('empty app_configs', () {
    final c = NixblitzConfig.fromJson({
      'schema_version': 18,
      'system': {'hostname': 'h', 'platform': 'p'},
      'app_configs': <String, dynamic>{},
    });
    expect(c.isAppEnabled('bitcoind'), isFalse);
  });
});
```

(Adapt `SystemConfig.fallback()` to whatever default constructor SystemConfig has. If there isn't one, use `SystemConfig(hostname: 'h', platform: 'p')` directly.)

- [ ] **Step 2: Run tests — confirm they fail (NixblitzConfig still has typed shape)**

```bash
cd common && dart test test/models/nixblitz_config_test.dart
```

- [ ] **Step 3: Refactor `NixblitzConfig`**

Replace the relevant section of `nixblitz_config.dart`:

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

  T? appOption<T>(String app, String key) {
    final m = appConfigs[app];
    if (m == null) return null;
    final v = m[key];
    return v is T ? v : null;
  }

  Map<String, dynamic> appConfig(String app) =>
      appConfigs[app] ?? const {};

  bool isAppEnabled(String app) => appOption<bool>(app, 'enabled') ?? false;

  NixblitzConfig setAppOption(String app, String key, Object? value) {
    final current = appConfigs[app] ?? const <String, dynamic>{};
    final next = {...appConfigs, app: {...current, key: value}};
    return copyWith(appConfigs: next);
  }

  NixblitzConfig toggleAppOption(String app, String key) {
    final current = appOption<bool>(app, key) ?? false;
    return setAppOption(app, key, !current);
  }

  NixblitzConfig setAppConfig(String app, Map<String, dynamic> config) {
    final next = {...appConfigs, app: config};
    return copyWith(appConfigs: next);
  }

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

  factory NixblitzConfig.fromJson(Map<String, dynamic> json) {
    final raw = json['app_configs'] as Map?;
    final apps = <String, Map<String, dynamic>>{};
    if (raw != null) {
      for (final entry in raw.entries) {
        final v = entry.value;
        if (v is Map) {
          apps[entry.key as String] = v.cast<String, dynamic>();
        }
      }
    }
    return NixblitzConfig(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 18,
      system: SystemConfig.fromJson((json['system'] as Map?)?.cast<String, dynamic>() ?? const {}),
      appConfigs: apps,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'system': system.toJson(),
    'app_configs': appConfigs,
  };

  @override
  bool operator ==(Object other) =>
      other is NixblitzConfig &&
      other.schemaVersion == schemaVersion &&
      other.system == system &&
      _appConfigsEqual(other.appConfigs, appConfigs);

  @override
  int get hashCode => Object.hash(schemaVersion, system, _appConfigsHash(appConfigs));
}

bool _appConfigsEqual(Map<String, Map<String, dynamic>> a, Map<String, Map<String, dynamic>> b) {
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    final ma = a[k];
    final mb = b[k];
    if (mb == null || ma!.length != mb.length) return false;
    for (final mk in ma.keys) {
      if (ma[mk] != mb[mk]) return false;
    }
  }
  return true;
}

int _appConfigsHash(Map<String, Map<String, dynamic>> m) {
  var h = 0;
  for (final entry in m.entries) {
    var inner = 0;
    for (final ie in entry.value.entries) inner ^= Object.hash(ie.key, ie.value);
    h ^= Object.hash(entry.key, inner);
  }
  return h;
}
```

Delete from the same file:

- `class BitcoindConfig { ... }`
- `class LndConfig { ... }`
- `class ClnConfig { ... }`
- `class BlitzApiConfig { ... }`
- `class BlitzWebConfig { ... }`

(Keep `class SystemConfig`. Also keep the `BitcoinNetwork` import — Task 1 already moved that.)

- [ ] **Step 4: Run tests — confirm pass**

```bash
cd common && dart test test/models/nixblitz_config_test.dart
```

The NEW tests must pass. The trio across the workspace WILL fail elsewhere (call sites in `tui/`).

- [ ] **Step 5: Commit (with explicit acknowledgement of red trio)**

```bash
just analyze 2>&1 | head -30   # Sanity check — should report errors only in tui/lib (call sites)
jj commit -m "$(cat <<'EOF'
refactor(config): drop typed app fields, use generic appConfigs

NixblitzConfig now stores only schemaVersion, system, and appConfigs
(Map<String, Map<String, dynamic>>). Generic accessors: appOption,
appConfig, isAppEnabled, setAppOption, toggleAppOption, setAppConfig,
removeAppConfig.

Five typed config classes deleted: BitcoindConfig, LndConfig,
ClnConfig, BlitzApiConfig, BlitzWebConfig. BitcoinNetwork already
relocated in Task 1.

Trio is INTENTIONALLY RED at this commit: ~50 call sites in
tui/lib/src/ui/views/ still reference the deleted typed accessors.
Tasks 4–6 migrate the call sites; Task 7 finishes the green-trio
sweep.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(`just test` is expected to fail because of compile errors in tui/. Skip running it for the commit — the body explains. `just analyze` and `just format` should also fail/diff, but that's acceptable for a planned mid-stream commit.)

---

## Task 4: Migrate `configure_view.dart` call sites

**Files:**
- Modify: `tui/lib/src/ui/views/configure_view.dart`

**Spec reference:** Call-site updates: `configure_view.dart` (~50 typed-field reads, ~20 copyWith chains).

**Why now:** This is the largest single rewrite (~50 references). After Task 3 the file is full of compile errors; this task fixes them mechanically without changing the file's structure. Phase 3 does the structural rewrite.

**Trio still red after this task** — there are call sites in install_view, setup_view, dashboard_view that haven't been touched yet.

- [ ] **Step 1: Survey the typed-field references**

```bash
grep -nE '\bconfig\.(bitcoind|lnd|cln|blitzApi|blitzWeb)\b' tui/lib/src/ui/views/configure_view.dart | head -40
```

Categorise into:
- **Reads**: `config.bitcoind.enabled`, `config.lnd.alias`, etc. → become `config.appOption<T>('bitcoind', 'enabled')` / `config.isAppEnabled('bitcoind')`.
- **copyWith chains**: `config.copyWith(bitcoind: config.bitcoind.copyWith(enabled: !config.bitcoind.enabled))` → become `config.toggleAppOption('bitcoind', 'enabled')` or `config.setAppOption('bitcoind', 'enabled', newValue)`.

- [ ] **Step 2: Mechanical rewrite — apply the patterns**

Translation table (one-shot find-and-replace patterns; verify each match is genuine):

| Old pattern | New pattern |
|---|---|
| `config.bitcoind.enabled` | `config.isAppEnabled('bitcoind')` |
| `config.lnd.enabled` | `config.isAppEnabled('lnd')` |
| `config.cln.enabled` | `config.isAppEnabled('cln')` |
| `config.blitzApi.enabled` | `config.isAppEnabled('blitz_api')` |
| `config.blitzWeb.enabled` | `config.isAppEnabled('blitz_web')` |
| `config.bitcoind.network` | `BitcoinNetwork.fromWireName(config.appOption<String>('bitcoind', 'network') ?? 'mainnet') ?? BitcoinNetwork.mainnet` |
| `config.bitcoind.pruned` | `config.appOption<bool>('bitcoind', 'pruned') ?? false` |
| `config.bitcoind.pruneSizeGb` | `config.appOption<int>('bitcoind', 'prune_size_gb') ?? 0` |
| `config.lnd.alias` | `config.appOption<String>('lnd', 'alias') ?? ''` |

For the typed-name in `appOption`, mind the JSON snake_case:
- `blitzApi` (Dart) → `'blitz_api'` (JSON key)
- `blitzWeb` (Dart) → `'blitz_web'` (JSON key)
- `pruneSizeGb` (Dart) → `'prune_size_gb'` (JSON key)

Toggle / set patterns:

| Old pattern | New pattern |
|---|---|
| `config = config.copyWith(bitcoind: config.bitcoind.copyWith(enabled: !config.bitcoind.enabled));` | `config = config.toggleAppOption('bitcoind', 'enabled');` |
| `config = config.copyWith(bitcoind: config.bitcoind.copyWith(network: nextNetwork));` | `config = config.setAppOption('bitcoind', 'network', nextNetwork.wireName);` |
| `config = config.copyWith(bitcoind: config.bitcoind.copyWith(pruned: newPruned));` | `config = config.setAppOption('bitcoind', 'pruned', newPruned);` |
| `config = config.copyWith(bitcoind: config.bitcoind.copyWith(pruneSizeGb: newSize));` | `config = config.setAppOption('bitcoind', 'prune_size_gb', newSize);` |
| `config = config.copyWith(lnd: config.lnd.copyWith(alias: newAlias));` | `config = config.setAppOption('lnd', 'alias', newAlias);` |
| `config = config.copyWith(lnd: config.lnd.copyWith(enabled: !config.lnd.enabled));` | `config = config.toggleAppOption('lnd', 'enabled');` |
| (similar for cln, blitz_api, blitz_web) | (similar) |

Special cases to watch for:

- The Configure view has a **services list** at line ~101: `final services = ['system', 'bitcoind', 'lnd', 'cln', 'blitz-api', 'blitz-web', 'plugins'];`. Note the strings here use HYPHENS (e.g. `'blitz-api'`) for the menu key, which is DIFFERENT from the JSON snake_case key (`'blitz_api'`). When mapping menu-name → app-config-key, add a small helper:

```dart
String _appKeyForMenu(String menu) => switch (menu) {
  'blitz-api' => 'blitz_api',
  'blitz-web' => 'blitz_web',
  _ => menu,
};
```

Use it whenever the switch statement's `case 'blitz-api':` body needs to call `setAppOption(...)` or `appOption(...)`.

- The `_pendingKeyFor()` helper maps to dotted-path config keys like `'bitcoind.network'`. After this rewrite those dotted paths are still valid (in the new shape, the JSON key is `'app_configs.bitcoind.network'`, but if the helper produces just the inner path `'bitcoind.network'` the consumer probably still works as a uniqueness key for pending change tracking).

- [ ] **Step 3: Run analyzer for `configure_view.dart` only**

```bash
cd tui && dart analyze lib/src/ui/views/configure_view.dart
```

Should be clean. Run a wider analyze:

```bash
just analyze 2>&1 | grep -v ' info ' | head -30
```

Errors should now be confined to `install_view.dart`, `setup_view.dart`, `dashboard_view.dart` (Tasks 5–6).

- [ ] **Step 4: Commit (still mid-stream red)**

```bash
jj commit -m "$(cat <<'EOF'
refactor(config): migrate configure_view call sites to generic API

~50 typed-field reads (config.bitcoind.X, config.lnd.X, etc.) and ~20
copyWith chains rewritten to use isAppEnabled / appOption / setAppOption
/ toggleAppOption. Switch tree structure preserved — Phase 3 will do
the structural generalisation (manifest-driven field rendering, dynamic
menu items).

Trio still red on install_view.dart and setup_view.dart; Tasks 5–6 fix
those.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Migrate `install_view.dart` and `setup_view.dart` call sites

**Files:**
- Modify: `tui/lib/src/ui/views/install_view.dart`
- Modify: `tui/lib/src/ui/views/setup_view.dart`

**Spec reference:** Call-site updates: `install_view.dart`, `setup_view.dart`.

- [ ] **Step 1: Survey references**

```bash
grep -nE '\bconfig\.(bitcoind|lnd|cln|blitzApi|blitzWeb)\b' \
  tui/lib/src/ui/views/install_view.dart \
  tui/lib/src/ui/views/setup_view.dart
```

Apply the same translation table from Task 4. Specific patterns to expect:

**`install_view.dart` — wizard apply path:**

```dart
// Old:
config = config.copyWith(
  lnd: config.lnd.copyWith(enabled: lnChoice == _LightningChoice.lnd),
  cln: config.cln.copyWith(enabled: lnChoice == _LightningChoice.cln),
);

// New:
config = config
    .setAppOption('lnd', 'enabled', lnChoice == _LightningChoice.lnd)
    .setAppOption('cln', 'enabled', lnChoice == _LightningChoice.cln);
```

```dart
// Old:
config = config.copyWith(
  bitcoind: config.bitcoind.copyWith(network: chosenNetwork),
);

// New:
config = config.setAppOption('bitcoind', 'network', chosenNetwork.wireName);
```

**`setup_view.dart` — lnd seed display gate:**

```dart
// Old:
if (config.lnd.enabled) {
  // … read /mnt/data/lnd/lnd-seed-mnemonic …
}

// New:
if (config.isAppEnabled('lnd')) {
  // … unchanged body …
}
```

The seed-file path itself stays hardcoded — it's a Nix-side path, only relevant when lnd is enabled.

- [ ] **Step 2: Apply the rewrite**

Find-and-replace per the patterns above. Pay attention to chained `copyWith` calls — multiple `setAppOption` calls compose via the cascade operator.

- [ ] **Step 3: Run analyzer**

```bash
cd tui && dart analyze lib/src/ui/views/install_view.dart lib/src/ui/views/setup_view.dart
```

Should be clean for these two files.

```bash
just analyze 2>&1 | grep -v ' info ' | head -30
```

Remaining errors should now be only in `dashboard_view.dart` and `dashboard_chrome.dart` (Task 6).

- [ ] **Step 4: Commit**

```bash
jj commit -m "$(cat <<'EOF'
refactor(config): migrate install_view + setup_view call sites

Wizard's lightning choice / network choice apply path uses chained
setAppOption. Setup view's lnd seed-file gate uses isAppEnabled.

Trio still red on dashboard_view.dart + dashboard_chrome.dart; Task 6
fixes those.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate `dashboard_view.dart` + adapt `dashboard_chrome.dart`

**Files:**
- Modify: `tui/lib/src/ui/views/dashboard_view.dart`
- Modify: `tui/lib/src/ui/views/dashboard/dashboard_chrome.dart`
- Modify: `tui/test/ui/views/dashboard/dashboard_chrome_test.dart`

**Spec reference:** Dashboard chrome adaptation.

- [ ] **Step 1: Update `DashboardChrome` to accept nullable network**

Read the current state:

```bash
cat tui/lib/src/ui/views/dashboard/dashboard_chrome.dart
```

Change the `network` field from `String` to `String?`. When null, line 1 drops the network suffix:

```dart
// In DashboardChrome:
final String? network;   // was: final String network;

// In build:
final l1 = network == null
    ? '$hostname  ·  $platform'
    : '$hostname  ·  $platform  ·  $network';
```

Same change in `renderChromeText` helper. Update test cases in `dashboard_chrome_test.dart` to also assert the null-network path:

```dart
test('drops network segment when network is null', () {
  final out = renderChromeText(
    hostname: 'h', platform: 'p', network: null,
    uptimeSec: null, appliedAgo: null,
  );
  expect(out.split('\\n').first, equals('h  ·  p'));
});
```

- [ ] **Step 2: Update `dashboard_view.dart`'s chrome construction**

```bash
grep -n 'DashboardChrome\|config?.bitcoind\|config\.bitcoind' tui/lib/src/ui/views/dashboard_view.dart
```

Old:

```dart
DashboardChrome(
  hostname: config?.system.hostname ?? '?',
  platform: config?.system.platform ?? '?',
  network:  config?.bitcoind.network ?? 'unknown',
  uptimeSec: _readUptimeSec(context),
  appliedAgo: null,
)
```

New:

```dart
DashboardChrome(
  hostname: config?.system.hostname ?? '?',
  platform: config?.system.platform ?? '?',
  network:  config?.appOption<String>('bitcoind', 'network'),
  uptimeSec: _readUptimeSec(context),
  appliedAgo: null,
)
```

(`appOption` returns null when bitcoind isn't configured. The chrome accepts null and drops the segment. No fallback string needed.)

- [ ] **Step 3: Run analyzer**

```bash
just analyze 2>&1 | grep -v ' info ' | head -30
```

Should now be clean except possibly `scaffold_service.dart` (handled in Task 7).

- [ ] **Step 4: Run tests**

```bash
just test 2>&1 | tail -20
```

Should be mostly green; any remaining failures are in `scaffold_service` (Task 7) or test fixtures that still construct the deleted typed classes (delete those tests in this commit).

- [ ] **Step 5: Commit**

```bash
jj commit -m "$(cat <<'EOF'
refactor(config): migrate dashboard_view + chrome to generic API

dashboard_view reads bitcoin network via appOption<String>; passes nullable
to DashboardChrome. Chrome's network field is now nullable; line 1 drops
the network segment when no bitcoind is configured (homelab base case).

Trio still has compile errors in scaffold_service; Task 7 fixes that.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update `scaffold_service.dart` — fresh-install writes v18 shape

**Files:**
- Modify: `common/lib/src/services/scaffold_service.dart`
- Modify: `common/test/services/scaffold_service_test.dart` (if it exists)

**Spec reference:** Modified files: `scaffold_service.dart`.

**Why now:** Last Dart-side call site. Trio fully green after this task.

- [ ] **Step 1: Find the place that constructs the initial NixblitzConfig**

```bash
grep -nE 'NixblitzConfig\(|BitcoindConfig|LndConfig|ClnConfig|BlitzApiConfig|BlitzWebConfig' \
  common/lib/src/services/scaffold_service.dart
```

The current code likely instantiates each typed class with default values. Replace with:

```dart
NixblitzConfig(
  schemaVersion: 18,
  system: SystemConfig(
    hostname: defaultHostname,
    platform: detectedPlatform,
  ),
  appConfigs: const {
    'bitcoind':  {'enabled': false, 'network': 'mainnet', 'pruned': false, 'prune_size_gb': 0},
    'lnd':       {'enabled': false, 'alias': ''},
    'cln':       {'enabled': false},
    'blitz_api': {'enabled': false},
    'blitz_web': {'enabled': false},
  },
)
```

(Use whatever defaults the typed classes had previously.)

- [ ] **Step 2: Run trio**

```bash
just test
just analyze
just format
```

**All three must be GREEN.** This is the end of the call-site sweep. Any remaining errors mean a missed reference somewhere — chase it.

- [ ] **Step 3: Commit (full green)**

```bash
jj commit -m "$(cat <<'EOF'
refactor(config): scaffold_service writes v18 shape on fresh install

Initial config now has schemaVersion=18 and a populated app_configs
map with all five extracted apps disabled by default. Mirrors the
defaults the deleted typed classes used.

Trio is now fully green: every Dart call site has been migrated to
the generic API.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Rewrite `templates/hosts/installed.nix` for generic shape

**Files:**
- Modify: `templates/hosts/installed.nix`

**Spec reference:** Nix template rewrite section.

**Why now:** Dart side fully green; Nix template needs to read the new `app_configs` JSON shape on next system rebuild.

- [ ] **Step 1: Read the current template**

```bash
cat templates/hosts/installed.nix
```

Identify the section that reads `cfg.bitcoind.X`, `cfg.lnd.X`, etc.

- [ ] **Step 2: Rewrite with `appOpt` / `appEnabled` lambdas**

Replace the named-field reads with the generic helpers:

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

    # Test-LND auto-enable: if bitcoind regtest is on, enable test-lnd.
    # (The let-bound apps map gives us the value via appOpt.)
    features.apps.test-lnd.enable = (appEnabled "bitcoind") &&
      (appOpt "bitcoind" "network" "mainnet") == "regtest";

    # … any other config that previously read cfg.X.Y …
  };
}
```

(Adapt to the existing structure of installed.nix — don't reformat unrelated sections; keep operator group config, hosts entries, etc. unchanged.)

- [ ] **Step 3: Verify the template parses by dry-building**

After Task 7 produced a fresh JSON config with the new shape (or after testing on a dev VM), run:

```bash
just gen-locks   # if you touched any flake-input-driven content
```

For a quick syntax check without a full build:

```bash
nix-instantiate --parse templates/hosts/installed.nix > /dev/null 2>&1 && echo "syntax ok"
```

Note: `installed.nix` is part of the embedded templates. After modifying it, regenerate the embedded constants:

```bash
just gen-templates
```

This updates `common/lib/src/services/embedded_templates.g.dart` to include the new template content.

- [ ] **Step 4: Trio**

```bash
just test && just analyze && just format
```

Tests should pass; the embedded-templates regen produces a checked-in `.g.dart` file diff.

- [ ] **Step 5: Commit**

```bash
jj commit -m "$(cat <<'EOF'
refactor(config): installed.nix iterates generic app_configs shape

Local Nix lambdas appOpt/appEnabled wrap `cfg.app_configs.<name>.<key>`
with default fallbacks. The five named app blocks (bitcoind, lnd, cln,
blitz-api, blitz-web) keep their feature.apps.X.* assignments — Phase 4–6
will lift those imports into actual plugins.

Test-LND regtest auto-enable adapted to read network via appOpt.
Embedded templates regenerated via just gen-templates.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Manual smoke + final trio

**Files:** none (verification only)

**Spec reference:** Manual smoke subsection.

- [ ] **Step 1: Final trio**

```bash
just test && just analyze && just format
```

All three green.

- [ ] **Step 2: Smoke against a v17 config (auto-migration path)**

```bash
# On a Pi 5 install or VM with an existing v17 ~/nixblitz/config.json:
# 1. Capture the current config:
cat ~/nixblitz/config.json | head -20
# Expect schema_version: 17 and top-level bitcoind/lnd/cln/blitz_api/blitz_web keys.

# 2. Run the new TUI binary (deploy via nixos-rebuild or just run from the dev tree):
just run

# 3. After TUI starts, the migration writes v18 shape. Verify:
cat ~/nixblitz/config.json | head -30
# Expect schema_version: 18 and an `app_configs` block.
```

Verify the dashboard renders correctly post-migration (chrome shows network if bitcoind is enabled and has a network; tiles show their data).

- [ ] **Step 3: Smoke against a fresh install (scaffold path)**

```bash
# In a clean VM:
just vm-boot
# In VM, run nixblitz from scratch (fresh config):
nixblitz
# Verify ~/nixblitz/config.json has schema_version: 18 and an empty/default app_configs.
```

- [ ] **Step 4: Smoke `[u]: Update` (Nix template build path)**

```bash
# In a VM with the new TUI:
# 1. Toggle bitcoind.enabled in Configure view, Apply.
# 2. Watch nixos-rebuild invoke; verify it builds and the systemd unit lands.
```

The generated NixOS config should have the same `features.apps.bitcoind.enable = true` setting it would have produced under the v17 typed shape.

- [ ] **Step 5: No commit needed (verification only)**

If you want to capture a screenshot or asciinema for the record:

```bash
jj commit -m "$(cat <<'EOF'
docs(config): asciinema snapshot post-Phase-2

Dashboard renders correctly through the auto-migrated v18 config.
Apply+rebuild produces an equivalent NixOS closure.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(Skip if you don't capture media.)

---

## Self-review

**Spec coverage:**

| Spec section | Implementing task(s) |
|---|---|
| Goal — drop typed fields | Task 3 |
| `BitcoinNetwork` relocation | Task 1 |
| Migration v17 → v18 | Task 2 |
| `NixblitzConfig` refactor + generic accessors | Task 3 |
| `appOption` / `setAppOption` / friends | Task 3 |
| Deletion of 5 typed classes | Task 3 |
| `configure_view.dart` call-site rewrite | Task 4 |
| `install_view.dart` + `setup_view.dart` | Task 5 |
| `dashboard_view.dart` + `dashboard_chrome.dart` | Task 6 |
| Nullable network field | Task 6 |
| `scaffold_service.dart` writes v18 shape | Task 7 |
| Nix template `appOpt`/`appEnabled` | Task 8 |
| Test-LND regtest auto-enable adaptation | Task 8 |
| Manual smoke (v17 migration, fresh install, apply) | Task 9 |
| Trio gate per task | every task (with explicit mid-stream-red flags on 3–6) |

All spec sections covered.

**Type consistency:** `appOption<T>(app, key)`, `appConfig(app)`, `isAppEnabled(app)`, `setAppOption(app, key, value)`, `toggleAppOption(app, key)`, `setAppConfig(app, config)`, `removeAppConfig(app)` — all consistent across tasks.

**JSON keys consistent:** `'blitz_api'` and `'blitz_web'` (snake_case) in JSON; `'blitz-api'` and `'blitz-web'` (hyphenated) in the configure view's menu strings. Translation helper `_appKeyForMenu` flagged in Task 4.

**Placeholder scan:** every code step shows complete code or a precise translation pattern. No hidden TBDs. The `SystemConfig.fallback()` reference in Task 3's tests is flagged as "adapt to actual SystemConfig API".

**Mid-stream-red trio is acceptable per spec:** Tasks 3–6 are individual call-site migrations; the spec explicitly accepts this pattern (mirrors Phase 1's Tasks 15–17). Task 7 closes the green-trio sweep.

---

## Plan complete

Saved to: `docs/superpowers/plans/2026-05-05-config-generalization.md`
