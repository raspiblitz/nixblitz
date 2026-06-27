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

    // One combined body: lead with "Updated software" (which inputs /
    // plugins moved), then any packages that build on the node, then the
    // per-package nvd diff. Each section renders only when it has content.
    final lines = <String>[];

    final inputs = result?.inputsAhead ?? const <InputAhead>[];
    final plugins = result?.pluginsAhead ?? const <PluginAhead>[];
    if (inputs.isNotEmpty || plugins.isNotEmpty) {
      lines.add('Updated software');
      for (final i in inputs) {
        final name = i.name == kTuiInputName
            ? '${i.name} (the NixBlitz software)'
            : i.name;
        lines.add(
          '  $name  ${_short(i.currentRev)} → ${_short(i.upstreamRev)}',
        );
      }
      for (final p in plugins) {
        lines.add('  ${p.pluginId}  ${p.versionDelta}');
      }
      lines.add('');
    }

    if (result != null && result.wouldBuild.isNotEmpty) {
      final n = result.wouldBuild.length;
      lines.add('Builds on the node ($n)');
      lines.add(
        '  No binary-cache substitute — built locally on the next Apply. On a '
        'Pi 5 a fresh rustc storm can take hours.',
      );
      for (final d in result.wouldBuild) {
        lines.add('  $d');
      }
      lines.add('');
    }

    final diff = (result?.diffText ?? '').trim();
    if (diff.isNotEmpty) {
      lines.add('Package changes');
      lines.addAll(diff.split('\n'));
    }

    if (lines.isEmpty) {
      lines.add('Nothing staged from the last check.');
    }

    final title = "What's changing — checked $ago";
    final lineColor = nvdLineColor; // colours the [U]/[A]/[R]/Closure lines

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

/// 7-char short rev for display; passes through anything already short.
String _short(String rev) => rev.length > 7 ? rev.substring(0, 7) : rev;

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
