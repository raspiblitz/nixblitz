/// A single user-triggerable verb declared by a plugin manifest
/// (Phase 4). Plugins use this to expose post-install operations
/// the operator might want: backup, reset, switch a setting, etc.
///
/// The manifest renders these in the Configure → plugins → `<plugin>`
/// screen as a menu after the config fields. Triggering one runs
/// the declared shell command, optionally with sudo, and streams
/// stdout/stderr back to the TUI.
///
/// See `docs/decisions/plugins.md` and the Phase 4 plan for
/// rationale + scope.
class PluginAction {
  /// Human-readable menu entry. Required.
  final String label;

  /// Shown in the y/N confirmation overlay. Empty string for
  /// trivial actions where the label is self-explanatory.
  final String description;

  /// Shell command. Passed to `bash -c "<command>"` at runtime.
  /// May be a script name resolvable via PATH (the plugin.nix
  /// typically installs it with `pkgs.writeShellScriptBin`) or an
  /// inline shell snippet like `systemctl restart lnbits`.
  final String command;

  /// When true, the runner wraps the command with `sudo -n`.
  /// Operator's passwordless-sudo (already required by Apply +
  /// blitz-api) is the assumed grant.
  final bool runAsRoot;

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
    required this.command,
    this.runAsRoot = false,
    this.confirm = true,
    this.timeoutSeconds = 300,
  });

  factory PluginAction.fromJson(Map<String, dynamic> json) {
    final label = json['label'] as String?;
    if (label == null || label.isEmpty) {
      throw const FormatException('action.label is required');
    }
    final command = json['command'] as String?;
    if (command == null || command.isEmpty) {
      throw const FormatException('action.command is required');
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
      runAsRoot: json['run_as_root'] as bool? ?? false,
      confirm: json['confirm'] as bool? ?? true,
      timeoutSeconds: timeout,
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    if (description.isNotEmpty) 'description': description,
    'command': command,
    if (runAsRoot) 'run_as_root': runAsRoot,
    if (!confirm) 'confirm': confirm,
    if (timeoutSeconds != 300) 'timeout_seconds': timeoutSeconds,
  };
}
