import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

import 'spinner.dart';

const _accent = Color.fromRGB(247, 147, 26);
const _dim = TextStyle(color: Color.fromRGB(150, 150, 180));

/// Source-agnostic build/install progress panel: title, phase label, a
/// copy progress bar (when a fraction is known) or a spinner, elapsed
/// time, a tail of recent log lines, and a `[l] full log` hint.
///
/// Named `Build…` rather than `Install…` so it can be reused by other
/// sources (e.g. an internal-json rebuild screen) later. Pure rendering
/// — no timers, no IO; the caller drives `progress`/`elapsedSeconds`/
/// `recentLines`.
class BuildProgressPanel extends StatelessComponent {
  const BuildProgressPanel({
    super.key,
    required this.progress,
    required this.elapsedSeconds,
    required this.recentLines,
    this.title = 'Installing NixBlitz',
    this.tailCount = 6,
    this.barWidth = 24,
  });

  final InstallProgress progress;
  final int elapsedSeconds;
  final List<String> recentLines;
  final String title;
  final int tailCount;
  final int barWidth;

  /// Formats seconds as `MmSs` (elides the minutes segment below 60s).
  static String formatElapsed(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return minutes > 0 ? '${minutes}m${secs}s' : '${secs}s';
  }

  @override
  Component build(BuildContext context) {
    final fraction = progress.copyFraction;
    final tail = recentLines.length <= tailCount
        ? recentLines
        : recentLines.sublist(recentLines.length - tailCount);

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: _accent, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 1),
          if (fraction != null)
            Row(
              children: [
                Text(phaseLabel(progress.phase)),
                const SizedBox(width: 2),
                SizedBox(
                  width: barWidth.toDouble(),
                  height: 1,
                  child: ProgressBar(
                    value: fraction.clamp(0.0, 1.0),
                    showPercentage: true,
                    fillCharacter: '█',
                    emptyCharacter: '░',
                    valueColor: _accent,
                  ),
                ),
                const SizedBox(width: 2),
                Text(formatElapsed(elapsedSeconds), style: _dim),
              ],
            )
          else
            Row(
              children: [
                Spinner(label: phaseLabel(progress.phase)),
                Text('   ${formatElapsed(elapsedSeconds)}', style: _dim),
              ],
            ),
          const SizedBox(height: 1),
          for (final line in tail) Text(line, style: _dim),
          const SizedBox(height: 1),
          const Text('[l] full log', style: _dim),
        ],
      ),
    );
  }
}
