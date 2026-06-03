part 'embedded_templates.g.dart';

/// Provides all NixOS template files embedded as string constants.
/// Generated from templates/ by scripts/gen_embedded_templates.dart.
class EmbeddedTemplates {
  EmbeddedTemplates._();

  /// Returns a map of relative path → file content for every template file.
  static Map<String, String> getAll() => _getAllTemplates();

  /// Raw JSON content of the repo-root `branches.json`, embedded at
  /// build time. nixblitz's own branch manifest — the TUI parses
  /// this once via `nixblitzBranchManifestProvider`.
  static String get nixblitzBranchesJson => _nixblitzBranchesJson;
}
