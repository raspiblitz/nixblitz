/// Identity + lifecycle metadata for a single installed plugin. One
/// entry per plugin in `NixblitzConfig.plugins`.
///
/// The canonical identifier is [id] — always the upstream URL (D5).
/// [dirName] is the sanitized on-disk directory name under
/// `~/nixblitz/plugins/`; the two differ when a URL collision forced a
/// numeric suffix at install time.
///
/// Tombstones (soft-deleted rows, D4) have [uninstalledAt] set and
/// [enabled] = false. Directory has been wiped but the row stays so
/// we can reinstall later from the same pin.
library;

class PluginEntry {
  /// Canonical plugin URL — the D5 identifier.
  final String id;

  /// Source URL. Currently identical to [id]; split for future
  /// aliasing (e.g. one plugin served from a primary + mirror).
  final String url;

  /// Tracked git branch (D7). Default `main`.
  final String branch;

  /// Pinned commit SHA (D10). Full, not abbreviated.
  final String pinnedRev;

  /// On-disk directory name under `~/nixblitz/plugins/`. Derived from
  /// [id] at install time; may carry a numeric suffix if the default
  /// derivation collided with an existing entry.
  final String dirName;

  final DateTime installedAt;

  /// Set on soft-delete (D4). Null for active plugins.
  final DateTime? uninstalledAt;

  final DateTime lastUpdatedAt;

  /// Module enabled in the generated NixOS config. False once
  /// soft-deleted or when the user toggles it off (future).
  final bool enabled;

  /// Whether "Update entire system" advances this plugin's
  /// [pinnedRev] (D11). Flipped off by `plugin pin <id>`.
  final bool autoUpdate;

  /// Fingerprint of the SSH or OpenPGP key that signed the commit
  /// at [pinnedRev], if any. Captured at install time when the
  /// rev carried a signature; null when the operator consented to
  /// an unsigned commit (or this entry pre-dates Approach A).
  ///
  /// On refresh, a non-null pinned fingerprint that doesn't match
  /// the new rev's signature triggers `PluginSignatureMismatch`
  /// — the operator must explicitly re-consent before the
  /// publisher key change is accepted. See
  /// `docs/decisions/plugin-trust-models.md` Approach A.
  final String? signatureFingerprint;

  const PluginEntry({
    required this.id,
    required this.url,
    required this.branch,
    required this.pinnedRev,
    required this.dirName,
    required this.installedAt,
    this.uninstalledAt,
    required this.lastUpdatedAt,
    this.enabled = true,
    this.autoUpdate = true,
    this.signatureFingerprint,
  });

  bool get isTombstone => uninstalledAt != null;

  factory PluginEntry.fromJson(Map<String, dynamic> json) => PluginEntry(
    id: json['id'] as String,
    url: json['url'] as String,
    branch: json['branch'] as String? ?? 'main',
    pinnedRev: json['pinned_rev'] as String,
    dirName: json['dir_name'] as String,
    installedAt: DateTime.parse(json['installed_at'] as String),
    uninstalledAt: json['uninstalled_at'] == null
        ? null
        : DateTime.parse(json['uninstalled_at'] as String),
    lastUpdatedAt: DateTime.parse(json['last_updated_at'] as String),
    enabled: json['enabled'] as bool? ?? true,
    autoUpdate: json['auto_update'] as bool? ?? true,
    signatureFingerprint: json['signature_fingerprint'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'branch': branch,
    'pinned_rev': pinnedRev,
    'dir_name': dirName,
    'installed_at': installedAt.toIso8601String(),
    if (uninstalledAt != null)
      'uninstalled_at': uninstalledAt!.toIso8601String(),
    'last_updated_at': lastUpdatedAt.toIso8601String(),
    'enabled': enabled,
    'auto_update': autoUpdate,
    if (signatureFingerprint != null)
      'signature_fingerprint': signatureFingerprint,
  };

  PluginEntry copyWith({
    String? id,
    String? url,
    String? branch,
    String? pinnedRev,
    String? dirName,
    DateTime? installedAt,
    DateTime? uninstalledAt,
    bool clearUninstalledAt = false,
    DateTime? lastUpdatedAt,
    bool? enabled,
    bool? autoUpdate,
    String? signatureFingerprint,
    bool clearSignatureFingerprint = false,
  }) => PluginEntry(
    id: id ?? this.id,
    url: url ?? this.url,
    branch: branch ?? this.branch,
    pinnedRev: pinnedRev ?? this.pinnedRev,
    dirName: dirName ?? this.dirName,
    installedAt: installedAt ?? this.installedAt,
    uninstalledAt:
        clearUninstalledAt ? null : (uninstalledAt ?? this.uninstalledAt),
    lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    enabled: enabled ?? this.enabled,
    autoUpdate: autoUpdate ?? this.autoUpdate,
    signatureFingerprint: clearSignatureFingerprint
        ? null
        : (signatureFingerprint ?? this.signatureFingerprint),
  );

  @override
  bool operator ==(Object other) =>
      other is PluginEntry &&
      other.id == id &&
      other.url == url &&
      other.branch == branch &&
      other.pinnedRev == pinnedRev &&
      other.dirName == dirName &&
      other.installedAt == installedAt &&
      other.uninstalledAt == uninstalledAt &&
      other.lastUpdatedAt == lastUpdatedAt &&
      other.enabled == enabled &&
      other.autoUpdate == autoUpdate &&
      other.signatureFingerprint == signatureFingerprint;

  @override
  int get hashCode => Object.hash(
    id,
    url,
    branch,
    pinnedRev,
    dirName,
    installedAt,
    uninstalledAt,
    lastUpdatedAt,
    enabled,
    autoUpdate,
    signatureFingerprint,
  );
}
