import 'package:riverpod/riverpod.dart';

import 'package:common/src/services/configure/app_manifest_registry.dart';
import 'package:common/src/services/configure/bundled/registry.dart';

/// Combined bundled + plugin app manifests.
/// Plugin manifests come from installed plugins that declare a
/// config_schema (Task 5 wires this up).
///
/// Note: Phase 3 Task 5 keeps the plugin list empty since PluginService.list()
/// is async and the registry initializes synchronously. Phase 4-6 will add
/// an async version when needed. The key deliverable is the PluginManifest
/// model change (configSchema field), which enables plugin-shipped manifests
/// to declare UI schemas compatible with the Configure view's manifest-driven
/// rendering from Task 7.
final appManifestRegistryProvider = Provider<AppManifestRegistry>((ref) {
  return AppManifestRegistry(bundled: bundledAppManifests, plugin: const []);
});
