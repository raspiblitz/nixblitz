import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/plugin/plugin_dep_check.dart';

/// Per-plugin dep status, keyed by `plugin.id`.
///
/// Reactively re-derives when `configProvider` updates. Returns an
/// empty map while the config is still loading or has errored, so
/// downstream UI code can treat "no entries" as "no plugins to
/// check" without special-casing the loading state.
///
/// Currently feeds `const []` for the plugin list — Task 8 will wire
/// in `installedPluginsProvider` so this provider operates on the
/// real installed-plugin set. Until then the empty input is a no-op
/// (the result map stays empty), which is fine: there are no plugins
/// to gate.
final pluginDepCheckProvider = Provider<Map<String, DepStatus>>((ref) {
  final configAsync = ref.watch(configProvider);
  final config = configAsync.value;
  if (config == null) return const {};
  // TODO(Task 8): final plugins = ref.watch(installedPluginsProvider);
  return checkPluginDeps(const [], config);
});
