import 'dart:convert';
import 'dart:io';

import 'package:common/src/services/log_service.dart';

const _markerFilename = '.nixblitz-installed.json';

/// Authoritative install record for a plugin.
///
/// Written to `~/nixblitz/plugins/<id>/.nixblitz-installed.json` at install
/// time and consumed by [regeneratePluginsList] to derive `plugins.list`.
class PluginMarker {
  final String id;
  final String url;
  final String version;
  final String rev;
  final DateTime installedAt;
  final bool disabled;

  /// Tracked git branch (default `main`). Refresh re-clones from this
  /// branch and updates [rev] to the new HEAD.
  final String branch;

  /// Whether `plugin refresh-all` advances this plugin's [rev]. Set
  /// false by `plugin pin <id>` to hold a specific version against
  /// system-wide updates.
  final bool autoUpdate;

  /// Fingerprint of the SSH or OpenPGP key that signed the commit at
  /// [rev], if any. Captured at install time when the rev carried a
  /// signature; null when the operator consented to an unsigned
  /// commit. On refresh, a non-null fingerprint that doesn't match
  /// the new rev's signature triggers a re-consent prompt.
  final String? signatureFingerprint;

  const PluginMarker({
    required this.id,
    required this.url,
    required this.version,
    required this.rev,
    required this.installedAt,
    required this.disabled,
    this.branch = 'main',
    this.autoUpdate = true,
    this.signatureFingerprint,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'version': version,
    'rev': rev,
    'installed_at': installedAt.toIso8601String(),
    if (disabled) 'disabled': true,
    if (branch != 'main') 'branch': branch,
    if (!autoUpdate) 'auto_update': false,
    if (signatureFingerprint != null)
      'signature_fingerprint': signatureFingerprint,
  };

  factory PluginMarker.fromJson(Map<String, dynamic> j) => PluginMarker(
    id: j['id'] as String,
    url: j['url'] as String,
    version: j['version'] as String,
    rev: j['rev'] as String,
    installedAt: DateTime.parse(j['installed_at'] as String),
    disabled: (j['disabled'] as bool?) ?? false,
    branch: (j['branch'] as String?) ?? 'main',
    autoUpdate: (j['auto_update'] as bool?) ?? true,
    signatureFingerprint: j['signature_fingerprint'] as String?,
  );

  PluginMarker copyWith({
    String? version,
    String? rev,
    bool? disabled,
    String? branch,
    bool? autoUpdate,
    String? signatureFingerprint,
    bool clearSignatureFingerprint = false,
  }) => PluginMarker(
    id: id,
    url: url,
    version: version ?? this.version,
    rev: rev ?? this.rev,
    installedAt: installedAt,
    disabled: disabled ?? this.disabled,
    branch: branch ?? this.branch,
    autoUpdate: autoUpdate ?? this.autoUpdate,
    signatureFingerprint: clearSignatureFingerprint
        ? null
        : (signatureFingerprint ?? this.signatureFingerprint),
  );
}

/// Write [marker] to `<pluginDir>/.nixblitz-installed.json`.
///
/// [pluginDir] must already exist; the install flow owns directory creation.
void writeMarker(String pluginDir, PluginMarker marker) {
  File(
    '$pluginDir/$_markerFilename',
  ).writeAsStringSync(jsonEncode(marker.toJson()));
}

/// Read the marker from `<pluginDir>/.nixblitz-installed.json`.
///
/// Returns null if the file is missing OR malformed (any decode/parse error).
/// Malformed cases are warn-logged so an operator can debug a plugin that
/// silently disappears from `plugins.list`.
PluginMarker? readMarker(String pluginDir) {
  final f = File('$pluginDir/$_markerFilename');
  if (!f.existsSync()) return null;
  try {
    return PluginMarker.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  } catch (e) {
    LogService.warn('readMarker: malformed marker at $pluginDir: $e');
    return null;
  }
}

/// Walk [pluginsRoot] and return every valid marker found.
///
/// Subdirectories without a marker (or with a malformed one) are silently
/// skipped. Order is platform-dependent — callers should not rely on it.
List<PluginMarker> discoverInstalledMarkers(String pluginsRoot) {
  final dir = Directory(pluginsRoot);
  if (!dir.existsSync()) return const [];
  final out = <PluginMarker>[];
  for (final entry in dir.listSync()) {
    if (entry is Directory) {
      final m = readMarker(entry.path);
      if (m != null) out.add(m);
    }
  }
  return out;
}
