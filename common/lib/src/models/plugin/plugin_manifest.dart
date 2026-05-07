import 'dart:convert';

import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest_error.dart';
import 'package:common/src/models/plugin/plugin_permissions.dart';
import 'package:common/src/models/plugin/plugin_streamer_spec.dart';
import 'package:common/src/models/plugin/plugin_tile.dart';

/// Plugin manifest schema (see `docs/decisions/plugins.md`, D1/D6/D14/D16).
///
/// Versioning mirrors the main config schema (see
/// `common/lib/src/models/config_migrations.dart`):
///
/// - [currentPluginManifestVersion] is what this TUI understands.
/// - [minCompatibleManifestVersion] is the lowest manifest schema we
///   can still round-trip safely.
/// - Plugins declare `manifest.schema_version` (what they were
///   authored against) and `manifest.min_tui_version` (the lowest
///   TUI that can render them). If a plugin's `min_tui_version`
///   exceeds [currentPluginManifestVersion], we refuse to install
///   with [PluginTooNewException].
///
/// Additive schema changes bump only [currentPluginManifestVersion];
/// older TUIs continue to load newer manifests and drop unknown
/// fields. Breaking changes bump both constants so old TUIs refuse.

/// What version of the manifest schema this TUI understands.
///
/// v2 (current): privileged actions are dispatched as systemd
/// `unit:` references rather than `command:` + `run_as_root: true`.
/// Tile commands always run as the admin user (no `run_as_root` on
/// `dashboard`). See sudo posture / Posture A in the project plan.
const int currentPluginManifestVersion = 2;

/// Lowest manifest schema version this TUI can safely load. v1
/// manifests are rejected because their `run_as_root: true` action
/// path silently breaks under wheelNeedsPassword=true — better to
/// hard-fail at load with a migration hint than silently no-op.
const int minCompatibleManifestVersion = 2;

class PluginTooNewException implements Exception {
  final int requiredMinTuiVersion;
  final int thisTuiVersion;

  const PluginTooNewException(this.requiredMinTuiVersion, this.thisTuiVersion);

  @override
  String toString() =>
      'Plugin requires TUI manifest version >= $requiredMinTuiVersion '
      'but this TUI only supports up to $thisTuiVersion. '
      'Please update NixBlitz.';
}

class PluginManifest {
  /// What schema version the plugin was authored against.
  final int schemaVersion;

  /// Lowest TUI that can render this plugin's config/UI surface.
  final int minTuiVersion;

  /// Stable plugin identifier (e.g. `blitz-api`). Used as the directory
  /// name under `~/nixblitz/plugins/<id>/` and as the lookup key in
  /// dep-check / install-flow code. Defaults to [name] when absent in
  /// JSON, so existing v2-shape manifests (which only had `name`)
  /// continue to parse without modification.
  final String id;

  /// Display name shown in the TUI.
  final String name;

  final String description;

  /// Self-declared install URL (e.g. `git+https://forge.example/p`).
  /// `PluginUrlDep` resolution matches against this verbatim — keep
  /// it stable across versions of a plugin. Nullable: bundled or
  /// locally-developed plugins without a registry entry leave this
  /// unset.
  final String? url;

  /// Plugin version string (e.g. `0.1.0`). Free-form; the TUI does
  /// not parse semver. Stored on the install marker for audit.
  /// Nullable when absent in the manifest.
  final String? version;

  /// User-triggerable actions (Phase 4). Keys are action ids
  /// (used internally), values describe the labeled command. May
  /// be empty — many plugins are install-and-leave-alone.
  final Map<String, PluginAction> actions;

  /// Declarative permission block (D14). Informational in Phase 1.
  final PluginPermissions permissions;

  /// Optional dashboard tile declaration (Phase 3). Plugins without
  /// a `dashboard` block in `plugin.json` don't get a tile.
  final PluginTileSpec? dashboard;

  /// Config schema for manifest-driven UI rendering. The plugin's
  /// config fields appear in the Configure view driven by this
  /// AppManifest. Null only for plugins with no user-editable
  /// config (the dashboard-only kind).
  final AppManifest? configSchema;

  /// Plugin dependencies declared in `requires` (Phase 4). Each entry
  /// is either an [AppDep] (built-in app id) or a [PluginUrlDep]
  /// (another plugin keyed by install URL). Default empty.
  final List<PluginDep> requires;

  /// Optional path within the plugin checkout to the NixOS module
  /// (e.g. `module.nix`). Resolved relative to the plugin's source
  /// root and imported by the generated `installed.nix`. Null when
  /// the plugin has no NixOS-side module.
  final String? module;

  /// Subprocess streamers declared in `streamers` (Phase 4). Each
  /// entry is launched at TUI startup and emits dashboard tile events
  /// for its declared `tile_ids`. Default empty.
  final List<StreamerSpec> streamers;

  const PluginManifest({
    required this.schemaVersion,
    required this.minTuiVersion,
    required this.name,
    required this.description,
    String? id,
    this.url,
    this.version,
    this.actions = const {},
    this.permissions = const PluginPermissions(),
    this.dashboard,
    this.configSchema,
    this.requires = const [],
    this.module,
    this.streamers = const [],
  }) : id = id ?? name;

  factory PluginManifest.fromJsonString(String s) =>
      PluginManifest.fromJson(jsonDecode(s) as Map<String, dynamic>);

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final header = json['manifest'] as Map<String, dynamic>?;
    if (header == null) {
      throw FormatException('plugin.json is missing the `manifest` block');
    }

    final minTui = header['min_tui_version'] as int? ?? 1;
    if (minTui > currentPluginManifestVersion) {
      throw PluginTooNewException(minTui, currentPluginManifestVersion);
    }

    final name = header['name'] as String?;
    if (name == null || name.isEmpty) {
      throw FormatException('manifest.name is required');
    }

    final rawActions = json['actions'] as Map<String, dynamic>? ?? const {};
    final actionMap = <String, PluginAction>{};
    for (final entry in rawActions.entries) {
      final v = entry.value;
      if (v is! Map<String, dynamic>) {
        throw FormatException(
          'actions.${entry.key} must be a map, got ${v.runtimeType}',
        );
      }
      actionMap[entry.key] = PluginAction.fromJson(v);
    }

    final permsRaw = json['permissions'];
    final perms = permsRaw is Map<String, dynamic>
        ? PluginPermissions.fromJson(permsRaw)
        : const PluginPermissions();

    // Cross-validate: any `unit:` action must point at a unit
    // listed in permissions.privileged_units. This prevents a
    // manifest from triggering arbitrary system units it didn't
    // declare up-front.
    for (final entry in actionMap.entries) {
      final unit = entry.value.unit;
      if (unit != null && !perms.privilegedUnits.contains(unit)) {
        throw FormatException(
          'action `${entry.key}` references unit `$unit` which is '
          'not declared in permissions.privileged_units',
        );
      }
    }

    final dashboardRaw = json['dashboard'];
    final dashboard = dashboardRaw is Map<String, dynamic>
        ? PluginTileSpec.fromJson(dashboardRaw)
        : null;

    final rawId = json['id'];
    String? id;
    if (rawId != null) {
      if (rawId is! String || rawId.isEmpty) {
        throw const PluginManifestError(
          'manifest.id must be a non-empty string when present',
        );
      }
      id = rawId;
    }

    final csRaw = json['config_schema'];
    AppManifest? configSchema;
    if (csRaw is Map<String, dynamic>) {
      // Inject id from outer manifest if absent in config_schema.
      // Prefer the plugin's stable top-level `id` (e.g. "blitz-api")
      // over the display `name` (e.g. "Blitz API"); the AppManifest
      // id is what dep-check / install flow keys on, and it must
      // match the plugin's directory name under ~/nixblitz/plugins/.
      final csJson = Map<String, dynamic>.from(csRaw)
        ..putIfAbsent('id', () => id ?? name);
      configSchema = AppManifest.fromJson(csJson);
    }

    final schemaVersion = header['schema_version'] as int? ?? 1;
    if (schemaVersion < minCompatibleManifestVersion) {
      throw FormatException(
        'manifest.schema_version $schemaVersion is too old; this TUI '
        'requires v$minCompatibleManifestVersion or newer. v1 plugins '
        'with `run_as_root: true` actions need to migrate to `unit:` '
        'systemd dispatch — see sudo posture in the project docs.',
      );
    }

    final rawUrl = json['url'];
    String? url;
    if (rawUrl != null) {
      if (rawUrl is! String || rawUrl.isEmpty) {
        throw const PluginManifestError(
          'manifest.url must be a non-empty string when present',
        );
      }
      url = rawUrl;
    }

    final rawVersion = json['version'];
    String? version;
    if (rawVersion != null) {
      if (rawVersion is! String || rawVersion.isEmpty) {
        throw const PluginManifestError(
          'manifest.version must be a non-empty string when present',
        );
      }
      version = rawVersion;
    }

    final rawRequires = json['requires'];
    final requiresList = <PluginDep>[];
    if (rawRequires != null) {
      if (rawRequires is! List) {
        throw const PluginManifestError(
          'manifest.requires must be a list of dependency objects',
        );
      }
      for (final entry in rawRequires) {
        if (entry is! Map<String, dynamic>) {
          throw PluginManifestError(
            'manifest.requires entries must be maps, got ${entry.runtimeType}',
          );
        }
        requiresList.add(PluginDep.fromJson(entry));
      }
    }

    final rawModule = json['module'];
    String? module;
    if (rawModule != null) {
      if (rawModule is! String || rawModule.isEmpty) {
        throw const PluginManifestError(
          'manifest.module must be a non-empty string when present',
        );
      }
      module = rawModule;
    }

    final rawStreamers = json['streamers'];
    final streamersList = <StreamerSpec>[];
    if (rawStreamers != null) {
      if (rawStreamers is! List) {
        throw const PluginManifestError(
          'manifest.streamers must be a list of streamer objects',
        );
      }
      for (final entry in rawStreamers) {
        if (entry is! Map<String, dynamic>) {
          throw PluginManifestError(
            'manifest.streamers entries must be maps, got ${entry.runtimeType}',
          );
        }
        streamersList.add(StreamerSpec.fromJson(entry));
      }
    }

    return PluginManifest(
      schemaVersion: schemaVersion,
      minTuiVersion: minTui,
      name: name,
      description: header['description'] as String? ?? '',
      id: id,
      url: url,
      version: version,
      actions: actionMap,
      permissions: perms,
      dashboard: dashboard,
      configSchema: configSchema,
      requires: List.unmodifiable(requiresList),
      module: module,
      streamers: List.unmodifiable(streamersList),
    );
  }

  Map<String, dynamic> toJson() => {
    'manifest': {
      'schema_version': schemaVersion,
      'min_tui_version': minTuiVersion,
      'name': name,
      if (description.isNotEmpty) 'description': description,
    },
    if (id != name) 'id': id,
    if (url != null) 'url': url,
    if (version != null) 'version': version,
    if (actions.isNotEmpty)
      'actions': {for (final e in actions.entries) e.key: e.value.toJson()},
    if (!permissions.isEmpty) 'permissions': permissions.toJson(),
    if (dashboard != null) 'dashboard': dashboard!.toJson(),
    if (configSchema != null) 'config_schema': configSchema!.toJson(),
    if (requires.isNotEmpty) 'requires': [for (final d in requires) d.toJson()],
    if (module != null) 'module': module,
    if (streamers.isNotEmpty)
      'streamers': [for (final s in streamers) s.toJson()],
  };
}
