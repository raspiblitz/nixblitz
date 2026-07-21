import 'package:nocterm/nocterm.dart';

/// Shared chrome for the TUI's inline popups / modals: an accent
/// border, the unified dark surface, and default padding. Every popup
/// wraps its content in this so the look stays consistent and a new
/// popup can't silently drift a color the way `select_popup` /
/// `branch_picker` did (see issue #37). Callers still own positioning
/// (`Center` / `Stack`) — this only owns the box.
class PopupChrome extends StatelessComponent {
  const PopupChrome({super.key, required this.child, this.padding, this.width});

  final Component child;

  /// Inner padding. Defaults to a tight `horizontal: 1` (the list
  /// pickers); wider text modals pass `symmetric(horizontal: 2,
  /// vertical: 1)`.
  final EdgeInsets? padding;

  /// Optional fixed width. Centered text modals set this (so they
  /// shrink to fit narrow terminals); list pickers size to content
  /// and leave it null.
  final double? width;

  @override
  Component build(BuildContext context) {
    return Container(
      width: width,
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        border: BoxBorder.all(color: kPopupAccent),
        color: kPopupSurface,
      ),
      child: child,
    );
  }
}

// Unified popup palette. Popups pull row/element colors from these so
// the whole overlay layer stays coherent; a new popup should reach for
// these instead of re-declaring literals.

/// Bitcoin orange — the border, titles, and selected-row highlight.
const kPopupAccent = Color.fromRGB(247, 147, 26);

/// The majority dark surface (`#181824`). `select_popup` and
/// `branch_picker` had drifted to a bluer `#242436`; this is the value
/// they unify back to.
const kPopupSurface = Color.fromRGB(24, 24, 36);

/// Primary body text inside a popup.
const kPopupBody = Color.fromRGB(200, 200, 200);

/// Dim hint / footer text (the `↑/↓ select  Enter confirm` line, etc.).
const kPopupDim = Color.fromRGB(120, 120, 140);

/// Text drawn on top of an accent-highlighted (selected) row.
const kPopupSelectedFg = Color.fromRGB(0, 0, 0);
