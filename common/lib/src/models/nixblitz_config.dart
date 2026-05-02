import 'dart:convert';
import 'package:common/src/models/config_migrations.dart';
import 'package:common/src/models/plugin/plugin_entry.dart';

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

  const SystemConfig({
    required this.hostname,
    required this.timezone,
    required this.platform,
    this.diskDevice = '',
    this.shell = 'bash',
  });

  factory SystemConfig.defaults() => const SystemConfig(
    hostname: 'nixblitz',
    timezone: 'UTC',
    platform: 'x86',
    diskDevice: '',
    shell: 'bash',
  );

  factory SystemConfig.fromJson(Map<String, dynamic> json) => SystemConfig(
    hostname: json['hostname'] as String? ?? 'nixblitz',
    timezone: json['timezone'] as String? ?? 'UTC',
    platform: json['platform'] as String? ?? 'x86',
    diskDevice: json['disk_device'] as String? ?? '',
    shell: json['shell'] as String? ?? 'bash',
  );

  Map<String, dynamic> toJson() => {
    'hostname': hostname,
    'timezone': timezone,
    'platform': platform,
    'disk_device': diskDevice,
    'shell': shell,
  };

  SystemConfig copyWith({
    String? hostname,
    String? timezone,
    String? platform,
    String? diskDevice,
    String? shell,
  }) => SystemConfig(
    hostname: hostname ?? this.hostname,
    timezone: timezone ?? this.timezone,
    platform: platform ?? this.platform,
    diskDevice: diskDevice ?? this.diskDevice,
    shell: shell ?? this.shell,
  );

  @override
  bool operator ==(Object other) =>
      other is SystemConfig &&
      other.hostname == hostname &&
      other.timezone == timezone &&
      other.platform == platform &&
      other.diskDevice == diskDevice &&
      other.shell == shell;

  @override
  int get hashCode =>
      Object.hash(hostname, timezone, platform, diskDevice, shell);
}

class BitcoindConfig {
  final bool enabled;
  final String network;
  final bool pruned;
  final int pruneSizeGb;

  const BitcoindConfig({
    required this.enabled,
    required this.network,
    required this.pruned,
    required this.pruneSizeGb,
  });

  factory BitcoindConfig.defaults() => const BitcoindConfig(
    enabled: true,
    network: 'mainnet',
    pruned: true,
    pruneSizeGb: 550,
  );

  factory BitcoindConfig.fromJson(Map<String, dynamic> json) => BitcoindConfig(
    enabled: json['enabled'] as bool? ?? true,
    network: json['network'] as String? ?? 'mainnet',
    pruned: json['pruned'] as bool? ?? true,
    pruneSizeGb: json['prune_size_gb'] as int? ?? 550,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'network': network,
    'pruned': pruned,
    'prune_size_gb': pruneSizeGb,
  };

  BitcoindConfig copyWith({
    bool? enabled,
    String? network,
    bool? pruned,
    int? pruneSizeGb,
  }) => BitcoindConfig(
    enabled: enabled ?? this.enabled,
    network: network ?? this.network,
    pruned: pruned ?? this.pruned,
    pruneSizeGb: pruneSizeGb ?? this.pruneSizeGb,
  );

  @override
  bool operator ==(Object other) =>
      other is BitcoindConfig &&
      other.enabled == enabled &&
      other.network == network &&
      other.pruned == pruned &&
      other.pruneSizeGb == pruneSizeGb;

  @override
  int get hashCode => Object.hash(enabled, network, pruned, pruneSizeGb);
}

class LndConfig {
  final bool enabled;
  final String alias;

  const LndConfig({required this.enabled, required this.alias});

  factory LndConfig.defaults() => const LndConfig(enabled: false, alias: '');

  factory LndConfig.fromJson(Map<String, dynamic> json) => LndConfig(
    enabled: json['enabled'] as bool? ?? false,
    alias: json['alias'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'enabled': enabled, 'alias': alias};

  LndConfig copyWith({bool? enabled, String? alias}) =>
      LndConfig(enabled: enabled ?? this.enabled, alias: alias ?? this.alias);

  @override
  bool operator ==(Object other) =>
      other is LndConfig && other.enabled == enabled && other.alias == alias;

  @override
  int get hashCode => Object.hash(enabled, alias);
}

class ClnConfig {
  final bool enabled;

  const ClnConfig({required this.enabled});

  factory ClnConfig.defaults() => const ClnConfig(enabled: false);

  factory ClnConfig.fromJson(Map<String, dynamic> json) =>
      ClnConfig(enabled: json['enabled'] as bool? ?? false);

  Map<String, dynamic> toJson() => {'enabled': enabled};

  ClnConfig copyWith({bool? enabled}) =>
      ClnConfig(enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      other is ClnConfig && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;
}

class BlitzApiConfig {
  final bool enabled;

  const BlitzApiConfig({required this.enabled});

  factory BlitzApiConfig.defaults() => const BlitzApiConfig(enabled: true);

  factory BlitzApiConfig.fromJson(Map<String, dynamic> json) =>
      BlitzApiConfig(enabled: json['enabled'] as bool? ?? true);

  Map<String, dynamic> toJson() => {'enabled': enabled};

  BlitzApiConfig copyWith({bool? enabled}) =>
      BlitzApiConfig(enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      other is BlitzApiConfig && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;
}

class BlitzWebConfig {
  final bool enabled;

  const BlitzWebConfig({required this.enabled});

  factory BlitzWebConfig.defaults() => const BlitzWebConfig(enabled: true);

  factory BlitzWebConfig.fromJson(Map<String, dynamic> json) =>
      BlitzWebConfig(enabled: json['enabled'] as bool? ?? true);

  Map<String, dynamic> toJson() => {'enabled': enabled};

  BlitzWebConfig copyWith({bool? enabled}) =>
      BlitzWebConfig(enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      other is BlitzWebConfig && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;
}

class NixblitzConfig {
  final int version;

  /// The minimum TUI schema version required to safely read this config.
  /// Preserved from the file if present, otherwise defaults to [minCompatibleVersion].
  /// This means: if a newer TUI wrote v5 requiring min v3, an older TUI at v3
  /// or v4 reading this config preserves the "min v3" on write-back, so even
  /// older TUIs (v1, v2) continue to be blocked.
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
  final BitcoindConfig bitcoind;
  final LndConfig lnd;
  final ClnConfig cln;
  final BlitzApiConfig blitzApi;
  final BlitzWebConfig blitzWeb;
  final List<PluginEntry> plugins;
  final Map<String, dynamic> _extra;

  const NixblitzConfig({
    this.version = currentConfigVersion,
    this.configMinCompatibleVersion = minCompatibleVersion,
    required this.initialized,
    this.setupStepCompleted,
    required this.system,
    required this.bitcoind,
    required this.lnd,
    required this.cln,
    required this.blitzApi,
    required this.blitzWeb,
    this.plugins = const [],
    Map<String, dynamic> extra = const {},
  }) : _extra = extra;

  factory NixblitzConfig.defaults() => NixblitzConfig(
    initialized: false,
    setupStepCompleted: null,
    system: SystemConfig.defaults(),
    bitcoind: BitcoindConfig.defaults(),
    lnd: LndConfig.defaults(),
    cln: ClnConfig.defaults(),
    blitzApi: BlitzApiConfig.defaults(),
    blitzWeb: BlitzWebConfig.defaults(),
  );

  static const _knownKeys = {
    'version',
    'min_compatible_version',
    'initialized',
    'setup_step_completed',
    'system',
    'bitcoind',
    'lnd',
    'cln',
    'blitz_api',
    'blitz_web',
    'plugins',
  };

  /// Parse a config from JSON. Runs migrations if the version is older than
  /// the current one. Unknown fields (future versions) are preserved in
  /// `_extra` and written back out on save.
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

    // Run migrations if needed (noop if already current version)
    final migrated =
        json.containsKey('version') &&
            (json['version'] as int) >= currentConfigVersion
        ? json
        : migrateConfig(json);

    final extra = <String, dynamic>{};
    for (final entry in migrated.entries) {
      if (!_knownKeys.contains(entry.key)) {
        extra[entry.key] = entry.value;
      }
    }

    return NixblitzConfig(
      version: (migrated['version'] as int?) ?? currentConfigVersion,
      // Preserve max(file's min, our min) — never weaken protection.
      configMinCompatibleVersion: configMinVersion > minCompatibleVersion
          ? configMinVersion
          : minCompatibleVersion,
      initialized: migrated['initialized'] as bool? ?? false,
      // Old configs predate this field. Two cases to handle on
      // load:
      //   - `initialized=false`: fresh / never started → null,
      //     wizard begins at the first step.
      //   - `initialized=true`: a previous wizard run ran the
      //     services build before this field existed. We don't
      //     know whether it then finished, so be conservative
      //     and treat the operator as "got past buildServices
      //     but no further" — wizard resumes at waitBitcoind.
      //     Already-finished operators see one extra prompt
      //     (which they confirm and never see again); the
      //     alternative is leaving stuck-mid-wizard users
      //     unable to resume.
      setupStepCompleted:
          migrated['setup_step_completed'] as String? ??
          ((migrated['initialized'] as bool? ?? false)
              ? 'buildServices'
              : null),
      system: migrated['system'] != null
          ? SystemConfig.fromJson(migrated['system'] as Map<String, dynamic>)
          : SystemConfig.defaults(),
      bitcoind: migrated['bitcoind'] != null
          ? BitcoindConfig.fromJson(
              migrated['bitcoind'] as Map<String, dynamic>,
            )
          : BitcoindConfig.defaults(),
      lnd: migrated['lnd'] != null
          ? LndConfig.fromJson(migrated['lnd'] as Map<String, dynamic>)
          : LndConfig.defaults(),
      cln: migrated['cln'] != null
          ? ClnConfig.fromJson(migrated['cln'] as Map<String, dynamic>)
          : ClnConfig.defaults(),
      blitzApi: migrated['blitz_api'] != null
          ? BlitzApiConfig.fromJson(
              migrated['blitz_api'] as Map<String, dynamic>,
            )
          : BlitzApiConfig.defaults(),
      blitzWeb: migrated['blitz_web'] != null
          ? BlitzWebConfig.fromJson(
              migrated['blitz_web'] as Map<String, dynamic>,
            )
          : BlitzWebConfig.defaults(),
      plugins:
          (migrated['plugins'] as List<dynamic>?)
              ?.map((e) => PluginEntry.fromJson(e as Map<String, dynamic>))
              .toList(growable: false) ??
          const [],
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'min_compatible_version': configMinCompatibleVersion,
    'initialized': initialized,
    'setup_step_completed': setupStepCompleted,
    'system': system.toJson(),
    'bitcoind': bitcoind.toJson(),
    'lnd': lnd.toJson(),
    'cln': cln.toJson(),
    'blitz_api': blitzApi.toJson(),
    'blitz_web': blitzWeb.toJson(),
    'plugins': plugins.map((p) => p.toJson()).toList(),
    ..._extra,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

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

    // Compare sub-configs via JSON serialization to catch any field changes.
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
    compareSection('bitcoind', bitcoind.toJson(), other.bitcoind.toJson());
    compareSection('lnd', lnd.toJson(), other.lnd.toJson());
    compareSection('cln', cln.toJson(), other.cln.toJson());
    compareSection('blitz_api', blitzApi.toJson(), other.blitzApi.toJson());
    compareSection('blitz_web', blitzWeb.toJson(), other.blitzWeb.toJson());

    return changes.join('\n');
  }

  /// Structured per-key diff against [other]. Returns dotted-path
  /// keys whose live value differs, using the JSON snake_case
  /// names that [toJson] emits — e.g. `{"system.hostname",
  /// "lnd.alias", "bitcoind.prune_size_gb"}`. Top-level fields
  /// use bare names (`"initialized"`, `"setup_step_completed"`).
  ///
  /// Used by `pendingChangeKeysProvider` to drive Configure-view
  /// per-row pending markers and the dashboard header's
  /// `X pending / in sync` status segment. The string-returning
  /// [diffFrom] stays around for the Apply view's free-text diff
  /// render — different consumers, different shapes.
  ///
  /// Plugins are deliberately skipped: their per-key diff would
  /// also need plugin-specific config-schema awareness which
  /// lives outside this model. File-level porcelain still picks
  /// them up via the dashboard banner. `_extra` (forward-compat
  /// unknown fields) is also skipped — round-tripped transparently
  /// and not surfaced to operators.
  Set<String> diffKeysFrom(NixblitzConfig other) {
    final keys = <String>{};

    if (initialized != other.initialized) keys.add('initialized');
    if (setupStepCompleted != other.setupStepCompleted) {
      keys.add('setup_step_completed');
    }

    // Same per-section toJson() comparison as diffFrom — every
    // field appearing in toJson is automatically covered, so new
    // sub-config fields don't need a corresponding edit here.
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
    compareSection('bitcoind', bitcoind.toJson(), other.bitcoind.toJson());
    compareSection('lnd', lnd.toJson(), other.lnd.toJson());
    compareSection('cln', cln.toJson(), other.cln.toJson());
    compareSection('blitz_api', blitzApi.toJson(), other.blitzApi.toJson());
    compareSection('blitz_web', blitzWeb.toJson(), other.blitzWeb.toJson());

    return keys;
  }

  NixblitzConfig copyWith({
    int? version,
    int? configMinCompatibleVersion,
    bool? initialized,
    // Wrapped in a function-typed sentinel because this field
    // is nullable — a plain `String? setupStepCompleted` can't
    // distinguish "leave as-is" from "explicitly clear to null".
    // Pass `() => null` to clear, `() => "stepName"` to set,
    // omit entirely to inherit. (Matches Dart's idiom for
    // copyWith on optional nullable fields.)
    String? Function()? setupStepCompleted,
    SystemConfig? system,
    BitcoindConfig? bitcoind,
    LndConfig? lnd,
    ClnConfig? cln,
    BlitzApiConfig? blitzApi,
    BlitzWebConfig? blitzWeb,
    List<PluginEntry>? plugins,
    Map<String, dynamic>? extra,
  }) => NixblitzConfig(
    version: version ?? this.version,
    configMinCompatibleVersion:
        configMinCompatibleVersion ?? this.configMinCompatibleVersion,
    initialized: initialized ?? this.initialized,
    setupStepCompleted: setupStepCompleted == null
        ? this.setupStepCompleted
        : setupStepCompleted(),
    system: system ?? this.system,
    bitcoind: bitcoind ?? this.bitcoind,
    lnd: lnd ?? this.lnd,
    cln: cln ?? this.cln,
    blitzApi: blitzApi ?? this.blitzApi,
    blitzWeb: blitzWeb ?? this.blitzWeb,
    plugins: plugins ?? this.plugins,
    extra: extra ?? _extra,
  );
}
