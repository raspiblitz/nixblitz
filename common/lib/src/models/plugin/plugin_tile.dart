/// Plugin-declared dashboard tile (Phase 3).
///
/// `PluginTileSpec` is the static declaration that lives in
/// `plugin.json`'s `dashboard` block. `PluginTileSnapshot` is the
/// runtime data the polling service emits each tick.
///
/// Both stay free of `nocterm` types so this lives in `common/`
/// without dragging a TUI dep across packages. The TUI side maps
/// the string color keys (`"ok"`/`"warn"`/`"error"` and hex strings)
/// into actual `Color` instances at render time.
library;

/// Static plugin-tile declaration from plugin.json.
class PluginTileSpec {
  /// Tile heading.
  final String title;

  /// Hex color string `#rrggbb` for the title + top rule. Defaults
  /// to a neutral grey when absent.
  final String accentColorHex;

  /// Shell command polled at [pollInterval]. Output is parsed as
  /// JSON per the tile-state protocol (see plugins.md Phase 3 plan).
  final String command;

  final Duration pollInterval;
  final Duration timeout;

  static const Duration _minPollInterval = Duration(seconds: 5);
  static const String _defaultAccent = '#888899';

  const PluginTileSpec({
    required this.title,
    this.accentColorHex = _defaultAccent,
    required this.command,
    this.pollInterval = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 5),
  });

  factory PluginTileSpec.fromJson(Map<String, dynamic> json) {
    final title = json['title'] as String?;
    if (title == null || title.isEmpty) {
      throw const FormatException('dashboard.title is required');
    }
    final command = json['command'] as String?;
    if (command == null || command.isEmpty) {
      throw const FormatException('dashboard.command is required');
    }
    final pollSec = json['poll_interval_seconds'] as int? ?? 30;
    if (pollSec < _minPollInterval.inSeconds) {
      throw FormatException(
        'dashboard.poll_interval_seconds must be ≥ ${_minPollInterval.inSeconds}, '
        'got $pollSec',
      );
    }
    final timeoutSec = json['timeout_seconds'] as int? ?? 5;
    if (timeoutSec <= 0) {
      throw FormatException(
        'dashboard.timeout_seconds must be positive, got $timeoutSec',
      );
    }
    final accent = json['accent_color'] as String? ?? _defaultAccent;
    if (!_isValidHexColor(accent)) {
      throw FormatException(
        'dashboard.accent_color must be `#rrggbb`, got `$accent`',
      );
    }
    if (json.containsKey('run_as_root')) {
      throw const FormatException(
        'dashboard.run_as_root is no longer supported (manifest schema '
        'v2). Tile commands always run as the admin user; expose any '
        'privileged data through a group-readable file or a setuid '
        'wrapper.',
      );
    }
    return PluginTileSpec(
      title: title,
      accentColorHex: accent,
      command: command,
      pollInterval: Duration(seconds: pollSec),
      timeout: Duration(seconds: timeoutSec),
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    if (accentColorHex != _defaultAccent) 'accent_color': accentColorHex,
    'command': command,
    if (pollInterval.inSeconds != 30)
      'poll_interval_seconds': pollInterval.inSeconds,
    if (timeout.inSeconds != 5) 'timeout_seconds': timeout.inSeconds,
  };

  static final _hexRe = RegExp(r'^#[0-9a-fA-F]{6}$');
  static bool _isValidHexColor(String s) => _hexRe.hasMatch(s);
}

/// One key/value pair rendered as a row inside a plugin tile. Plain
/// strings — color decisions stay in the TUI layer.
class PluginTileRow {
  final String label;
  final String value;
  const PluginTileRow(this.label, this.value);
}

/// Status / footer color levels. Mapped to actual nocterm `Color`
/// instances by the TUI-side `PluginTile` widget.
enum PluginTileStatus {
  ok,
  warn,
  error;

  static PluginTileStatus? tryParse(String? raw) => switch (raw) {
    'ok' => PluginTileStatus.ok,
    'warn' => PluginTileStatus.warn,
    'error' => PluginTileStatus.error,
    _ => null,
  };
}

/// Runtime tile state, emitted by `PluginDashboardService` after
/// each successful poll (or with `footer` set in the failure cases).
class PluginTileSnapshot {
  final String title;
  final String accentColorHex;
  final String? statusLabel;
  final PluginTileStatus? statusColor;
  final List<PluginTileRow> rows;
  final String? footer;
  final PluginTileStatus? footerColor;

  const PluginTileSnapshot({
    required this.title,
    required this.accentColorHex,
    this.statusLabel,
    this.statusColor,
    this.rows = const [],
    this.footer,
    this.footerColor,
  });

  /// Parse the JSON output of a tile-state command into a snapshot.
  /// Throws `FormatException` if the input isn't a flat object.
  factory PluginTileSnapshot.fromCommandOutput({
    required PluginTileSpec spec,
    required Map<String, dynamic> json,
  }) {
    final rows = <PluginTileRow>[];
    String? statusLabel;
    PluginTileStatus? statusColor;
    String? footer;
    PluginTileStatus? footerColor;

    for (final entry in json.entries) {
      switch (entry.key) {
        case '_status_label':
          statusLabel = entry.value?.toString();
        case '_status_color':
          statusColor = PluginTileStatus.tryParse(entry.value?.toString());
        case '_footer':
          footer = entry.value?.toString();
        case '_footer_color':
          footerColor = PluginTileStatus.tryParse(entry.value?.toString());
        default:
          rows.add(PluginTileRow(entry.key, entry.value?.toString() ?? ''));
      }
    }

    return PluginTileSnapshot(
      title: spec.title,
      accentColorHex: spec.accentColorHex,
      statusLabel: statusLabel,
      statusColor: statusColor,
      rows: List.unmodifiable(rows),
      footer: footer,
      footerColor: footerColor,
    );
  }

  /// Failure-state factory: tile rendered with a red footer + the
  /// reason in plain text.
  factory PluginTileSnapshot.failure({
    required PluginTileSpec spec,
    required String reason,
    List<PluginTileRow> rows = const [],
  }) {
    return PluginTileSnapshot(
      title: spec.title,
      accentColorHex: spec.accentColorHex,
      rows: rows,
      footer: reason,
      footerColor: PluginTileStatus.error,
    );
  }
}
