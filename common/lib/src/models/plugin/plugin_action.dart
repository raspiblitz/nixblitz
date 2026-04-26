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

  const PluginAction({
    required this.label,
    this.description = '',
    this.command,
    this.unit,
    this.confirm = true,
    this.timeoutSeconds = 300,
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
    return PluginAction(
      label: label,
      description: json['description'] as String? ?? '',
      command: command,
      unit: unit,
      confirm: json['confirm'] as bool? ?? true,
      timeoutSeconds: timeout,
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    if (description.isNotEmpty) 'description': description,
    if (command != null) 'command': command,
    if (unit != null) 'unit': unit,
    if (!confirm) 'confirm': confirm,
    if (timeoutSeconds != 300) 'timeout_seconds': timeoutSeconds,
  };
}
