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

  const PluginMarker({
    required this.id,
    required this.url,
    required this.version,
    required this.rev,
    required this.installedAt,
    required this.disabled,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'version': version,
    'rev': rev,
    'installed_at': installedAt.toIso8601String(),
    if (disabled) 'disabled': true,
  };

  factory PluginMarker.fromJson(Map<String, dynamic> j) => PluginMarker(
    id: j['id'] as String,
    url: j['url'] as String,
    version: j['version'] as String,
    rev: j['rev'] as String,
    installedAt: DateTime.parse(j['installed_at'] as String),
    disabled: (j['disabled'] as bool?) ?? false,
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
