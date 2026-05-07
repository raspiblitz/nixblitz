import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:common/src/services/plugin/plugin_dep_check.dart';

/// Per-plugin dep status, keyed by `plugin.id`.
///
/// Reactively re-derives when `configProvider` or
/// [installedPluginsProvider] update. Returns an empty map while the
/// config is still loading or has errored, so downstream UI code can
/// treat "no entries" as "no plugins to check" without special-casing
/// the loading state.
final pluginDepCheckProvider = Provider<Map<String, DepStatus>>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  final plugins = ref.watch(installedPluginsProvider);
  if (config == null) return const {};
  return checkPluginDeps(plugins, config);
});
