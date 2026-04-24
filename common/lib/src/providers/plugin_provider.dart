import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/plugin_service.dart';

/// PluginService keyed off the same baseDir as ConfigService. Phase
/// 1 has no TUI consumers yet; Phases 2-4 will `ref.watch` this and
/// surface plugin state in the Configure / Dashboard / Actions views.
final pluginServiceProvider = Provider<PluginService>((ref) {
  return PluginService(baseDir: ref.watch(baseDirProvider));
});
