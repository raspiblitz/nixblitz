import 'package:common/src/services/plugin/plugin_marker.dart';

/// Aggregate result from [PluginService.refreshAll]. The TUI walks
/// these three lists to render successes / warnings / skipped lines
/// in the bulk refresh log surface.
class PluginRefreshAllResult {
  /// Plugins whose refresh advanced the pin to a newer rev.
  final List<PluginMarker> advanced;

  /// Plugins whose refresh found the pin already at upstream HEAD —
  /// no files written, working tree clean. Distinguishing these from
  /// [advanced] lets the CLI suppress the "Run Apply view" hint when
  /// nothing actually moved (the operator's `git diff` would be empty).
  final List<PluginMarker> unchanged;

  /// Plugins whose refresh threw. The error is whatever
  /// [PluginService.refresh] surfaces — typically [StateError] for
  /// network failures or malformed upstream output, or
  /// [PluginSignatureMismatch] when the publisher key changed.
  final List<({PluginMarker plugin, Object error})> failures;

  /// Plugins skipped because [PluginService.refreshAll] was called
  /// with `includePinned: false` and the plugin had
  /// `autoUpdate == false`.
  final List<PluginMarker> skipped;

  const PluginRefreshAllResult({
    required this.advanced,
    required this.unchanged,
    required this.failures,
    required this.skipped,
  });

  bool get hasAnyFailure => failures.isNotEmpty;
  int get totalAttempted =>
      advanced.length + unchanged.length + failures.length;
}
