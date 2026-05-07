import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

/// All plugins discovered under `<baseDir>/plugins/<id>/` that have a
/// `.nixblitz-installed.json` marker AND a parseable `plugin.json`.
///
/// Reads from [baseDirProvider] (overridden in tests + at app startup).
/// Returns an unmodifiable list — callers can't mutate the manifest set.
///
/// Markers without a `plugin.json` or with malformed JSON are warn-logged
/// and skipped, so an operator can debug a plugin that silently disappears
/// from the dashboard.
final installedPluginsProvider = Provider<List<PluginManifest>>((ref) {
  final baseDir = ref.watch(baseDirProvider);
  final pluginsRoot = '$baseDir/plugins';
  final markers = discoverInstalledMarkers(pluginsRoot);
  final manifests = <PluginManifest>[];
  for (final marker in markers) {
    final manifestFile = File('$pluginsRoot/${marker.id}/plugin.json');
    if (!manifestFile.existsSync()) {
      LogService.warn(
        'plugin ${marker.id}: marker present but plugin.json missing; skipping',
      );
      continue;
    }
    try {
      final m = PluginManifest.fromJsonString(manifestFile.readAsStringSync());
      manifests.add(m);
    } catch (e) {
      LogService.warn('plugin ${marker.id}: plugin.json parse error: $e');
    }
  }
  // Sort by id so the rendered plugin list stays stable across reboots —
  // Directory.listSync() order is platform-dependent.
  manifests.sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(manifests);
});
