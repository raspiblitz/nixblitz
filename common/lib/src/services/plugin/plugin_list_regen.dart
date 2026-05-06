import 'dart:io';

import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

/// Outcome of a [regeneratePluginsList] call.
class RegenResult {
  /// Paths written to the new `plugins.list` (sorted).
  final List<String> written;

  /// Paths present in the previous `plugins.list` that had no corresponding
  /// marker — dropped from the new file and warn-logged. This is the
  /// security boundary: a malicious plugin cannot sneak imports past us by
  /// editing `plugins.list` directly.
  final List<String> dropped;

  const RegenResult({required this.written, required this.dropped});
}

/// Regenerate `<baseDir>/plugins.list` from the marker set under
/// `<baseDir>/plugins/`.
///
/// Filters:
///   - markers with `disabled: true` are skipped
///   - markers whose id is not in [satisfiedPluginIds] are skipped
///     (caller computes this from enabled+dep-satisfied plugins)
///
/// Orphan paths in the previous `plugins.list` (no corresponding marker)
/// are removed and reported in [RegenResult.dropped].
RegenResult regeneratePluginsList({
  required String baseDir,
  required Set<String> satisfiedPluginIds,
}) {
  final pluginsRoot = '$baseDir/plugins';
  final markers = discoverInstalledMarkers(pluginsRoot);

  final eligibleMarkers = markers
      .where((m) => !m.disabled && satisfiedPluginIds.contains(m.id))
      .toList();

  final eligiblePaths = eligibleMarkers
      .map((m) => '$pluginsRoot/${m.id}')
      .toSet();

  final listFile = File('$baseDir/plugins.list');
  final dropped = <String>[];
  if (listFile.existsSync()) {
    final old = listFile
        .readAsStringSync()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    for (final path in old) {
      if (!eligiblePaths.contains(path)) {
        dropped.add(path);
        LogService.warn(
          'plugins.list: dropped orphan path on regen — '
          'no marker found at $path',
        );
      }
    }
  }

  final newPaths = eligibleMarkers.map((m) => '$pluginsRoot/${m.id}').toList()
    ..sort();
  listFile.writeAsStringSync('${newPaths.join("\n")}\n');

  return RegenResult(written: newPaths, dropped: dropped);
}
