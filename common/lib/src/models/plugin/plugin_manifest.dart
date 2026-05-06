import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/models/plugin/plugin_permissions.dart';
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

  /// Display name shown in the TUI.
  final String name;

  final String description;

  /// Config fields the user can edit. Keys are field ids, values
  /// describe their type and labels. May be empty — many plugins
  /// need no user-editable config (e.g. tailscale).
  final Map<String, ConfigField> config;

  /// User-triggerable actions (Phase 4). Keys are action ids
  /// (used internally), values describe the labeled command. May
  /// be empty — many plugins are install-and-leave-alone.
  final Map<String, PluginAction> actions;

  /// Declarative permission block (D14). Informational in Phase 1.
  final PluginPermissions permissions;

  /// Optional dashboard tile declaration (Phase 3). Plugins without
  /// a `dashboard` block in `manifest.json` don't get a tile.
  final PluginTileSpec? dashboard;

  /// Optional config schema for manifest-driven UI rendering (Phase 3 Task 5).
  /// When present, the plugin's config fields appear in the Configure view
  /// driven by this AppManifest instead of opaque plugin.config.
  final AppManifest? configSchema;

  const PluginManifest({
    required this.schemaVersion,
    required this.minTuiVersion,
    required this.name,
    required this.description,
    this.config = const {},
    this.actions = const {},
    this.permissions = const PluginPermissions(),
    this.dashboard,
    this.configSchema,
  });

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final header = json['manifest'] as Map<String, dynamic>?;
    if (header == null) {
      throw FormatException('manifest.json is missing the `manifest` block');
    }

    final minTui = header['min_tui_version'] as int? ?? 1;
    if (minTui > currentPluginManifestVersion) {
      throw PluginTooNewException(minTui, currentPluginManifestVersion);
    }

    final name = header['name'] as String?;
    if (name == null || name.isEmpty) {
      throw FormatException('manifest.name is required');
    }

    final rawConfig = json['config'] as Map<String, dynamic>? ?? const {};
    final configMap = <String, ConfigField>{};
    for (final entry in rawConfig.entries) {
      final v = entry.value;
      if (v is! Map<String, dynamic>) {
        throw FormatException(
          'config.${entry.key} must be a map, got ${v.runtimeType}',
        );
      }
      configMap[entry.key] = ConfigField.fromJson(v);
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

    final csRaw = json['config_schema'];
    AppManifest? configSchema;
    if (csRaw is Map<String, dynamic>) {
      // Inject id from outer manifest if absent in config_schema.
      // The plugin's id IS the AppManifest's id in this context.
      final csJson = Map<String, dynamic>.from(csRaw)
        ..putIfAbsent('id', () => name);
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

    return PluginManifest(
      schemaVersion: schemaVersion,
      minTuiVersion: minTui,
      name: name,
      description: header['description'] as String? ?? '',
      config: configMap,
      actions: actionMap,
      permissions: perms,
      dashboard: dashboard,
      configSchema: configSchema,
    );
  }

  Map<String, dynamic> toJson() => {
    'manifest': {
      'schema_version': schemaVersion,
      'min_tui_version': minTuiVersion,
      'name': name,
      if (description.isNotEmpty) 'description': description,
    },
    if (config.isNotEmpty)
      'config': {for (final e in config.entries) e.key: e.value.toJson()},
    if (actions.isNotEmpty)
      'actions': {for (final e in actions.entries) e.key: e.value.toJson()},
    if (!permissions.isEmpty) 'permissions': permissions.toJson(),
    if (dashboard != null) 'dashboard': dashboard!.toJson(),
    if (configSchema != null) 'config_schema': configSchema!.toJson(),
  };
}

/// A single user-editable field declared by a plugin manifest (D6).
///
/// [type] is the raw DSL string. Allowed shapes:
///
/// - `bool`, `int`, `string`, `secret` — primitive fields
/// - `select<a|b|c>` — choice from a non-empty `|`-separated list
/// - `list<T>` — homogeneous list where T is one of the primitives
///
/// Unknown shapes are rejected at parse time via [FormatException].
class ConfigField {
  final String type;
  final String label;
  final bool required;
  final dynamic defaultValue;

  const ConfigField({
    required this.type,
    required this.label,
    this.required = false,
    this.defaultValue,
  });

  factory ConfigField.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type == null) {
      throw const FormatException('config field missing `type`');
    }
    _validateTypeString(type);
    return ConfigField(
      type: type,
      label: json['label'] as String? ?? '',
      required: json['required'] as bool? ?? false,
      defaultValue: json['default'],
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'label': label,
    'required': required,
    if (defaultValue != null) 'default': defaultValue,
  };

  /// Returns null if [value] is acceptable for this field; otherwise
  /// a short human-readable reason. Used by the manifest validator
  /// when reading a plugin's `config.json`.
  String? validate(dynamic value) {
    if (value == null) return required ? 'required' : null;
    return _validateValue(type, value);
  }

  static const _primitives = {'bool', 'int', 'string', 'secret'};
  static final _selectRe = RegExp(r'^select<([^<>]+)>$');
  static final _listRe = RegExp(r'^list<([^<>]+)>$');

  static void _validateTypeString(String type) {
    if (_primitives.contains(type)) return;
    final sm = _selectRe.firstMatch(type);
    if (sm != null) {
      final choices = sm.group(1)!.split('|');
      if (choices.any((c) => c.isEmpty)) {
        throw FormatException('empty choice in select type: `$type`');
      }
      return;
    }
    final lm = _listRe.firstMatch(type);
    if (lm != null) {
      final inner = lm.group(1)!;
      if (!_primitives.contains(inner)) {
        throw FormatException(
          'list element type must be one of $_primitives, got `$inner` in `$type`',
        );
      }
      return;
    }
    throw FormatException('unknown config field type: `$type`');
  }

  static String? _validateValue(String type, dynamic value) {
    if (_primitives.contains(type)) {
      return _validatePrimitive(type, value);
    }
    final sm = _selectRe.firstMatch(type);
    if (sm != null) {
      final choices = sm.group(1)!.split('|');
      if (value is! String) return 'expected one of ${choices.join(", ")}';
      if (!choices.contains(value)) {
        return 'must be one of ${choices.join(", ")}';
      }
      return null;
    }
    final lm = _listRe.firstMatch(type);
    if (lm != null) {
      if (value is! List) return 'expected list';
      final inner = lm.group(1)!;
      for (final item in value) {
        final err = _validatePrimitive(inner, item);
        if (err != null) return 'list element: $err';
      }
      return null;
    }
    return 'unknown type `$type`';
  }

  static String? _validatePrimitive(String type, dynamic value) {
    switch (type) {
      case 'bool':
        return value is bool ? null : 'expected bool';
      case 'int':
        return value is int ? null : 'expected int';
      case 'string':
      case 'secret':
        return value is String ? null : 'expected string';
      default:
        return 'unknown primitive `$type`';
    }
  }
}
