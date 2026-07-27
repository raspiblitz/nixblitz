import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

import 'spinner.dart';

/// Pure row model so glyph/label logic is testable without nocterm.
class SeedWaitRow {
  final String glyph;
  final String label;
  final bool isCurrent;
  final bool isFailed;

  const SeedWaitRow({
    required this.glyph,
    required this.label,
    this.isCurrent = false,
    this.isFailed = false,
  });
}

const _labels = [
  'LND service started',
  'Waiting for LND to create the wallet seed',
  'Read seed file (needs sudo)',
];

/// Maps a [SeedWaitStatus] to the three checklist rows. The current
/// row's glyph is '⠿' — a placeholder the widget swaps for a live
/// [Spinner]; tests assert on the placeholder.
List<SeedWaitRow> seedWaitChecklistRows(SeedWaitStatus status) {
  final currentIdx = switch (status.phase) {
    SeedWaitPhase.startingService => 0,
    SeedWaitPhase.waitingForSeedFile => 1,
    SeedWaitPhase.readingSeed => 2,
    SeedWaitPhase.done => 3, // past the end: everything ✓
  };
  final failed = status.error != null;
  return List.generate(3, (i) {
    if (i < currentIdx) {
      return SeedWaitRow(glyph: '✓', label: _labels[i]);
    }
    if (i == currentIdx) {
      return SeedWaitRow(
        glyph: failed ? '✗' : '⠿',
        label: _labels[i],
        isCurrent: !failed,
        isFailed: failed,
      );
    }
    return SeedWaitRow(glyph: '○', label: _labels[i]);
  });
}

class SeedWaitChecklist extends StatelessComponent {
  const SeedWaitChecklist({required this.status});

  final SeedWaitStatus status;

  @override
  Component build(BuildContext context) {
    final rows = seedWaitChecklistRows(status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Lightning Wallet Setup',
          style: const TextStyle(
            color: Color.fromRGB(247, 147, 26),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 1),
        for (final row in rows)
          if (row.isCurrent)
            Spinner(label: row.label)
          else
            Text(
              '${row.glyph} ${row.label}',
              style: TextStyle(
                color: row.isFailed
                    ? const Color.fromRGB(255, 80, 80)
                    : row.glyph == '✓'
                    ? const Color.fromRGB(80, 220, 120)
                    : const Color.fromRGB(120, 120, 140),
              ),
            ),
        const SizedBox(height: 1),
        if (status.phase != SeedWaitPhase.startingService ||
            status.error != null)
          const Text(
            'Reading the seed requires root — a sudo prompt may appear.',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        if (status.error != null) ...[
          const SizedBox(height: 1),
          Text(
            status.error!,
            style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
          ),
        ],
        const SizedBox(height: 1),
        const Text(
          '[o] show LND log',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      ],
    );
  }
}
