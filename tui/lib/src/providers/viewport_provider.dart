import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';

/// Cell-grid dimensions of the terminal — width / height in
/// character cells. Single source of truth for layout decisions
/// downstream of the live SIGWINCH stream.
///
/// `_Shell` (`ui/app.dart`) pumps `TerminalBinding.instance.terminal.
/// size` into this provider once at mount and again on every resize
/// event from the backend. Defaults to 80×24 — the historical safe
/// minimum and what the wizard rendered on before this provider
/// existed.
class ViewportSize {
  const ViewportSize(this.width, this.height);
  final int width;
  final int height;

  ViewportSize copyWith({int? width, int? height}) =>
      ViewportSize(width ?? this.width, height ?? this.height);

  @override
  bool operator ==(Object other) =>
      other is ViewportSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// Coarse-grained "is this a phone or a desktop" classifier derived
/// from [viewportSizeProvider]. Views that change shape (sidebar +
/// content → single-pane, top-menu strip → cycler, etc.) watch this
/// instead of the raw size so the breakpoint lives in one place.
///
/// The 60-cell cutoff matches the inflection point where the
/// sidebar (`kSidebarWidth` = 24) + a usable content pane stops
/// fitting on the same row. Below 60 means phone-over-SSH in
/// landscape (~40-50) or portrait (~30-40); above 60 covers tablet
/// portrait (~80), desktop terminals, and the lifecycle wizards.
enum ViewportClass { compact, wide }

final viewportSizeProvider = StateProvider<ViewportSize>(
  (ref) => const ViewportSize(80, 24),
);

final viewportClassProvider = Provider<ViewportClass>((ref) {
  final s = ref.watch(viewportSizeProvider);
  return s.width < 60 ? ViewportClass.compact : ViewportClass.wide;
});

/// True when the terminal is "vertically short" — usable content
/// height is tight enough that verbose row descriptions push the
/// selected target off-screen even after scrolling helps.
///
/// Phone SSH clients with the on-screen keyboard up report ~10–12
/// rows total regardless of orientation; the 20-row cutoff catches
/// that while keeping standard desktop / tablet terminals showing
/// the full descriptions. Width is irrelevant here — a wide-but-
/// short terminal (long laptop session with terminal squeezed
/// vertically) gets the same compact-content treatment.
///
/// Orthogonal to [viewportClassProvider] on purpose: layout
/// decisions (sidebar+content → single-pane) gate on width;
/// content-verbosity decisions (drop descriptions / hints) gate
/// on height.
final viewportShortProvider = Provider<bool>((ref) {
  return ref.watch(viewportSizeProvider).height < 20;
});
