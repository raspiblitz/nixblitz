import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../widgets/tile.dart';
import 'format.dart';

class HardwareTile extends StatelessComponent {
  const HardwareTile({super.key});

  static const _accent = Color.fromRGB(120, 200, 220);

  @override
  Component build(BuildContext context) {
    final snap = context.watch(hardwareSnapshotProvider);
    return snap.when(
      loading: () => const Tile(
        title: 'Hardware',
        accent: _accent,
        rows: [TileRow('status', 'waiting for event…')],
      ),
      error: (e, _) =>
          const Tile(title: 'Hardware', accent: _accent, footer: 'unreachable'),
      data: (s) {
        if (s == null) {
          return const Tile(
            title: 'Hardware',
            accent: _accent,
            footer: 'unavailable — blitz-api is off',
          );
        }
        final memFrac = s.memTotalBytes == 0
            ? 0.0
            : s.memUsedBytes / s.memTotalBytes;
        final diskFrac = s.diskTotalBytes == 0
            ? 0.0
            : s.diskUsedBytes / s.diskTotalBytes;
        return Tile(
          title: 'Hardware',
          accent: _accent,
          rows: [
            TileRow('cpu', '${s.cpuPercent.toStringAsFixed(0)}%'),
            TileRow(
              'memory',
              '${humanBytes(s.memUsedBytes)} / '
                  '${humanBytes(s.memTotalBytes)} '
                  '(${humanPercent(memFrac)})',
            ),
            TileRow(
              'disk',
              '${humanBytes(s.diskUsedBytes)} / '
                  '${humanBytes(s.diskTotalBytes)} '
                  '(${humanPercent(diskFrac)})',
            ),
          ],
        );
      },
    );
  }
}
