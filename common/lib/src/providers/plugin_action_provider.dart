import 'package:riverpod/riverpod.dart';

import 'package:common/src/services/plugin_action_runner.dart';

/// Stateless runner — one instance is enough for the whole app.
final pluginActionRunnerProvider = Provider<PluginActionRunner>((ref) {
  return PluginActionRunner();
});
