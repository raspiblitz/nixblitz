import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

/// Shared UI bits for the Apply and Update "done" screens. Lets both
/// views branch identically on [RebuildResult] so users see the same
/// language whether they came from Configure → Apply or Update.

Component rebuildHeadline(RebuildResult result, String action) {
  final (text, color) = switch (result.outcome) {
    RebuildOutcome.success => (
      '$action Complete',
      const Color.fromRGB(110, 220, 110),
    ),
    RebuildOutcome.partial => (
      '$action applied with warnings',
      const Color.fromRGB(220, 180, 100),
    ),
    RebuildOutcome.failure => (
      '$action Failed',
      const Color.fromRGB(255, 80, 80),
    ),
  };
  return Text(
    text,
    style: TextStyle(color: color, fontWeight: FontWeight.bold),
  );
}

Component rebuildFailedUnitsBanner(List<String> units) {
  if (units.isEmpty) return const SizedBox(height: 0);
  return Container(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The new config is active, but ${units.length} '
          '${units.length == 1 ? 'unit' : 'units'} failed to start:',
          style: const TextStyle(color: Color.fromRGB(220, 180, 100)),
        ),
        ...units.map(
          (u) => Text(
            '  • $u',
            style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
          ),
        ),
        const SizedBox(height: 1),
        Text(
          'Investigate: `systemctl status ${units.first}` '
          '| `journalctl -u ${units.first} -e`',
          style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      ],
    ),
  );
}
