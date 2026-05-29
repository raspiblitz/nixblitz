import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:common/src/services/plugin/plugin_app_version_service.dart';

/// Resolves each installed plugin's app version on demand by running
/// its declared `app_version` command (in parallel). Riverpod caches
/// the result until the installed-plugin set changes, so the commands
/// don't re-run on every rebuild.
///
/// Per plugin, the resolved string is:
/// - the command's output on success,
/// - `"unavailable"` when a declared command fails / times out,
/// - the plugin's own version when there's no command (the cachepop
///   fallback), or `"—"` when the plugin is also unversioned.
final pluginAppVersionsProvider = FutureProvider<Map<String, String>>((
  ref,
) async {
  final baseDir = ref.watch(baseDirProvider);
  final plugins = ref.watch(installedPluginsProvider);
  final out = <String, String>{};
  await Future.wait(
    plugins.map((m) async {
      final fallback = (m.version == null || m.version!.isEmpty)
          ? '—'
          : m.version!;
      final cmd = m.appVersionCommand;
      if (cmd == null) {
        out[m.id] = fallback;
        return;
      }
      final v = await readPluginAppVersion(
        baseDir: baseDir,
        pluginId: m.id,
        cmd: cmd,
      );
      out[m.id] = v ?? 'unavailable';
    }),
  );
  return out;
});
