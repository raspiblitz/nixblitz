import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

import '../format.dart';
import 'scrollable_log.dart';

/// Full-screen viewer for the cached `nvd diff` written by the
/// heavy update check into `update-status.json`. Stateless on
/// purpose — the file is the source of truth, this widget just
/// renders it.
///
/// Reached from System → Check → "View package diff" as
/// `AppView.packageDiff`. Esc routes back to System.
class CachedPackageDiff extends StatelessComponent {
  /// Invoked when the operator presses `Esc` (or `q`). Hosts use
  /// this to return to wherever the viewer was opened from.
  final VoidCallback onClose;

  const CachedPackageDiff({super.key, required this.onClose});

  @override
  Component build(BuildContext context) {
    final status = readUpdateStatus();
    final result = status.checkResult;
    final ago = result != null ? humanizeAge(result.checkedAt) : 'unknown';

    // Two body shapes share the same viewer: a populated nvd diff
    // (substitute-only path) or a "would-build" list (compile-needed
    // path). diffText takes precedence so that, if both were ever
    // present, the operator still sees the more informative nvd
    // output.
    final compileNeeded =
        result != null &&
        result.diffText.trim().isEmpty &&
        result.compileNeeded;
    final String title;
    final List<String> lines;
    final Color? Function(String)? lineColor;
    if (compileNeeded) {
      title = 'Packages needing local compile — checked $ago';
      lines = [
        '${result.wouldBuild.length} derivation${result.wouldBuild.length == 1 ? "" : "s"} '
            'have no binary-cache substitute and would need to be built locally.',
        'Trigger the build via System → Apply when you have time — on a Pi 5',
        'a fresh rustc storm can take several hours.',
        '',
        ...result.wouldBuild,
      ];
      lineColor = null;
    } else {
      title = 'Cached package diff — checked $ago';
      lines = (result?.diffText ?? '').split('\n');
      lineColor = nvdLineColor;
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape ||
              event.logicalKey == LogicalKey.keyQ) {
            onClose();
            return true;
          }
          // Swallow the top-menu nav keys so a stray h/l doesn't
          // yank the operator into a different view mid-scroll.
          // (The inner ScrollableLog claims j/k + arrowUp/Down on
          // its own.)
          if (event.logicalKey == LogicalKey.keyH ||
              event.logicalKey == LogicalKey.keyL ||
              event.logicalKey == LogicalKey.arrowLeft ||
              event.logicalKey == LogicalKey.arrowRight) {
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('CachedPackageDiff key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: ScrollableLog(
                lines: lines,
                lineColor: lineColor,
                focused: true,
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              '[Esc] back   [↑/↓ j/k] scroll   [PgUp/PgDn] page',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-line colour for `nvd diff` output. Public so the Apply view's
/// review / done screens (which also render nvd output) share the
/// same palette without re-defining the regex tests.
///
/// Orange for version changes, green for additions, red for
/// removals, cyan for the closure-size summary, null elsewhere.
Color? nvdLineColor(String line) {
  if (line.startsWith('[U.') || line.startsWith('[U]')) {
    return const Color.fromRGB(247, 147, 26); // orange — updated
  }
  if (line.startsWith('[A.') || line.startsWith('[A]')) {
    return const Color.fromRGB(110, 220, 110); // green — added
  }
  if (line.startsWith('[R.') || line.startsWith('[R]')) {
    return const Color.fromRGB(255, 120, 120); // red — removed
  }
  if (line.startsWith('Closure size')) {
    return const Color.fromRGB(120, 200, 220); // cyan — summary
  }
  return null;
}
