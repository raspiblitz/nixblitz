import 'package:riverpod/riverpod.dart';

import 'package:common/src/services/configure/app_manifest_registry.dart';
import 'package:common/src/services/configure/bundled/registry.dart';

/// Combined bundled + plugin app manifests.
/// Plugin manifests come from installed plugins that declare a
/// config_schema (Task 5 wires this up). For Phase 3's initial commit,
/// the plugin list is empty; Task 5 populates it.
final appManifestRegistryProvider = Provider<AppManifestRegistry>((ref) {
  return AppManifestRegistry(bundled: bundledAppManifests, plugin: const []);
});
