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

  /// Reached from [system]'s "Apply pending changes" action. Hosts
  /// the review + rebuild-streaming + done state machine for every
  /// mutating operation — the only path that touches a generation.
  /// Not surfaced in the top menu.
  apply,

  /// Full-screen viewer for the cached `nvd diff` from the last
  /// check. Reached from `system → Check → View package diff`;
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

/// Compact-mode hamburger overlay (top menu's `☰` glyph). True =
/// overlay is showing, view focus yielded. Lives here rather than
/// alongside the TopMenu widget so [modalActiveProvider] can read
/// it without circular imports.
final topMenuOverlayProvider = StateProvider<bool>((ref) => false);

/// Payload for the "Apply now?" popup. Set by action-completion
/// sites (plugin install done, leaving Configure with pending
/// edits); null means no popup. See
/// docs/superpowers/specs/2026-05-19-apply-now-prompt-design.md.
class ApplyNowPrompt {
  const ApplyNowPrompt({this.headline});

  /// Optional one-line summary of what just happened, e.g.
  /// "configured blitz-api v0.1.0". Null → the popup shows only the
  /// generic pending-change count (the Configure-exit case).
  final String? headline;
}

/// Drives the "Apply now?" popup; non-null while the popup is up.
final applyNowPromptProvider = StateProvider<ApplyNowPrompt?>((ref) => null);

/// True while any modal popup is on top of the view tree (help,
/// sudo prompt, hamburger overlay, apply-now prompt). Widgets that hold an interactive
/// [Focusable] should set `focused: !modalActive` so a stray
/// keystroke can't bubble into the underlying view while a modal is
/// up — independent of nocterm's BlockFocus dispatch behavior.
final modalActiveProvider = Provider<bool>((ref) {
  final help = ref.watch(helpVisibleProvider);
  final sudo = ref.watch(pendingSudoPromptProvider);
  final topMenu = ref.watch(topMenuOverlayProvider);
  final applyNow = ref.watch(applyNowPromptProvider);
  return help || sudo != null || topMenu || applyNow != null;
});

/// View-declared "I'm in a non-resumable rebuild flow" flag. Apply
/// flips this on when it enters the post-commit / rebuild-running
/// window and clears it when it reaches a terminal state (done,
/// fail, reset to review). The shell consumes it to gate the `q`
/// quit shortcut behind a two-press confirm — an operator
/// fat-fingering `q` instead of `a` during an Apply must not nuke
/// a half-finished rebuild silently.
final viewBusyProvider = StateProvider<bool>((ref) => false);

/// Composed signal: any view declares itself busy, or a sudo prompt
/// is up. Read by the shell's `q` handler.
final inflightOperationProvider = Provider<bool>((ref) {
  final viewBusy = ref.watch(viewBusyProvider);
  final sudo = ref.watch(pendingSudoPromptProvider);
  return viewBusy || sudo != null;
});

/// First press of `q` during an in-flight op flips this true. Within
/// a short window (3s) a second press actually quits; after that the
/// flag clears so a stale arm doesn't snipe an unrelated `q`.
final quitArmedProvider = StateProvider<bool>((ref) => false);
