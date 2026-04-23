import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../../widgets/tile.dart';
import 'format.dart';

/// Identity + ancillary-services tile. Bitcoin/LN have their own
/// tiles; everything else ends up here.
class SystemTile extends StatelessComponent {
  const SystemTile({super.key});

  @override
  Component build(BuildContext context) {
    final snap = context.watch(systemSnapshotProvider);

    return snap.when(
      loading: () => const Tile(
        title: 'System',
        accent: Color.fromRGB(220, 220, 220),
        rows: [TileRow('status', 'connecting…')],
      ),
      error: (e, _) => Tile(
        title: 'System',
        accent: const Color.fromRGB(220, 220, 220),
        footer: 'unreachable',
      ),
      data: (s) {
        if (s == null) {
          return const Tile(
            title: 'System',
            accent: Color.fromRGB(220, 220, 220),
            footer: 'unavailable — blitz-api is off',
          );
        }
        return Tile(
          title: 'System',
          accent: const Color.fromRGB(220, 220, 220),
          statusLabel: s.hostname,
          rows: [
            TileRow('platform', s.platform),
            TileRow('network', s.network),
            TileRow('uptime', humanDuration(s.uptime)),
            ...s.services.entries.map(
              (e) => TileRow(
                e.key,
                e.value.name,
                valueColor: _stateColor(e.value),
              ),
            ),
          ],
        );
      },
    );
  }

  Color _stateColor(ServiceState state) {
    switch (state) {
      case ServiceState.running:
        return const Color.fromRGB(110, 220, 110);
      case ServiceState.failed:
        return const Color.fromRGB(255, 120, 120);
      case ServiceState.activating:
        return const Color.fromRGB(220, 180, 100);
      case ServiceState.stopped:
      case ServiceState.unknown:
        return const Color.fromRGB(150, 150, 180);
    }
  }
}
