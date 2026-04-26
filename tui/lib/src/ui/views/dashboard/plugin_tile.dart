import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../widgets/tile.dart';

/// Renders one plugin-declared tile. Watches
/// [pluginTileSnapshotsProvider] and pulls the entry for [dirName].
/// Translates the common-layer string color keys + hex accent into
/// nocterm `Color` values for the underlying [Tile].
class PluginTile extends StatelessComponent {
  final String dirName;

  /// Fallback used when no snapshot has arrived yet. Sourced from
  /// the manifest's `dashboard.title`. We keep it as a constructor
  /// arg so the dashboard view (which already reads the manifest to
  /// decide which plugins get tiles) doesn't have to round-trip it
  /// through the provider.
  final String fallbackTitle;
  final String accentColorHex;

  const PluginTile({
    super.key,
    required this.dirName,
    required this.fallbackTitle,
    required this.accentColorHex,
  });

  @override
  Component build(BuildContext context) {
    final accent = _hexToColor(accentColorHex);
    final async = context.watch(pluginTileSnapshotsProvider);

    final snapshot = async.maybeWhen(
      data: (m) => m[dirName],
      orElse: () => null,
    );

    if (snapshot == null) {
      return Tile(
        title: fallbackTitle,
        accent: accent,
        rows: const [],
        footer: 'loading…',
        footerColor: const Color.fromRGB(150, 150, 180),
      );
    }

    return Tile(
      title: snapshot.title,
      accent: _hexToColor(snapshot.accentColorHex),
      statusLabel: snapshot.statusLabel,
      statusColor: snapshot.statusColor == null
          ? null
          : _statusToColor(snapshot.statusColor!),
      rows: [
        for (final r in snapshot.rows) TileRow(r.label, r.value),
      ],
      footer: snapshot.footer,
      footerColor: snapshot.footerColor == null
          ? null
          : _statusToColor(snapshot.footerColor!),
    );
  }
}

/// Map a `#rrggbb` hex string to a nocterm Color. Falls back to the
/// neutral grey on any parse error — should never happen because
/// `PluginTileSpec.fromJson` validates the format up front.
Color _hexToColor(String hex) {
  if (hex.length != 7 || !hex.startsWith('#')) {
    return const Color.fromRGB(136, 136, 153);
  }
  final r = int.tryParse(hex.substring(1, 3), radix: 16) ?? 0x88;
  final g = int.tryParse(hex.substring(3, 5), radix: 16) ?? 0x88;
  final b = int.tryParse(hex.substring(5, 7), radix: 16) ?? 0x99;
  return Color.fromRGB(r, g, b);
}

Color _statusToColor(PluginTileStatus s) => switch (s) {
      PluginTileStatus.ok => const Color.fromRGB(110, 220, 110),
      PluginTileStatus.warn => const Color.fromRGB(220, 180, 100),
      PluginTileStatus.error => const Color.fromRGB(255, 80, 80),
    };
