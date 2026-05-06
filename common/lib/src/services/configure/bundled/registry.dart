import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/services/configure/bundled/embedded_schemas.dart';

/// Manifests bundled in the TUI binary. In Phase 4-6 each manifest moves
/// alongside its app's Nix module into a real plugin; the AppManifest
/// shape doesn't change, only the source.
List<AppManifest> get bundledAppManifests {
  final raw = EmbeddedAppSchemas.getAll();
  // Stable order: alphabetical by id.
  final list = raw.values.map(AppManifest.fromJsonString).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(list);
}
