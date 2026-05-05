library;

part 'embedded_manifests.g.dart';

/// Provides all bundled tile manifest JSON files embedded as string constants.
/// Generated from bundled/manifests/ by scripts/gen_dashboard_manifests.dart.
class EmbeddedManifests {
  EmbeddedManifests._();

  /// All manifests as raw JSON strings, keyed by manifest name (filename
  /// without extension).
  static Map<String, String> getAll() => Map.unmodifiable(_allManifests);
}
