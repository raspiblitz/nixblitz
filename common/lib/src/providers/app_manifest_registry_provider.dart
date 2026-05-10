import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:common/src/services/configure/app_manifest_registry.dart';
import 'package:common/src/services/configure/bundled/registry.dart';

/// Combined bundled + plugin app manifests. Plugin schemas are
/// pulled from every installed plugin that declares a top-level
/// `config_schema` block in its plugin.json. Without this merge,
/// post-extraction plugins (bitcoind / lnd / cln / blitz-api / …)
/// wouldn't appear in [AppManifestRegistry.serviceIds()] and the
/// service-status polling that feeds the wizard's wait-bitcoind
/// step would have no `bitcoind.service` to probe.
final appManifestRegistryProvider = Provider<AppManifestRegistry>((ref) {
  final plugins = ref.watch(installedPluginsProvider);
  final pluginSchemas = <AppManifest>[
    for (final p in plugins)
      if (p.configSchema != null) p.configSchema!,
  ];
  return AppManifestRegistry(
    bundled: bundledAppManifests,
    plugin: pluginSchemas,
  );
});
