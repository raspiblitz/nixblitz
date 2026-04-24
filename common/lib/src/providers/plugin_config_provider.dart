import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';

import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/git_provider.dart';
import 'package:common/src/providers/plugin_provider.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin_config_service.dart';
import 'package:common/src/services/plugin_service.dart';

final pluginConfigServiceProvider = Provider<PluginConfigService>((ref) {
  return PluginConfigService(baseDir: ref.watch(baseDirProvider));
});

/// Per-plugin config state, keyed by the plugin's on-disk dir name.
/// Mirrors the immediate-persist convention used by the main
/// `configProvider` (see `common/lib/src/providers/config_provider.dart`).
///
/// A separate notifier instance per [dirName] lets the Configure view
/// watch the one plugin the user is editing without churning unrelated
/// forms.
final pluginConfigProvider = StateNotifierProvider.family<
    PluginConfigNotifier, AsyncValue<Map<String, dynamic>>, String>(
  (ref, dirName) {
    return PluginConfigNotifier(
      ref: ref,
      configService: ref.watch(pluginConfigServiceProvider),
      pluginService: ref.watch(pluginServiceProvider),
      dirName: dirName,
    );
  },
);

class PluginConfigNotifier
    extends StateNotifier<AsyncValue<Map<String, dynamic>>> {
  final Ref _ref;
  final PluginConfigService _configService;
  final PluginService _pluginService;
  final String _dirName;

  PluginConfigNotifier({
    required Ref ref,
    required PluginConfigService configService,
    required PluginService pluginService,
    required String dirName,
  })  : _ref = ref,
        _configService = configService,
        _pluginService = pluginService,
        _dirName = dirName,
        super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      state = AsyncValue.data(_configService.read(_dirName));
    } catch (e, st) {
      LogService.error(
        'Failed to load plugin config for $_dirName',
        e,
        st,
      );
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> reload() async => _load();

  /// Update a single field, validating against the plugin's manifest
  /// before persisting. Throws [StateError] if the key isn't declared
  /// in the manifest, and [FormatException] if the value doesn't
  /// match the declared type.
  Future<void> updateField(String key, dynamic value) async {
    final current = state.value ?? const <String, dynamic>{};
    final manifest = _pluginService.readManifest(_dirName);
    final spec = manifest.config[key];
    if (spec == null) {
      throw StateError(
        'Plugin `$_dirName` has no config field `$key`.',
      );
    }
    final err = spec.validate(value);
    if (err != null) {
      throw FormatException(
        'Invalid value for `$key` (${spec.type}): $err',
      );
    }
    final next = <String, dynamic>{...current, key: value};
    await _configService.write(_dirName, next);
    state = AsyncValue.data(next);

    // Dashboard + footer watch `pendingChangesProvider` (a `git
    // status` wrapper) to show the Apply hint and banner. That
    // provider only re-runs when `configProvider` emits, which
    // never happens for plugin edits. Invalidate it here so the
    // UI reflects the new dirty file immediately.
    _ref.invalidate(pendingChangesProvider);
  }

  /// Load the plugin's manifest once. Cheap — callers typically want
  /// to iterate `manifest.config` to render a form.
  PluginManifest manifest() => _pluginService.readManifest(_dirName);
}
