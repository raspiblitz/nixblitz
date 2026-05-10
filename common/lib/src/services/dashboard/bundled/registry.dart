import 'package:common/src/services/dashboard/bundled/embedded_manifests.dart';
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';

/// Manifests bundled in the TUI binary. After the bitcoin/lightning
/// plugin extraction this is just hardware + system (procfs/sysfs
/// readers, no plugin dep). Plugin-owned tile manifests are merged
/// in by `tileManifestsProvider` at runtime.
List<TileManifest> get bundledManifests {
  final raw = EmbeddedManifests.getAll();
  // Stable order: alphabetical by id (hardware, system).
  final list = raw.values.map(TileManifest.fromJsonString).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(list);
}
