import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../widgets/tile.dart';
import 'format.dart';

class BitcoinTile extends StatelessComponent {
  const BitcoinTile({super.key});

  static const _accent = Color.fromRGB(247, 147, 26);

  @override
  Component build(BuildContext context) {
    final snap = context.watch(btcSnapshotProvider);

    // Show the configured network as subtitle even before data lands.
    final network = context.watch(configProvider).value?.bitcoind.network ?? '';

    return snap.when(
      loading: () => Tile(
        title: 'Bitcoin',
        accent: _accent,
        statusLabel: network,
        rows: const [TileRow('status', 'waiting for event…')],
      ),
      error: (e, _) => Tile(
        title: 'Bitcoin',
        accent: _accent,
        statusLabel: network,
        footer: 'unreachable',
      ),
      data: (s) {
        if (s == null) {
          return Tile(
            title: 'Bitcoin',
            accent: _accent,
            statusLabel: network,
            footer: 'unavailable — blitz-api is off',
          );
        }
        final synced = s.verificationProgress >= 0.9999;
        return Tile(
          title: 'Bitcoin',
          accent: _accent,
          statusLabel: synced ? 'synced' : humanPercent(s.verificationProgress),
          statusColor: synced
              ? const Color.fromRGB(110, 220, 110)
              : const Color.fromRGB(220, 180, 100),
          rows: [
            TileRow('blocks', '${s.blocks}'),
            if (s.headers != s.blocks)
              TileRow(
                'headers',
                '${s.headers}',
                valueColor: const Color.fromRGB(220, 180, 100),
              ),
            TileRow('peers', '${s.peers}'),
            TileRow('mempool', '${s.mempoolTxs} tx'),
            TileRow('disk', humanBytes(s.sizeOnDiskBytes)),
          ],
        );
      },
    );
  }
}
