import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/services/log_service.dart';

/// A teardown to run on the live system before a rebuild removes a
/// plugin: the plugin's id plus the resolved action it declared via
/// `manifest.teardown`.
class PluginTeardown {
  final String pluginId;
  final PluginAction action;

  const PluginTeardown({required this.pluginId, required this.action});
}

/// Parse a `plugins.list` file body into ids: one per line, trimmed,
/// blanks dropped. Tolerates null (file absent / not in HEAD).
List<String> parsePluginsList(String? raw) => (raw ?? '')
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .toList();

/// Ids present in [committed] (HEAD's `plugins.list`) but absent from
/// [current] (the on-disk one) — i.e. plugins being removed by the
/// rebuild this Apply will run. Covers both disable and uninstall.
Set<String> removedPluginIds({
  required List<String> committed,
  required List<String> current,
}) {
  final cur = current.toSet();
  return committed.where((id) => !cur.contains(id)).toSet();
}

/// Ids `enabled` in the committed config but not in the current one — the
/// operator's per-plugin disable edge (the Configure `enabled` toggle going
/// true→false). Null-safe: either config null → empty (fail safe, no spurious
/// teardowns). Pairs with [removedPluginIds] (the uninstall edge); the
/// pre-rebuild step tears down the union.
Set<String> disabledPluginIds({
  required NixblitzConfig? committed,
  required NixblitzConfig? current,
}) {
  if (committed == null || current == null) return {};
  final out = <String>{};
  for (final id in committed.appConfigs.keys) {
    if (committed.isAppEnabled(id) && !current.isAppEnabled(id)) {
      out.add(id);
    }
  }
  return out;
}

/// For each removed id, fetch its manifest text via [readManifest] (which
/// reads from the committed git tree — the on-disk copy may already be gone
/// because `PluginService.remove()` hard-deletes the plugin dir) and, if it
/// declares a `teardown`, resolve the named action. Best-effort: a plugin whose
/// committed manifest is absent/empty, fails to parse, declares no teardown, or
/// names a missing action is skipped (logged), not raised. The returned list is
/// ordered by id for deterministic execution.
Future<List<PluginTeardown>> resolveTeardowns({
  required Set<String> removedIds,
  required Future<String?> Function(String pluginId) readManifest,
}) async {
  final out = <PluginTeardown>[];
  for (final id in removedIds.toList()..sort()) {
    String? raw;
    try {
      raw = await readManifest(id);
    } catch (e, st) {
      LogService.error('teardown: reading manifest for `$id` failed', e, st);
      continue;
    }
    if (raw == null || raw.trim().isEmpty) {
      LogService.warn(
        'teardown: no committed manifest for removed plugin `$id` — skipped',
      );
      continue;
    }
    try {
      final manifest = PluginManifest.fromJsonString(raw);
      final teardownId = manifest.teardown;
      if (teardownId == null) continue;
      final action = manifest.actions[teardownId];
      if (action == null) {
        LogService.warn(
          'teardown: `$id` names teardown `$teardownId` with no '
          'matching action — skipped',
        );
        continue;
      }
      out.add(PluginTeardown(pluginId: id, action: action));
    } catch (e, st) {
      LogService.error('teardown: resolving `$id` failed', e, st);
    }
  }
  return out;
}
