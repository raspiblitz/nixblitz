import 'dart:io';

import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

/// Outcome of a [regeneratePluginsList] call.
class RegenResult {
  /// Plugin ids written to the new `plugins.list` (sorted).
  final List<String> written;

  /// Ids present in the previous `plugins.list` that had no corresponding
  /// marker — dropped from the new file and warn-logged. This is the
  /// security boundary: a malicious plugin cannot sneak imports past us by
  /// editing `plugins.list` directly.
  final List<String> dropped;

  const RegenResult({required this.written, required this.dropped});
}

/// Regenerate `<baseDir>/plugins.list` from the marker set under
/// `<baseDir>/plugins/`.
///
/// File format: one plugin id per line. The flake's `pluginModules`
/// derivation joins each id with `./plugins/<id>` to locate the
/// plugin checkout — keeps the file flake-portable (no operator
/// `$HOME` baked in).
///
/// Filters:
///   - markers with `disabled: true` are skipped
///   - markers whose id is not in [satisfiedPluginIds] are skipped
///     (caller computes this from enabled+dep-satisfied plugins)
///
/// Orphan ids in the previous `plugins.list` (no corresponding marker)
/// are removed and reported in [RegenResult.dropped].
RegenResult regeneratePluginsList({
  required String baseDir,
  required Set<String> satisfiedPluginIds,
}) {
  final pluginsRoot = '$baseDir/plugins';
  final markers = discoverInstalledMarkers(pluginsRoot);

  final eligibleIds = markers
      .where((m) => !m.disabled && satisfiedPluginIds.contains(m.id))
      .map((m) => m.id)
      .toSet();

  final listFile = File('$baseDir/plugins.list');
  final dropped = <String>[];
  if (listFile.existsSync()) {
    final old = listFile
        .readAsStringSync()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    for (final id in old) {
      if (!eligibleIds.contains(id)) {
        dropped.add(id);
        LogService.warn(
          'plugins.list: dropped orphan id on regen — '
          'no marker found for `$id`',
        );
      }
    }
  }

  final newIds = eligibleIds.toList()..sort();
  listFile.writeAsStringSync('${newIds.join("\n")}\n');

  return RegenResult(written: newIds, dropped: dropped);
}
