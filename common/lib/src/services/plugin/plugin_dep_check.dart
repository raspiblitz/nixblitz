import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';

/// Result of checking a single plugin's `requires` block (Phase 4).
///
/// Sealed so callers can `switch (status)` exhaustively over the
/// two outcomes — `ok` for a satisfied plugin, [DepMissing] with a
/// non-empty list of unmet deps otherwise.
sealed class DepStatus {
  const DepStatus();

  /// Singleton "all deps satisfied" sentinel. Compare with `same()` /
  /// `identical()` rather than `isA<_DepOk>()` so we don't leak the
  /// private subtype name into test code.
  static const DepStatus ok = _DepOk();
}

final class _DepOk extends DepStatus {
  const _DepOk();

  @override
  String toString() => 'DepStatus.ok';
}

/// One or more deps were not satisfied. [missing] is the subset of
/// the plugin's `requires` list that failed resolution. Always
/// non-empty (an empty list would be reported as [DepStatus.ok]).
///
/// The list is unmodifiable — callers can hand it to UI code without
/// worrying about defensive copies.
final class DepMissing extends DepStatus {
  final List<PluginDep> missing;
  const DepMissing(this.missing);

  @override
  String toString() => 'DepMissing($missing)';
}

/// Resolves each plugin's `requires` block against the supplied
/// [config] and the URLs declared by the other plugins in [plugins].
///
/// - [AppDep] is satisfied iff `config.isAppEnabled(dep.id) == true`.
/// - [PluginUrlDep] is satisfied iff some other manifest in [plugins]
///   has a verbatim-matching `url`.
///
/// Returns one entry per input plugin keyed by `plugin.id`. The
/// value is [DepStatus.ok] if every dep resolved, otherwise a
/// [DepMissing] holding only the unmet deps. The output preserves
/// the input order via insertion order on the returned `Map`.
Map<String, DepStatus> checkPluginDeps(
  List<PluginManifest> plugins,
  NixblitzConfig config,
) {
  // Self-references resolve trivially: the current plugin's own url is in
  // `installedUrls`, so a plugin that lists its own url in `requires`
  // satisfies itself. Plugin authors shouldn't write that, but doing so
  // doesn't break anything.
  final installedUrls = plugins.map((p) => p.url).whereType<String>().toSet();

  final result = <String, DepStatus>{};
  for (final plugin in plugins) {
    final missing = <PluginDep>[];
    for (final dep in plugin.requires) {
      switch (dep) {
        case AppDep(:final id):
          if (!config.isAppEnabled(id)) missing.add(dep);
        case PluginUrlDep(:final url):
          if (!installedUrls.contains(url)) missing.add(dep);
      }
    }
    result[plugin.id] = missing.isEmpty
        ? DepStatus.ok
        : DepMissing(List.unmodifiable(missing));
  }
  return result;
}
