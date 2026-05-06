library;

part 'embedded_schemas.g.dart';

/// Provides all bundled app manifest JSON files embedded as string constants.
/// Generated from bundled/manifests/ by scripts/gen_app_config_schemas.dart.
class EmbeddedAppSchemas {
  EmbeddedAppSchemas._();

  /// All app manifests as raw JSON strings, keyed by manifest name (filename
  /// without extension).
  static Map<String, String> getAll() => Map.unmodifiable(_allAppSchemas);
}
