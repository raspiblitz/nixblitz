/// Shared sidebar geometry for the Configure and System views.
///
/// Both views render a left-column section picker; using a single
/// width keeps the right pane from jumping horizontally when the
/// operator switches between top-menu entries.
///
/// Cell budget (24 total):
///   1 left border + 2 left padding + 2 cursor prefix +
///   16 label area + 2 right padding + 1 right border.
///
/// 16 chars of label area fits every currently-shipped label
/// (`Lightning (LND)` is 15) with one cell to spare. Anything
/// longer is truncated by [truncateSidebarLabel].
const int kSidebarWidth = 24;

/// Usable label area after subtracting border, padding, and the
/// `> ` cursor prefix.
const int _kSidebarLabelArea = kSidebarWidth - 8;

/// Truncate [label] to the sidebar's usable label area, appending
/// `…` when content was dropped. Pure function so callers don't
/// need to know the cell-budget arithmetic.
String truncateSidebarLabel(String label) {
  if (label.length <= _kSidebarLabelArea) return label;
  return '${label.substring(0, _kSidebarLabelArea - 1)}…';
}
