import 'dart:convert';
import 'package:common/src/models/config_migrations.dart';

class SystemConfig {
  final String hostname;
  final String timezone;
  final String platform;

  /// The block device the operator picked at install time
  /// (e.g. `/dev/sda`, `/dev/nvme0n1`). Threaded through to
  /// `disko.devices.disk.main.device` so post-install rebuilds
  /// install GRUB onto the same disk that disko-install
  /// partitioned. Empty string falls back to the disko module's
  /// per-platform default (`/dev/vda` on x86 — fine for qemu
  /// virtio VMs but wrong on bare metal). Set by the install
  /// wizard before save-config.
  final String diskDevice;

  /// Default login shell for the admin user. One of `bash` or
  /// `nushell`. Threaded through to `users.defaultUserShell` in
  /// `templates/modules/system/base.nix`. Bash is the default
  /// because most NixBlitz operators are coming from Linux
  /// systems where bash is the lingua franca; nushell stays
  /// available as an opt-in for people who prefer it.
  final String shell;

  /// Whether node-wide Tor support is enabled. Defaults to `true`
  /// (privacy-by-default). When true, all supporting services are
  /// routed through Tor; false disables the Tor daemon and clearnet
  /// mode is used throughout.
  final bool tor;

  /// Operator's pick of which nixblitz branch to track. Null means
  /// "use the embedded manifest's default:true entry" — the scaffold
  /// service materialises that default into the flake without
  /// pinning the operator's choice. A non-null value is either a
  /// declared key from the embedded manifest (e.g. `"stable"`,
  /// `"next"`) or the `"custom:<ref>"` escape-hatch string the
  /// operator types into the branch picker.
  final String? nixblitzBranch;

  const SystemConfig({
    required this.hostname,
    required this.timezone,
    required this.platform,
    this.diskDevice = '',
    this.shell = 'bash',
    this.tor = true,
    this.nixblitzBranch,
  });

  factory SystemConfig.defaults() => const SystemConfig(
    hostname: 'nixblitz',
    timezone: 'UTC',
    platform: 'x86',
    diskDevice: '',
    shell: 'bash',
    tor: true,
  );

  factory SystemConfig.fromJson(Map<String, dynamic> json) => SystemConfig(
    hostname: json['hostname'] as String? ?? 'nixblitz',
    timezone: json['timezone'] as String? ?? 'UTC',
    platform: json['platform'] as String? ?? 'x86',
    diskDevice: json['disk_device'] as String? ?? '',
    shell: json['shell'] as String? ?? 'bash',
    tor: json['tor'] as bool? ?? true,
    nixblitzBranch: json['nixblitz_branch'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'hostname': hostname,
    'timezone': timezone,
    'platform': platform,
    'disk_device': diskDevice,
    'shell': shell,
    'tor': tor,
    'nixblitz_branch': nixblitzBranch,
  };

  SystemConfig copyWith({
    String? hostname,
    String? timezone,
    String? platform,
    String? diskDevice,
    String? shell,
    bool? tor,
    String? nixblitzBranch,
  }) => SystemConfig(
    hostname: hostname ?? this.hostname,
    timezone: timezone ?? this.timezone,
    platform: platform ?? this.platform,
    diskDevice: diskDevice ?? this.diskDevice,
    shell: shell ?? this.shell,
    tor: tor ?? this.tor,
    nixblitzBranch: nixblitzBranch ?? this.nixblitzBranch,
  );

  @override
  bool operator ==(Object other) =>
      other is SystemConfig &&
      other.hostname == hostname &&
      other.timezone == timezone &&
      other.platform == platform &&
      other.diskDevice == diskDevice &&
      other.shell == shell &&
      other.tor == tor &&
      other.nixblitzBranch == nixblitzBranch;

  @override
  int get hashCode => Object.hash(
    hostname,
    timezone,
    platform,
    diskDevice,
    shell,
    tor,
    nixblitzBranch,
  );
}

class NixblitzConfig {
  final int schemaVersion;

  /// The minimum TUI schema version required to safely read this config.
  /// Preserved from the file if present, otherwise defaults to [minCompatibleVersion].
  final int configMinCompatibleVersion;

  final bool initialized;

  /// Name of the last setup-wizard step the operator completed,
  /// or null if no step has finished. The wizard records its
  /// own [SetupStep] enum names here (`"setPassword"`,
  /// `"buildServices"`, `"waitBitcoind"`, `"initLightning"`,
  /// `"summary"`) so a Ctrl+C mid-wizard resumes at the next
  /// undone step on the following launch.
  ///
  /// Tracked as a string rather than a typed enum on purpose —
  /// it survives wizard refactors that rename/insert/remove
  /// steps. When this field equals the terminal step name
  /// (`"summary"`) the wizard is fully done and the app routes
  /// straight to the dashboard.
  ///
  /// Distinct from [initialized]: that field flips at the very
  /// first useful step (services build) so the NixOS modules
  /// know to enable services, but it doesn't tell us whether
  /// the operator finished the rest of the wizard.
  final String? setupStepCompleted;

  final SystemConfig system;

  /// Generic per-app config storage. Key is the app identifier
  /// (e.g. `"bitcoind"`, `"lnd"`, `"cln"`, plus any installed
  /// plugin's id); value is the app's flat config map.
  /// Use [appOption], [isAppEnabled], [setAppOption], etc. for
  /// type-safe access.
  final Map<String, Map<String, dynamic>> appConfigs;

  final Map<String, dynamic> _extra;

  const NixblitzConfig({
    this.schemaVersion = currentConfigVersion,
    this.configMinCompatibleVersion = minCompatibleVersion,
    this.initialized = false,
    this.setupStepCompleted,
    required this.system,
    this.appConfigs = const {},
    Map<String, dynamic> extra = const {},
  }) : _extra = extra;

  factory NixblitzConfig.defaults() =>
      NixblitzConfig(system: SystemConfig.defaults(), appConfigs: const {});

  // ── generic accessors ──────────────────────────────────────────────

  /// Read a single config value for an app. Returns null if the app or
  /// key is missing, or the stored value's type doesn't match T.
  T? appOption<T>(String app, String key) {
    final m = appConfigs[app];
    if (m == null) return null;
    final v = m[key];
    return v is T ? v : null;
  }

  /// Read an app's whole config map (empty map if app is absent).
  Map<String, dynamic> appConfig(String app) => appConfigs[app] ?? const {};

  /// Returns whether an app is enabled. Convenience over
  /// `appOption<bool>(app, 'enabled') ?? false`.
  bool isAppEnabled(String app) => appOption<bool>(app, 'enabled') ?? false;

  /// Set a single value, returning a new NixblitzConfig. Creates the app
  /// entry if absent.
  NixblitzConfig setAppOption(String app, String key, Object? value) {
    final current = appConfigs[app] ?? const <String, dynamic>{};
    final next = {
      ...appConfigs,
      app: {...current, key: value},
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

  // ── diff helpers ───────────────────────────────────────────────────

  /// Returns a human-readable description of changes from [other] to this.
  String diffFrom(NixblitzConfig other) {
    final changes = <String>[];

    if (initialized != other.initialized) {
      changes.add('initialized: ${other.initialized} → $initialized');
    }
    if (setupStepCompleted != other.setupStepCompleted) {
      changes.add(
        'setup_step_completed: ${other.setupStepCompleted ?? "(none)"} → '
        '${setupStepCompleted ?? "(none)"}',
      );
    }

    void compareSection(
      String name,
      Map<String, dynamic> after,
      Map<String, dynamic> before,
    ) {
      final fieldChanges = <String>[];
      final allKeys = {...after.keys, ...before.keys};
      for (final key in allKeys) {
        final a = after[key];
        final b = before[key];
        if (a != b) {
          fieldChanges.add('  $key: $b → $a');
        }
      }
      if (fieldChanges.isNotEmpty) {
        changes.add('$name:\n${fieldChanges.join('\n')}');
      }
    }

    compareSection('system', system.toJson(), other.system.toJson());

    final allApps = {...appConfigs.keys, ...other.appConfigs.keys};
    for (final app in allApps) {
      compareSection(
        app,
        appConfigs[app] ?? const {},
        other.appConfigs[app] ?? const {},
      );
    }

    return changes.join('\n');
  }

  /// Structured per-key diff against [other]. Returns dotted-path
  /// keys whose live value differs, using the JSON snake_case
  /// names — e.g. `{"system.hostname", "lnd.alias",
  /// "bitcoind.prune_size_gb"}`. Top-level fields use bare names
  /// (`"initialized"`, `"setup_step_completed"`).
  ///
  /// Used by `pendingChangeKeysProvider` to drive Configure-view
  /// per-row pending markers and the dashboard header's
  /// `X pending / in sync` status segment.
  Set<String> diffKeysFrom(NixblitzConfig other) {
    final keys = <String>{};

    if (initialized != other.initialized) keys.add('initialized');
    if (setupStepCompleted != other.setupStepCompleted) {
      keys.add('setup_step_completed');
    }

    void compareSection(
      String name,
      Map<String, dynamic> after,
      Map<String, dynamic> before,
    ) {
      final allKeys = {...after.keys, ...before.keys};
      for (final key in allKeys) {
        if (after[key] != before[key]) keys.add('$name.$key');
      }
    }

    compareSection('system', system.toJson(), other.system.toJson());

    final allApps = {...appConfigs.keys, ...other.appConfigs.keys};
    for (final app in allApps) {
      compareSection(
        app,
        appConfigs[app] ?? const {},
        other.appConfigs[app] ?? const {},
      );
    }

    return keys;
  }

  // ── serialization ──────────────────────────────────────────────────

  /// Parse a config from JSON. Runs migrations if the schema version is
  /// older than the current one. Unknown top-level fields (future versions)
  /// are preserved in `_extra` and written back out on save.
  ///
  /// Throws [ConfigTooNewException] if the config was written by a TUI that
  /// declared a higher minimum compatible version than this TUI supports.
  factory NixblitzConfig.fromJson(Map<String, dynamic> json) {
    // Check minimum compatible version — if the config was written by a newer
    // TUI that declared a breaking change, refuse to load it.
    final configMinVersion = json['min_compatible_version'] as int? ?? 1;
    if (configMinVersion > currentConfigVersion) {
      throw ConfigTooNewException(configMinVersion, currentConfigVersion);
    }

    // Run migrations if needed (noop if already current version).
    // Use 'schema_version' as the canonical key (v18+); fall back to 'version'
    // for pre-v18 configs on disk.
    final rawVersion =
        (json['schema_version'] as int?) ?? (json['version'] as int?);
    final migrated = rawVersion != null && rawVersion >= currentConfigVersion
        ? json
        : migrateConfig(
            // Normalise: if we have schema_version but no version, add it so
            // migrateConfig's version-based dispatch works.
            rawVersion == null ? json : {...json, 'version': rawVersion},
          );

    // Parse app_configs generic map.
    final raw = migrated['app_configs'] as Map?;
    final apps = <String, Map<String, dynamic>>{};
    if (raw != null) {
      for (final entry in raw.entries) {
        final v = entry.value;
        if (v is Map) {
          apps[entry.key as String] = Map<String, dynamic>.from(v);
        }
      }
    }

    // Collect unknown top-level fields for forward-compatibility.
    const knownKeys = {
      'schema_version',
      'version', // legacy alias, consumed during migration
      'min_compatible_version',
      'initialized',
      'setup_step_completed',
      'system',
      'app_configs',
      'plugins',
    };
    final extra = <String, dynamic>{};
    for (final entry in migrated.entries) {
      if (!knownKeys.contains(entry.key)) {
        extra[entry.key] = entry.value;
      }
    }

    return NixblitzConfig(
      schemaVersion:
          (migrated['schema_version'] as int?) ??
          (migrated['version'] as int?) ??
          currentConfigVersion,
      configMinCompatibleVersion: configMinVersion > minCompatibleVersion
          ? configMinVersion
          : minCompatibleVersion,
      initialized: migrated['initialized'] as bool? ?? false,
      setupStepCompleted:
          migrated['setup_step_completed'] as String? ??
          ((migrated['initialized'] as bool? ?? false)
              ? 'buildServices'
              : null),
      system: migrated['system'] != null
          ? SystemConfig.fromJson(migrated['system'] as Map<String, dynamic>)
          : SystemConfig.defaults(),
      appConfigs: apps,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'min_compatible_version': configMinCompatibleVersion,
    'initialized': initialized,
    'setup_step_completed': setupStepCompleted,
    'system': system.toJson(),
    'app_configs': appConfigs,
    ..._extra,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  // ── copyWith ───────────────────────────────────────────────────────

  NixblitzConfig copyWith({
    int? schemaVersion,
    int? configMinCompatibleVersion,
    bool? initialized,
    // Wrapped in a function-typed sentinel because this field
    // is nullable — a plain `String? setupStepCompleted` can't
    // distinguish "leave as-is" from "explicitly clear to null".
    // Pass `() => null` to clear, `() => "stepName"` to set,
    // omit entirely to inherit.
    String? Function()? setupStepCompleted,
    SystemConfig? system,
    Map<String, Map<String, dynamic>>? appConfigs,
    Map<String, dynamic>? extra,
  }) => NixblitzConfig(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    configMinCompatibleVersion:
        configMinCompatibleVersion ?? this.configMinCompatibleVersion,
    initialized: initialized ?? this.initialized,
    setupStepCompleted: setupStepCompleted == null
        ? this.setupStepCompleted
        : setupStepCompleted(),
    system: system ?? this.system,
    appConfigs: appConfigs ?? this.appConfigs,
    extra: extra ?? _extra,
  );

  // ── equality ───────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      other is NixblitzConfig &&
      other.schemaVersion == schemaVersion &&
      other.configMinCompatibleVersion == configMinCompatibleVersion &&
      other.initialized == initialized &&
      other.setupStepCompleted == setupStepCompleted &&
      other.system == system &&
      _appConfigsEqual(other.appConfigs, appConfigs);

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    configMinCompatibleVersion,
    initialized,
    setupStepCompleted,
    system,
    _appConfigsHash(appConfigs),
  );
}

bool _appConfigsEqual(
  Map<String, Map<String, dynamic>> a,
  Map<String, Map<String, dynamic>> b,
) {
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
    for (final ie in entry.value.entries) {
      inner ^= Object.hash(ie.key, ie.value);
    }
    h ^= Object.hash(entry.key, inner);
  }
  return h;
}
