import 'package:common/src/services/dashboard/colors.dart';
import 'package:common/src/services/dashboard/dsl/binding_resolver.dart';
import 'package:common/src/services/dashboard/dsl/primitives.dart' as dsl;
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:nocterm/nocterm.dart';
import '../../widgets/tile.dart';

/// Default accent used when the manifest does not specify one.
const _defaultAccent = Color.fromRGB(100, 180, 255);

Color _accent(TileManifest m) {
  if (m.accentColor == null) return _defaultAccent;
  return parseHex(m.accentColor!) ?? _defaultAccent;
}

/// A nocterm widget that renders any [TileManifest] + [TileSnapshot] pair
/// using the generic primitive tree. This is the single replacement for the
/// four hand-written tile widgets that will be deleted in Task 17.
class TileRenderer extends StatelessComponent {
  final TileManifest manifest;
  final TileSnapshot snapshot;

  const TileRenderer({
    required this.manifest,
    required this.snapshot,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final accent = _accent(manifest);
    final data = snapshot.data;
    final primitiveWidgets = <Component>[];

    for (final p in manifest.layout) {
      primitiveWidgets.add(_buildPrimitive(p, data, accent, indent: 0));
    }

    // Footer resolution
    final footerResult = _resolveFooterWidget(manifest, snapshot, accent);
    final footerText = footerResult?.$1;
    final footerColor = footerResult?.$2;

    // Build a Column from all primitive widgets and pass it as child so the
    // Tile chrome (border + title bar + footer) wraps the full manifest body.
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: primitiveWidgets,
    );

    return Tile(
      title: manifest.title,
      accent: accent,
      footer: footerText,
      footerColor: footerColor,
      child: body,
    );
  }

  Component _buildPrimitive(
    dsl.Primitive p,
    Map<String, dynamic> data,
    Color accent, {
    required int indent,
  }) {
    final prefix = ' ' * indent;
    switch (p) {
      case dsl.Row():
        final val = resolveValue(p.value, data);
        final color = p.valueColor != null
            ? resolveTileColor(p.valueColor, accent: accent)
            : null;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '$prefix${p.label}',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            Text(
              '$val',
              style: TextStyle(
                color: color ?? const Color.fromRGB(220, 220, 220),
              ),
            ),
          ],
        );

      case dsl.StatusRow():
        final val = resolveValue(p.value, data);
        final colorName = resolveValue(p.color, data);
        final color = resolveTileColor(
          colorName is String ? colorName : null,
          accent: accent,
        );
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '$prefix${p.label}',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            Text('$val', style: TextStyle(color: color)),
          ],
        );

      case dsl.ProgressBar():
        final rawVal = resolveValue(p.value, data);
        final numVal = rawVal is num ? rawVal.toDouble() : 0.0;
        final rawMax = resolveValue(p.max, data);
        final maxNum = (rawMax is num) ? rawMax.toDouble() : 1.0;
        final pct = maxNum > 0 ? (numVal / maxNum).clamp(0.0, 1.0) : 0.0;
        final pctText = '${(pct * 100).round()}%';
        final barColor = resolveTileColor(p.color, accent: accent);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.label != null)
              Text(
                '$prefix${p.label}',
                style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            Row(
              children: [
                Expanded(
                  child: _ProgressBarWidget(value: pct, color: barColor),
                ),
                Text(
                  ' $pctText',
                  style: const TextStyle(color: Color.fromRGB(220, 220, 220)),
                ),
              ],
            ),
          ],
        );

      case dsl.Section():
        final sectionChildren = <Component>[
          if (p.title != null)
            Text(
              '$prefix${p.title}',
              style: TextStyle(color: accent, fontWeight: FontWeight.bold),
            ),
          ...p.children.map(
            (c) => _buildPrimitive(c, data, accent, indent: indent + 2),
          ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: sectionChildren,
        );

      case dsl.Spacer():
        return SizedBox(height: p.height.toDouble());

      case dsl.Footer():
        // Footer inside layout (unusual, but handled gracefully)
        final text = resolveValue(p.text, data);
        final color = resolveTileColor(
          p.color is String ? p.color as String : null,
          accent: accent,
        );
        return Text('$text', style: TextStyle(color: color));
    }
  }

  (String, Color)? _resolveFooterWidget(
    TileManifest m,
    TileSnapshot snap,
    Color accent,
  ) {
    final errorColor = const Color.fromRGB(0xef, 0x53, 0x50);
    final mutedColor = const Color.fromRGB(0x9e, 0x9e, 0x9e);

    // Priority 1 & 2: error states
    if (snap.lastError != null) {
      final msg = snap.lastError.toString();
      if (msg.contains('crash-looping')) {
        return ('crash-looping — see log', errorColor);
      }
      return (msg, errorColor);
    }

    // Priority 3: empty snapshot
    if (snap.isEmpty) {
      return ('no data', mutedColor);
    }

    // Priority 4: manifest has a direct Footer primitive
    if (m.footer is dsl.Footer) {
      final f = m.footer as dsl.Footer;
      final text = resolveValue(f.text, snap.data);
      final color = resolveTileColor(
        f.color is String ? f.color as String : null,
        accent: accent,
      );
      return ('$text', color);
    }

    // Priority 5: manifest footer is a $status directive map
    if (m.footer is Map) {
      final resolved = resolveValue(m.footer, snap.data);
      if (resolved is Map) {
        // Should resolve to {"Footer": {"text": ..., "color": ...}}
        final footerArgs = (resolved['Footer'] as Map?)
            ?.cast<String, dynamic>();
        if (footerArgs != null) {
          final text = resolveValue(footerArgs['text'], snap.data);
          final color = resolveTileColor(
            footerArgs['color'] as String?,
            accent: accent,
          );
          return ('$text', color);
        }
      }
    }

    return null;
  }
}

/// Internal widget for rendering a simple text-based progress bar.
class _ProgressBarWidget extends StatelessComponent {
  final double value; // 0.0 to 1.0
  final Color color;

  const _ProgressBarWidget({required this.value, required this.color});

  @override
  Component build(BuildContext context) {
    // We'll use 20 cells for the bar.
    const cells = 20;
    final filled = (value * cells).round().clamp(0, cells);
    final bar = '${'█' * filled}${'·' * (cells - filled)}';
    return Text(bar, style: TextStyle(color: color));
  }
}

// ---------------------------------------------------------------------------
// Text-rendering helper for golden-style tests.
// Not used at runtime.
// ---------------------------------------------------------------------------

/// Renders a [TileManifest] + [TileSnapshot] to plain text.
/// Used by unit tests to verify rendering logic without spinning up nocterm.
String renderTileToText(TileManifest m, TileSnapshot snap, {int width = 40}) {
  final out = StringBuffer();
  out.writeln('=== ${m.title} ===');
  for (final p in m.layout) {
    _renderPrimitiveToText(p, snap.data, out, indent: 0, width: width);
  }
  final footer = _resolveFooterText(m, snap);
  if (footer != null) out.writeln('— $footer');
  return out.toString();
}

void _renderPrimitiveToText(
  dsl.Primitive p,
  Map<String, dynamic> data,
  StringBuffer out, {
  required int indent,
  required int width,
}) {
  final prefix = ' ' * indent;
  switch (p) {
    case dsl.Row():
      final val = resolveValue(p.value, data);
      out.writeln('$prefix${p.label}: $val');

    case dsl.StatusRow():
      final val = resolveValue(p.value, data);
      out.writeln('$prefix${p.label}: $val');

    case dsl.ProgressBar():
      final rawVal = resolveValue(p.value, data);
      final numVal = rawVal is num ? rawVal.toDouble() : 0.0;
      final rawMax = resolveValue(p.max, data);
      final maxNum = (rawMax is num) ? rawMax.toDouble() : 1.0;
      final pct = maxNum > 0 ? (numVal / maxNum).clamp(0.0, 1.0) : 0.0;
      final pctText = '${(pct * 100).round()}%';

      // Bar width: subtract label + space + percent + spaces from width
      final labelPart = p.label != null ? '${p.label} ' : '';
      final barWidth = (width - labelPart.length - pctText.length - 3).clamp(
        4,
        40,
      );
      final filled = (pct * barWidth).round().clamp(0, barWidth);
      final bar = '${'█' * filled}${'·' * (barWidth - filled)}';

      if (p.label != null) {
        out.writeln('$prefix${p.label} [$bar] $pctText');
      } else {
        out.writeln('$prefix[$bar] $pctText');
      }

    case dsl.Section():
      if (p.title != null) {
        out.writeln('$prefix${p.title}');
      }
      for (final c in p.children) {
        _renderPrimitiveToText(c, data, out, indent: indent + 2, width: width);
      }

    case dsl.Spacer():
      for (var i = 0; i < p.height; i++) {
        out.writeln();
      }

    case dsl.Footer():
      final text = resolveValue(p.text, data);
      out.writeln('— $text');
  }
}

String? _resolveFooterText(TileManifest m, TileSnapshot snap) {
  // Priority 1: crash-loop detection
  if (snap.lastError != null) {
    final msg = snap.lastError.toString();
    if (msg.contains('crash-looping')) {
      return 'crash-looping — see log';
    }
    // Priority 2: other error
    return msg;
  }

  // Priority 3: empty snapshot
  if (snap.isEmpty) {
    return 'no data';
  }

  // Priority 4: manifest has a direct Footer primitive
  if (m.footer is dsl.Footer) {
    final f = m.footer as dsl.Footer;
    final text = resolveValue(f.text, snap.data);
    return '$text';
  }

  // Priority 5: manifest footer is a $status directive map
  if (m.footer is Map) {
    final resolved = resolveValue(m.footer, snap.data);
    if (resolved is Map) {
      final footerArgs = (resolved['Footer'] as Map?)?.cast<String, dynamic>();
      if (footerArgs != null) {
        final text = resolveValue(footerArgs['text'], snap.data);
        return '$text';
      }
    }
  }

  return null;
}
