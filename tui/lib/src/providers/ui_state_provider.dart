import 'package:common/common.dart';
import 'package:riverpod/legacy.dart';

enum AppView {
  install,
  setup,
  dashboard,
  configure,
  apply,
  update,
  debug,
  configTooNew,
}

final currentViewProvider = StateProvider<AppView>((ref) => AppView.dashboard);
final selectedServiceIndexProvider = StateProvider<int>((ref) => 0);

/// Templates drift state at TUI launch — populated by an
/// override in [NixBlitzApp]'s ProviderScope so the dashboard
/// can show a banner + offer a refresh action when the binary's
/// embedded templates differ from the operator's on-disk copy.
///
/// Computed once at launch (cheap — diffs ~20 short string
/// blobs) rather than reactively because the underlying state
/// only changes when the operator either (a) updates the binary
/// or (b) hand-edits a template file. Both are out-of-process
/// events; rechecking on every dashboard rebuild would be wasted
/// work. The dashboard's [r] refresh action triggers a manual
/// reset of this provider after the refresh runs.
final templatesDriftProvider = StateProvider<TemplatesDrift>(
  (ref) => TemplatesDrift.inSync,
);
