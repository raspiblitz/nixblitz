/// Declarative manifest permissions (D14). Phase 1 surfaces these
/// at `plugin add` consent time only; no runtime enforcement.
///
/// The shape is frozen here so plugins authored today survive the
/// eventual enforcement layer without a manifest-schema bump — we
/// can layer per-plugin users, scoped JWTs, or wrapped CLIs behind
/// these exact keys later.
library;

class PluginPermissions {
  /// Bitcoin RPC scopes requested. Conventional values: `rpc:read`,
  /// `rpc:write`.
  final List<String> bitcoin;

  /// Lightning RPC scopes. Conventional values: `rpc:read`,
  /// `rpc:write`, `wallet:read`, `wallet:write`.
  final List<String> lightning;

  /// Filesystem read paths. Absolute paths expected.
  final List<String> filesystemRead;

  /// Filesystem write paths. Absolute paths expected.
  final List<String> filesystemWrite;

  /// Network access scopes. Conventional values: `outbound`,
  /// `listen:<port>`.
  final List<String> network;

  const PluginPermissions({
    this.bitcoin = const [],
    this.lightning = const [],
    this.filesystemRead = const [],
    this.filesystemWrite = const [],
    this.network = const [],
  });

  factory PluginPermissions.fromJson(Map<String, dynamic> json) {
    final fs = json['filesystem'] as Map<String, dynamic>? ?? const {};
    return PluginPermissions(
      bitcoin: _stringList(json['bitcoin']),
      lightning: _stringList(json['lightning']),
      filesystemRead: _stringList(fs['read']),
      filesystemWrite: _stringList(fs['write']),
      network: _stringList(json['network']),
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
  };

  bool get isEmpty =>
      bitcoin.isEmpty &&
      lightning.isEmpty &&
      filesystemRead.isEmpty &&
      filesystemWrite.isEmpty &&
      network.isEmpty;

  /// Human-readable lines for the `plugin add` consent prompt.
  /// Empty list → no permissions requested (still worth surfacing
  /// so the user sees "requests: none").
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
    return lines;
  }
}
