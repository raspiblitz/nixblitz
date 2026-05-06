/// Validation failure for the Phase 4 plugin manifest extensions
/// (`requires`, `module`, `streamers`). Distinct from the manifest's
/// existing [FormatException]-based validation so the install flow
/// can surface schema-extension errors with a more specific banner.
class PluginManifestError implements Exception {
  final String message;

  const PluginManifestError(this.message);

  @override
  String toString() => 'PluginManifestError: $message';
}
