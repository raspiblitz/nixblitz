import 'dart:io';

/// Number of lines the _Shell reserves for header + footer + padding.
/// Approximation based on the Shell layout:
/// - 2 lines: outer padding (top + bottom)
/// - 3 lines: header (container with vertical padding + border)
/// - 1 line: SizedBox between header and content
/// - 1 line: Divider
/// - 1 line: footer text
const int _shellReservedLines = 8;

/// Lines reserved by a view's own header (title + step label + spacing).
const int _defaultViewHeaderLines = 5;

/// Calculate how many log lines can be shown without pushing the shell
/// footer off-screen. Falls back to a conservative 20 if terminal size
/// is not available.
int maxVisibleLogLines({int viewHeaderLines = _defaultViewHeaderLines}) {
  try {
    final height = stdout.terminalLines;
    final available = height - _shellReservedLines - viewHeaderLines;
    return available > 5 ? available : 5;
  } catch (_) {
    return 20;
  }
}
import 'dart:io';

/// Number of lines the _Shell reserves for header + footer + padding.
/// Approximation based on the Shell layout:
/// - 2 lines: outer padding (top + bottom)
/// - 3 lines: header (container with vertical padding + border)
/// - 1 line: SizedBox between header and content
/// - 1 line: Divider
/// - 1 line: footer text
const int _shellReservedLines = 8;

/// Lines reserved by a view's own header (title + step label + spacing).
const int _defaultViewHeaderLines = 5;

/// Calculate how many log lines can be shown without pushing the shell
/// footer off-screen. Falls back to a conservative 20 if terminal size
/// is not available.
int maxVisibleLogLines({int viewHeaderLines = _defaultViewHeaderLines}) {
  try {
    final height = stdout.terminalLines;
    final available = height - _shellReservedLines - viewHeaderLines;
    return available > 5 ? available : 5;
  } catch (_) {
    return 20;
  }
}

/// Truncate a line to fit in the current terminal width on a single row.
/// Accounts for 4 chars of horizontal padding (EdgeInsets.all(2) ≈ 2 on
/// each side).
String truncateLine(String line, {int horizontalPadding = 4}) {
  try {
    final width = stdout.terminalColumns - horizontalPadding;
    if (line.length <= width) return line;
    if (width <= 3) return line.substring(0, width.clamp(0, line.length));
    return '${line.substring(0, width - 3)}...';
  } catch (_) {
    // Fallback: truncate to 120 chars
    if (line.length <= 120) return line;
    return '${line.substring(0, 117)}...';
  }
}
