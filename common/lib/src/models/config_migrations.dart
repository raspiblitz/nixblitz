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
const int currentConfigVersion = 2;

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
final Map<int, Map<String, dynamic> Function(Map<String, dynamic>)> migrations = {
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
