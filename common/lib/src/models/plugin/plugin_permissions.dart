/// Manifest permissions block. **Mostly author-supplied
/// documentation, NOT a security boundary.** Read D14 in
/// `docs/decisions/plugins.md` before treating any of these values
/// as enforced.
///
/// One field IS load-bearing: [privilegedUnits] is cross-checked
/// against `unit:` action references at manifest parse time, so a
/// plugin can't ship an action that triggers an undeclared systemd
/// unit. Everything else ([bitcoin], [lightning], [filesystemRead],
/// [filesystemWrite], [network]) is author-declared metadata that
/// nothing in NixBlitz reads at runtime — they exist so a future
/// audit tool has a vocabulary to grow into, but installing a
/// plugin grants the author root regardless of what these fields
/// say. Do not surface them as "permissions requested" in any UI.
library;

class PluginPermissions {
  /// Bitcoin RPC scopes the plugin claims to need. Documentation
  /// only — not enforced. Conventional values: `rpc:read`,
  /// `rpc:write`.
  final List<String> bitcoin;

  /// Lightning RPC scopes the plugin claims to need. Documentation
  /// only — not enforced. Conventional values: `rpc:read`,
  /// `rpc:write`, `wallet:read`, `wallet:write`.
  final List<String> lightning;

  /// Filesystem read paths the plugin claims to need. Documentation
  /// only — not enforced. Absolute paths expected.
  final List<String> filesystemRead;

  /// Filesystem write paths the plugin claims to need. Documentation
  /// only — not enforced. Absolute paths expected.
  final List<String> filesystemWrite;

  /// Network access scopes the plugin claims to need. Documentation
  /// only — not enforced. Conventional values: `outbound`,
  /// `listen:<port>`.
  final List<String> network;

  /// Systemd unit names this plugin's actions are allowed to start
  /// via `unit:` action dispatch (manifest schema v2). The plugin's
  /// plugin.nix must define every unit listed here. Listing here is
  /// what makes a unit usable by the operator from the TUI; absent
  /// units are rejected at manifest parse time.
  final List<String> privilegedUnits;

  const PluginPermissions({
    this.bitcoin = const [],
    this.lightning = const [],
    this.filesystemRead = const [],
    this.filesystemWrite = const [],
    this.network = const [],
    this.privilegedUnits = const [],
  });

  factory PluginPermissions.fromJson(Map<String, dynamic> json) {
    final fs = json['filesystem'] as Map<String, dynamic>? ?? const {};
    return PluginPermissions(
      bitcoin: _stringList(json['bitcoin']),
      lightning: _stringList(json['lightning']),
      filesystemRead: _stringList(fs['read']),
      filesystemWrite: _stringList(fs['write']),
      network: _stringList(json['network']),
      privilegedUnits: _stringList(json['privileged_units']),
    );
  }

  static List<String> _stringList(dynamic v) {
    if (v == null) return const [];
    if (v is! List) {
      throw FormatException('permissions expects a list, got ${v.runtimeType}');
    }
    return v.map((e) => e as String).toList(growable: false);
  }

  Map<String, dynamic> toJson() => {
    if (bitcoin.isNotEmpty) 'bitcoin': bitcoin,
    if (lightning.isNotEmpty) 'lightning': lightning,
    if (filesystemRead.isNotEmpty || filesystemWrite.isNotEmpty)
      'filesystem': {
        if (filesystemRead.isNotEmpty) 'read': filesystemRead,
        if (filesystemWrite.isNotEmpty) 'write': filesystemWrite,
      },
    if (network.isNotEmpty) 'network': network,
    if (privilegedUnits.isNotEmpty) 'privileged_units': privilegedUnits,
  };

  bool get isEmpty =>
      bitcoin.isEmpty &&
      lightning.isEmpty &&
      filesystemRead.isEmpty &&
      filesystemWrite.isEmpty &&
      network.isEmpty &&
      privilegedUnits.isEmpty;

  /// Human-readable lines describing the manifest's
  /// (author-supplied, unenforced) permission claims. **Do not
  /// surface these in the install consent prompt** — see the class
  /// docstring + D14. Kept for future audit / introspection
  /// tooling; existing test coverage exercises round-trip parsing.
  @Deprecated('do not surface as "permissions requested"; see D14')
  List<String> summaryLines() {
    if (isEmpty) return const ['requests: none'];
    final lines = <String>[];
    if (bitcoin.isNotEmpty) lines.add('bitcoin: ${bitcoin.join(", ")}');
    if (lightning.isNotEmpty) lines.add('lightning: ${lightning.join(", ")}');
    if (filesystemRead.isNotEmpty) {
      lines.add('filesystem read: ${filesystemRead.join(", ")}');
    }
    if (filesystemWrite.isNotEmpty) {
      lines.add('filesystem write: ${filesystemWrite.join(", ")}');
    }
    if (network.isNotEmpty) lines.add('network: ${network.join(", ")}');
    if (privilegedUnits.isNotEmpty) {
      lines.add('root systemd units: ${privilegedUnits.join(", ")}');
    }
    return lines;
  }
}
