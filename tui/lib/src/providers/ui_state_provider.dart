import 'package:common/common.dart';
import 'package:riverpod/legacy.dart';
import 'package:riverpod/riverpod.dart';

enum AppView {
  install,
  setup,
  dashboard,
  configure,

  /// Combined "what nixos-rebuild can do" view — sidebar splits
  /// read-only checks from destructive applies. Replaces the
  /// older standalone Apply / Update tabs.
  system,

  /// Kept reachable from [system]'s "Apply pending changes" action
  /// until the rebuild-streaming + done-screen state machine is
  /// folded directly into [SystemView]. Not surfaced in the top
  /// menu.
  apply,

  /// Same story as [apply]: still routable from [system] for the
  /// update / refresh actions; not in the top menu anymore.
  update,

  /// Full-screen viewer for the cached `nvd diff` from the last
  /// heavy check. Reached from `system → Check → View package diff`;
  /// Esc routes back to [system]. Not in the top menu; transient.
  packageDiff,
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

/// True while the help popup is visible (toggled by `?`). Lives in
/// the shared provider file so widgets like [ScrollableLog] can read
/// it without circular imports back to `app.dart`.
final helpVisibleProvider = StateProvider<bool>((ref) => false);

/// True while any modal popup is on top of the view tree (help or
/// sudo prompt). Widgets that hold an interactive [Focusable] should
/// set `focused: !modalActive` so a stray keystroke can't bubble
/// into the underlying view while a modal is up — independent of
/// nocterm's BlockFocus dispatch behavior.
final modalActiveProvider = Provider<bool>((ref) {
  final help = ref.watch(helpVisibleProvider);
  final sudo = ref.watch(pendingSudoPromptProvider);
  return help || sudo != null;
});
