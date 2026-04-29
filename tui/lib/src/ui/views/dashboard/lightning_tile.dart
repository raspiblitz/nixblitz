import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../widgets/tile.dart';
import 'format.dart';

class LightningTile extends StatelessComponent {
  const LightningTile({super.key});

  static const _accent = Color.fromRGB(200, 140, 220);

  @override
  Component build(BuildContext context) {
    final snap = context.watch(lnSnapshotProvider);
    final config = context.watch(configProvider).value;

    // If neither LN is configured, render a tidy "disabled" tile
    // instead of a misleading "loading…".
    final lnOn =
        (config?.lnd.enabled ?? false) || (config?.cln.enabled ?? false);
    if (!lnOn) {
      return const Tile(
        title: 'Lightning',
        accent: _accent,
        footer: 'disabled',
        footerColor: Color.fromRGB(150, 150, 180),
      );
    }

    return snap.when(
      loading: () => const Tile(
        title: 'Lightning',
        accent: _accent,
        rows: [TileRow('status', 'waiting for event…')],
      ),
      error: (e, _) => const Tile(
        title: 'Lightning',
        accent: _accent,
        footer: 'unreachable',
      ),
      data: (s) {
        if (s == null) {
          return const Tile(
            title: 'Lightning',
            accent: _accent,
            footer: 'unavailable — blitz-api is off',
          );
        }
        final pk = s.pubkey.isEmpty ? '?' : '${s.pubkey.substring(0, 10)}…';
        return Tile(
          title: 'Lightning',
          accent: _accent,
          statusLabel: s.impl.toUpperCase(),
          rows: [
            TileRow('alias', s.alias.isEmpty ? '(none)' : s.alias),
            TileRow('pubkey', pk),
            TileRow(
              'synced',
              s.syncedToChain ? 'yes' : 'no',
              valueColor: s.syncedToChain
                  ? const Color.fromRGB(110, 220, 110)
                  : const Color.fromRGB(220, 180, 100),
            ),
            TileRow('peers', '${s.numPeers}'),
            TileRow(
              'channels',
              '${s.numActiveChannels} active'
                  '${s.numPendingChannels > 0 ? ' + ${s.numPendingChannels} pending' : ''}',
            ),
            TileRow('on-chain', '${humanSats(s.onChainSats)} sat'),
            TileRow('channel', '${humanSats(s.channelSats)} sat'),
          ],
        );
      },
    );
  }
}
