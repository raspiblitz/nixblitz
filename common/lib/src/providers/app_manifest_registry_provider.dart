import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:common/src/services/configure/app_manifest_registry.dart';
import 'package:common/src/services/configure/bundled/registry.dart';

/// Combined bundled + plugin app manifests. Each installed plugin
/// contributes one [AppManifest] so it appears as a Configure sidebar
/// entry:
///
///  - A plugin with a top-level `config_schema` block contributes that
///    schema (its config fields + actions render under the entry). This
///    is also what puts post-extraction plugins (bitcoind / lnd / cln /
///    blitz-api / …) into [AppManifestRegistry.serviceIds()] so the
///    wizard's wait-bitcoind step has a `bitcoind.service` to probe.
///  - A logic-only plugin with actions but NO `config_schema` (e.g. a
///    sandboxed wasm plugin like node-summary) contributes a synthetic
///    fieldless manifest, so its actions are still reachable in the
///    sidebar. Without this, such a plugin installs but has no screen to
///    run its actions from.
final appManifestRegistryProvider = Provider<AppManifestRegistry>((ref) {
  final plugins = ref.watch(installedPluginsProvider);
  final pluginSchemas = <AppManifest>[
    for (final p in plugins)
      if (p.configSchema != null)
        p.configSchema!
      else if (p.actions.isNotEmpty)
        AppManifest(id: p.id, label: p.name, fields: const []),
  ];
  return AppManifestRegistry(
    bundled: bundledAppManifests,
    plugin: pluginSchemas,
  );
});
