/// Config schema migrations.
///
/// When a breaking schema change is needed, add a migration function here
/// and increment [currentConfigVersion]. Migrations are applied in order
/// when reading an older config.
///
/// ## Compatibility rules
///
/// - **Additive changes** (new fields with defaults) do NOT require a migration.
///   The model's fromJson handles missing fields via defaults, and unknown
///   fields are preserved in the `_extra` map for older TUI versions.
/// - **Breaking changes** (removing or renaming fields, changing types) DO
///   require a migration. Add a function here that transforms the old schema
///   to the new one.
/// - Older TUI versions encountering a config with version newer than
///   [currentConfigVersion] will still read it, preserving unknown fields and
///   the version number on write. This means an older TUI can "downgrade"
///   to read a newer config without destroying it.
/// - If a future change is so fundamental that older TUIs must NOT read it
///   (e.g., the config is split into multiple files, or critical invariants
///   change), set a threshold: have older TUIs refuse to load any config
///   where `version > currentConfigVersion + safeForwardWindow` (not yet
///   implemented — add when needed).
library;

/// Current schema version. Increment when a migration is added.
/// Start at 1; bump by 1 each time [migrations] gains a new entry.
///
/// Treat this as a NixBlitz-wide version, not just the config schema —
/// bump it whenever the embedded `.nix` templates change in a way that
/// makes on-disk copies incompatible. The TUI checks this at startup
/// and auto-refreshes templates on mismatch (see `NixBlitzApp.build`).
const int currentConfigVersion = 16;

/// The minimum schema version this TUI can safely read/write.
///
/// When writing a config, this TUI declares what it considers the minimum
/// compatible version. Older TUIs with [currentConfigVersion] below this
/// value must refuse to load the config (they would likely misinterpret
/// fields or produce a broken configuration).
///
/// When making a breaking change, bump both [currentConfigVersion] AND
/// [minCompatibleVersion] so older TUIs refuse to load the new schema.
/// When making only additive changes, bump only [currentConfigVersion]
/// (leave [minCompatibleVersion] alone, older TUIs continue to work).
const int minCompatibleVersion = 1;

/// Exception thrown when a config is too new for this TUI to safely load.
class ConfigTooNewException implements Exception {
  final int configMinVersion;
  final int thisTuiVersion;

  ConfigTooNewException(this.configMinVersion, this.thisTuiVersion);

  @override
  String toString() =>
      'Config requires TUI schema version >= $configMinVersion '
      'but this TUI only supports up to $thisTuiVersion. '
      'Please update NixBlitz.';
}

/// Map of source version → migration function.
/// Each migration transforms the JSON from version N to N+1.
final Map<int, Map<String, dynamic> Function(Map<String, dynamic>)> migrations =
    {
      // v1 → v2: bitcoind network enum narrowed from
      // ["mainnet", "testnet", "signet"] to ["mainnet", "regtest"] after
      // nix-bitcoin's module turned out not to support section-aware config
      // generation needed for testnet/signet. Fall back to mainnet so the
      // rebuild doesn't choke on an invalid enum value.
      1: (json) {
        final bitcoind = json['bitcoind'];
        if (bitcoind is Map<String, dynamic>) {
          final network = bitcoind['network'];
          if (network == 'testnet' || network == 'signet') {
            bitcoind['network'] = 'mainnet';
          }
        }
        return json;
      },
      // v2 → v3: no schema change; template contents bumped (blitz-api
      // and blitz-web modules wired to upstream flakes, hosts/default.nix
      // gates blitz-api on lnd). Existing TUIs need to refresh on-disk
      // templates; the migration runner bumps the version field so the
      // startup auto-refresh picks it up.
      2: (json) => json,
      // v3 → v4: no schema change; templates' blitz-web flake input now
      // points at fusion44/raspiblitz-web fork and the module targets
      // services.raspiblitz-web (upstream renamed). Template-only bump.
      3: (json) => json,
      // v4 → v5: no schema change; features.apps.blitz-api now enables a
      // local redis instance (upstream blitz-api needs one on :6379).
      4: (json) => json,
      // v5 → v6: no schema change; blitz-api now passes rootPath = "/api"
      // so the ASGI app knows its external mount point.
      5: (json) => json,
      // v6 → v7: no schema change; new test-lnd feature module (auto-enabled
      // on regtest) ships a secondary LND instance + lncli-test wrapper.
      6: (json) => json,
      // v7 → v8: no schema change; test-lnd now creates its wallet
      // headlessly via lndinit (LND doesn't self-bootstrap from a password
      // file alone).
      7: (json) => json,
      // v8 → v9: no schema change; test-lnd preStart gained shell tracing
      // + explicit log lines so first-boot wallet init failures surface
      // in the journal instead of vanishing.
      8: (json) => json,
      // v9 → v10: no schema change; test-lnd preStart now uses a
      // .wallet-initialized marker (instead of wallet.db existence) to
      // decide whether to run lndinit. A half-init from a previous
      // broken attempt can no longer trick us into skipping the real init.
      9: (json) => json,
      // v10 → v11: no schema change; test-lnd's networkDir dropped the
      // bogus `data/` prefix — LND's chain/ lives directly under dataDir.
      // Existing test-lnd installs need to wipe /var/lib/lnd-test so the
      // wallet is recreated in the right place.
      10: (json) => json,
      // v11 → v12: no schema change; bitcoind on regtest now sets
      // fallbackfee=0.0002 so sendtoaddress doesn't refuse for lack of
      // fee estimation data on a fresh chain.
      11: (json) => json,
      // v12 → v13: additive — plugins[] array is new (defaults to empty
      // and handled by fromJson). The bump exists so existing installs
      // auto-refresh templates: flake.nix now also scans ./plugins/ for
      // nix modules, and without that change plugins added via
      // `nixblitz plugin add` wouldn't be imported by the generated flake.
      12: (json) => json,
      // v13 → v14: no schema change; template-refresh only. flake.nix
      // now wraps each plugin module with `_module.args.pluginCfg =
      // fromJSON(readFile plugins/<dir>/config.json)` so plugin.nix
      // can declare `pluginCfg` as a module arg and read its own config
      // without `builtins.readFile` (see plugins.md D14).
      13: (json) => json,
      // v14 → v15: additive — `system.disk_device` records the path
      // the operator picked at install time. disko-x86 used to default
      // `device = "/dev/vda"` (qemu virtio), and post-install rebuilds
      // on bare-metal x86 then tried to install GRUB onto a non-existent
      // /dev/vda. The new field carries the actual install device
      // through to subsequent rebuilds. Existing configs on virtio
      // hosts get an empty string and fall back to the disko-x86
      // default — so VMs continue to work without re-installing.
      14: (json) => json,
      // v15 → v16: additive — `system.shell` lets the operator pick
      // bash or nushell as the admin user's default login shell. Bash
      // is the new default (was nushell, hard-coded in base.nix).
      // Existing configs missing the field fall through to bash on
      // next Apply — flip the Configure → system → shell select to
      // stay on nushell.
      15: (json) => json,
    };

/// Apply all necessary migrations to bring [json] up to [currentConfigVersion].
/// Returns the migrated JSON. Does not mutate the input.
Map<String, dynamic> migrateConfig(Map<String, dynamic> json) {
  var current = Map<String, dynamic>.from(json);
  var version = (current['version'] as int?) ?? 1;

  while (version < currentConfigVersion) {
    final migration = migrations[version];
    if (migration == null) {
      throw StateError(
        'No migration found for version $version → ${version + 1}. '
        'This is a bug.',
      );
    }
    current = migration(current);
    version++;
    current['version'] = version;
  }

  // Ensure version is set on the final output.
  current['version'] = currentConfigVersion;
  return current;
}
