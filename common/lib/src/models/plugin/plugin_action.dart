/// One field the TUI collects from the operator and passes to a
/// [PluginAction] at invocation time. Designed for short-lived
/// values that must not be persisted to `config.json` — tailscale
/// pre-auth keys, one-time unlock tokens, OTP codes.
///
/// Transport into the action:
///
/// - `command:` action → env var `NIXBLITZ_INPUT_<NAME_UPPER>` on
///   the spawned bash process.
/// - `unit:` action → a transient EnvironmentFile at
///   `/run/nixblitz/<unit-stem>-input.env` written by the TUI via
///   SudoSession, deleted after the unit exits. The plugin's unit
///   must declare `EnvironmentFile=-/run/nixblitz/<stem>-input.env`
///   and read `$NIXBLITZ_INPUT_<NAME_UPPER>` in its script.
///
/// Validation is intentionally minimal: the runner trusts the
/// operator's input as-is. Plugins that need stricter checks
/// (length, charset) do them server-side in their script.
class PluginActionInput {
  /// Identifier used as the env-var suffix
  /// (`NIXBLITZ_INPUT_<NAME_UPPER>`). Restricted to
  /// `[a-z][a-z0-9_]*` so the uppercased version is always a valid
  /// shell variable name.
  final String name;

  /// Shown above the input field in the TUI prompt.
  final String label;

  /// Optional helper text rendered below the label. Empty by
  /// default; long descriptions wrap.
  final String description;

  /// `'text'` renders as a plain input row; `'secret'` masks the
  /// value with `*` and reuses the password-input widget. Used by
  /// the TUI to pick the prompt widget; the runner treats both the
  /// same way.
  final String type;

  const PluginActionInput({
    required this.name,
    required this.label,
    this.description = '',
    this.type = 'text',
  });

  static final _nameRe = RegExp(r'^[a-z][a-z0-9_]*$');

  factory PluginActionInput.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || !_nameRe.hasMatch(name)) {
      throw FormatException(
        'action input `name` must match [a-z][a-z0-9_]*; got "$name"',
      );
    }
    final label = json['label'];
    if (label is! String || label.isEmpty) {
      throw const FormatException('action input `label` is required');
    }
    final type = json['type'] as String? ?? 'text';
    if (type != 'text' && type != 'secret') {
      throw FormatException(
        'action input `type` must be "text" or "secret"; got "$type"',
      );
    }
    return PluginActionInput(
      name: name,
      label: label,
      description: json['description'] as String? ?? '',
      type: type,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'label': label,
    if (description.isNotEmpty) 'description': description,
    if (type != 'text') 'type': type,
  };

  /// Env-var name derived from [name]. Both the runner and the
  /// plugin's unit script use this string.
  String get envVarName => 'NIXBLITZ_INPUT_${name.toUpperCase()}';
}

/// A single user-triggerable verb declared by a plugin manifest.
///
/// Plugins use this to expose post-install operations the operator
/// might want: backup, reset, switch a setting, etc.  The manifest
/// renders these in the Configure → plugins → `<plugin>` screen as a
/// menu after the config fields.
///
/// Discriminated by privilege:
///
/// - `command:` actions run as the admin user via `bash -c "<cmd>"`.
///   No sudo. Use for read-only or per-user operations.
/// - `unit:` actions dispatch a Type=oneshot systemd unit the plugin
///   ships in its plugin.nix. Run via `systemctl start <unit>` and
///   require the unit to be listed in `permissions.privileged_units`.
///   This is the only path to root from a plugin (Posture A).
///
/// Exactly one of `command` / `unit` must be set per action.
class PluginAction {
  /// Human-readable menu entry. Required.
  final String label;

  /// Shown in the y/N confirmation overlay.  Empty string for
  /// trivial actions where the label is self-explanatory.
  final String description;

  /// Shell command to run as the admin user. Mutually exclusive
  /// with [unit].
  final String? command;

  /// Systemd one-shot unit to dispatch as root. Mutually exclusive
  /// with [command]. Must appear in
  /// `PluginPermissions.privilegedUnits`.
  final String? unit;

  /// When true, the TUI shows a y/N prompt before launching.
  /// Default true — most actions are at least state-touching;
  /// flip to false for idempotent or read-only actions.
  final bool confirm;

  /// Hard timeout in seconds. Runner sends SIGTERM at the limit,
  /// SIGKILL after a grace period.
  final int timeoutSeconds;

  /// Operator-supplied values collected by the TUI right before the
  /// action runs. Empty list = no prompt. See [PluginActionInput]
  /// for transport details.
  final List<PluginActionInput> inputs;

  const PluginAction({
    required this.label,
    this.description = '',
    this.command,
    this.unit,
    this.confirm = true,
    this.timeoutSeconds = 300,
    this.inputs = const [],
  });

  /// True when this action dispatches a systemd unit (and therefore
  /// runs privileged via SudoSession + systemctl).
  bool get isPrivileged => unit != null;

  factory PluginAction.fromJson(Map<String, dynamic> json) {
    final label = json['label'] as String?;
    if (label == null || label.isEmpty) {
      throw const FormatException('action.label is required');
    }
    if (json.containsKey('run_as_root')) {
      throw FormatException(
        'action.run_as_root is no longer supported (manifest schema v2). '
        'Replace `run_as_root: true` + `command: "<cmd>"` with '
        '`unit: "<your-plugin-action>.service"` and ship the unit as a '
        'Type=oneshot service in your plugin.nix. List the unit in '
        'permissions.privileged_units.',
      );
    }
    final command = json['command'] as String?;
    final unit = json['unit'] as String?;
    if (command == null && unit == null) {
      throw FormatException(
        'action `$label` must declare either `command` or `unit`',
      );
    }
    if (command != null && unit != null) {
      throw FormatException(
        'action `$label` declares both `command` and `unit`; pick one',
      );
    }
    if (command != null && command.isEmpty) {
      throw FormatException('action `$label` has empty `command`');
    }
    if (unit != null && unit.isEmpty) {
      throw FormatException('action `$label` has empty `unit`');
    }
    final timeout = json['timeout_seconds'] as int? ?? 300;
    if (timeout <= 0) {
      throw FormatException(
        'action.timeout_seconds must be positive, got $timeout',
      );
    }
    final rawInputs = json['inputs'] as List? ?? const [];
    final inputs = <PluginActionInput>[];
    final seen = <String>{};
    for (final entry in rawInputs.cast<Map<String, dynamic>>()) {
      final input = PluginActionInput.fromJson(entry);
      if (!seen.add(input.name)) {
        throw FormatException(
          'action `$label` declares duplicate input "${input.name}"',
        );
      }
      inputs.add(input);
    }
    return PluginAction(
      label: label,
      description: json['description'] as String? ?? '',
      command: command,
      unit: unit,
      confirm: json['confirm'] as bool? ?? true,
      timeoutSeconds: timeout,
      inputs: inputs,
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    if (description.isNotEmpty) 'description': description,
    if (command != null) 'command': command,
    if (unit != null) 'unit': unit,
    if (!confirm) 'confirm': confirm,
    if (timeoutSeconds != 300) 'timeout_seconds': timeoutSeconds,
    if (inputs.isNotEmpty) 'inputs': inputs.map((i) => i.toJson()).toList(),
  };
}
