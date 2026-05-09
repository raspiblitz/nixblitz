import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../ui/views/dashboard/tile_layout.dart';
import '../../ui/widgets/tile.dart';
import '../dev_app.dart';

/// Static preview of the dashboard layout with hand-picked tile
/// content that mirrors the size distribution of a real installed
/// node (System: 6 rows, Hardware: 2, Bitcoin: 4, Lightning: 7,
/// Tailscale: 2). Lets us iterate on `tileRows` cross-axis +
/// gutter spacing without booting a full VM.
class DashboardDemoView extends StatelessComponent {
  const DashboardDemoView({super.key});

  static const _white = Color.fromRGB(220, 220, 220);
  static const _cyan = Color.fromRGB(120, 200, 220);
  static const _orange = Color.fromRGB(247, 147, 26);
  static const _purple = Color.fromRGB(200, 140, 220);
  static const _teal = Color.fromRGB(37, 150, 190);
  static const _ok = Color.fromRGB(110, 220, 110);

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            context.read(currentDevViewProvider.notifier).state = DevView.menu;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Dashboard demo key handler failed', e, st);
          return true;
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cols = columnsFor(constraints.maxWidth);
          final tiles = <SizedTile>[
            (
              widget: const Tile(
                title: 'nixblitz',
                accent: _white,
                statusLabel: 'x86 | regtest',
                rows: [
                  TileRow('network', 'regtest'),
                  TileRow('uptime', '21h 7m'),
                  TileRow('blitz-api', 'running', valueColor: _ok),
                  TileRow('blitz-web', 'stopped'),
                  TileRow('nginx', 'running', valueColor: _ok),
                  TileRow('redis', 'running', valueColor: _ok),
                ],
              ),
              height: 6 + 6,
            ),
            (
              widget: const Tile(
                title: 'memory / disk',
                accent: _cyan,
                rows: [
                  TileRow('memory', '1.1 GB / 7.8 GB (15%)'),
                  TileRow('disk', '93 GB / 147 GB (64%)'),
                ],
              ),
              height: 2 + 6,
            ),
            (
              widget: const Tile(
                title: 'Bitcoin',
                accent: _orange,
                statusLabel: '39%',
                rows: [
                  TileRow('blocks', '153'),
                  TileRow('peers', '0'),
                  TileRow('mempool', '0 tx'),
                  TileRow('disk', '46 KB'),
                ],
              ),
              height: 4 + 6,
            ),
            (
              widget: const Tile(
                title: 'Lightning',
                accent: _purple,
                statusLabel: 'LND_GRPC',
                rows: [
                  TileRow('alias', '0267a599c9def57bc8a7'),
                  TileRow('pubkey', '0267a599c9…'),
                  TileRow('synced', 'no'),
                  TileRow('peers', '0'),
                  TileRow('channels', '0 active'),
                  TileRow('on-chain', '98_995_882 sat'),
                  TileRow('channel', '895_530 sat'),
                ],
              ),
              height: 7 + 6,
            ),
            (
              widget: const Tile(
                title: 'Tailscale',
                accent: _teal,
                statusLabel: 'online',
                statusColor: _ok,
                rows: [
                  TileRow('tailnet', 'headscale.f44.fyi'),
                  TileRow('self_ip', '100.64.0.1'),
                ],
              ),
              height: 2 + 6,
            ),
          ];

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Text(
                    'Dashboard layout preview ($cols-col layout, '
                    '[Esc] back)',
                    style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                  ),
                ),
                const SizedBox(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: tileRows(tiles, cols),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
