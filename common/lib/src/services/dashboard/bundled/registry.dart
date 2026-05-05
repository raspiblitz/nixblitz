import 'package:common/src/services/dashboard/bundled/embedded_manifests.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';

/// Manifests bundled in the TUI binary. In Phase 4 this list will be
/// extended at startup to include manifests shipped by installed
/// plugins; the renderer doesn't care about the source.
List<TileManifest> get bundledManifests {
  final raw = EmbeddedManifests.getAll();
  // Stable order: alphabetical by id. Matches existing tile order in
  // dashboard_view.dart: bitcoin, hardware, lightning, system.
  final list = raw.values.map(TileManifest.fromJsonString).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(list);
}
