import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

/// All `PluginMarker`s discovered under `<baseDir>/plugins/<id>/`.
/// Sibling to [installedPluginsProvider]: that one surfaces the
/// parsed `plugin.json` for each install, this one surfaces the
/// marker so callers can read the operator's chosen branch (channel),
/// pin state, signature fingerprint, etc.
///
/// `installedPluginsProvider` already calls `discoverInstalledMarkers`
/// internally and discards the markers after locating each manifest;
/// we re-walk the same directory rather than reshaping that provider
/// because the two pieces of data have different update cadences
/// (a manifest edit changes one; a `plugin update` or `plugin switch-
/// channel` changes the other) and overloading either would muddy
/// the dependency graph.
final installedPluginMarkersProvider = Provider<List<PluginMarker>>((ref) {
  final baseDir = ref.watch(baseDirProvider);
  final markers = discoverInstalledMarkers('$baseDir/plugins');
  // Same id sort as installedPluginsProvider so callers can zip the
  // two by index without keying through a map.
  markers.sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(markers);
});
