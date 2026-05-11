import 'package:common/src/services/dashboard/colors.dart';
import 'package:common/src/services/dashboard/dsl/binding_resolver.dart';
import 'package:common/src/services/dashboard/dsl/primitives.dart' as dsl;
import 'package:common/src/services/dashboard/dsl/tile_manifest.dart';
import 'package:common/src/services/dashboard/tile_snapshot.dart';
import 'package:nocterm/nocterm.dart';
import '../../widgets/tile.dart';

/// Default accent used when the manifest does not specify one.
const _defaultAccent = Color.fromRGB(100, 180, 255);

/// Width hints for a tile's three-column grid:
/// [label column] [flex middle column] [value column].
///
/// `label` and `value` are character widths derived from the
/// widest rendered string in their respective columns; the
/// middle column is Flex / Expanded and absorbs the rest. Bars
/// live in the middle column so they stretch to fill it without
/// disturbing label / value alignment.
class _GridWidths {
  final int label;
  final int value;
  const _GridWidths({required this.label, required this.value});
}

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

    // Pre-render pass: compute the widest label and the widest
    // rendered value string across every row-like primitive in the
    // tile. These drive the three-column grid so labels left-align
    // in their column, values right-align in theirs, and the
    // middle column (where ProgressBars live) stretches to fill
    // the rest.
    final grid = _computeGridWidths(manifest.layout, data);

    for (final p in manifest.layout) {
      primitiveWidgets.add(
        _buildPrimitive(p, data, accent, indent: 0, grid: grid),
      );
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

  /// Walk Row / StatusRow / ProgressBar primitives (recursing
  /// into Sections) and compute the widest label and widest
  /// rendered value text. Indent contributes to the label width
  /// so a Section's nested labels still fit their column.
  /// ProgressBar pcts max out at 4 chars ("100%").
  static _GridWidths _computeGridWidths(
    List<dsl.Primitive> layout,
    Map<String, dynamic> data, {
    int indent = 0,
  }) {
    var maxLabel = 0;
    var maxValue = 0;

    void countLabel(String? label) {
      final l = indent + (label?.length ?? 0);
      if (l > maxLabel) maxLabel = l;
    }

    void countValue(int w) {
      if (w > maxValue) maxValue = w;
    }

    for (final p in layout) {
      switch (p) {
        case dsl.Row():
          countLabel(p.label);
          countValue('${resolveValue(p.value, data)}'.length);
        case dsl.StatusRow():
          countLabel(p.label);
          countValue('${resolveValue(p.value, data)}'.length);
        case dsl.ProgressBar():
          countLabel(p.label);
          countValue(4); // max "100%"
        case dsl.Section():
          final sub = _computeGridWidths(p.children, data, indent: indent + 2);
          if (sub.label > maxLabel) maxLabel = sub.label;
          if (sub.value > maxValue) maxValue = sub.value;
        default:
          break;
      }
    }
    return _GridWidths(label: maxLabel, value: maxValue);
  }

  Component _buildPrimitive(
    dsl.Primitive p,
    Map<String, dynamic> data,
    Color accent, {
    required int indent,
    required _GridWidths grid,
  }) {
    final prefix = ' ' * indent;
    switch (p) {
      case dsl.Row():
        final val = resolveValue(p.value, data);
        final color = p.valueColor != null
            ? resolveTileColor(p.valueColor, accent: accent)
            : null;
        return _gridRow(
          prefix: prefix,
          label: p.label,
          labelWidth: grid.label,
          valueText: '$val',
          valueWidth: grid.value,
          valueColor: color ?? const Color.fromRGB(220, 220, 220),
          middle: const SizedBox.shrink(),
        );

      case dsl.StatusRow():
        final val = resolveValue(p.value, data);
        final colorName = resolveValue(p.color, data);
        final color = resolveTileColor(
          colorName is String ? colorName : null,
          accent: accent,
        );
        return _gridRow(
          prefix: prefix,
          label: p.label,
          labelWidth: grid.label,
          valueText: '$val',
          valueWidth: grid.value,
          valueColor: color,
          middle: const SizedBox.shrink(),
        );

      case dsl.ProgressBar():
        final rawVal = resolveValue(p.value, data);
        final numVal = rawVal is num ? rawVal.toDouble() : 0.0;
        final rawMax = resolveValue(p.max, data);
        final maxNum = (rawMax is num) ? rawMax.toDouble() : 1.0;
        final pct = maxNum > 0 ? (numVal / maxNum).clamp(0.0, 1.0) : 0.0;
        final pctText = '${(pct * 100).round()}%';
        // Default progress bar fill is muted (not the bright default text color)
        // so the wide filled portion doesn't dominate the tile visually.
        final barColor = resolveTileColor(p.color ?? 'muted', accent: accent);
        return _gridRow(
          prefix: prefix,
          label: p.label,
          labelWidth: grid.label,
          valueText: pctText,
          valueWidth: grid.value,
          valueColor: const Color.fromRGB(220, 220, 220),
          // Bar lives in the middle (flex) column — stretches to
          // fill whatever space is between the label and value
          // columns, padded by 1 char on each side for visual
          // breathing room.
          middle: Row(
            children: [
              const SizedBox(width: 1),
              Expanded(
                child: ProgressBar(
                  value: pct,
                  valueColor: barColor,
                  fillCharacter: '█',
                  emptyCharacter: '░',
                ),
              ),
              const SizedBox(width: 1),
            ],
          ),
        );

      case dsl.Section():
        final sectionChildren = <Component>[
          if (p.title != null)
            Text(
              '$prefix${p.title}',
              style: TextStyle(color: accent, fontWeight: FontWeight.bold),
            ),
          ...p.children.map(
            (c) => _buildPrimitive(
              c,
              data,
              accent,
              indent: indent + 2,
              grid: grid,
            ),
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

  /// Renders one row of the tile's three-column grid:
  ///
  ///   [label-padded to labelWidth][middle (flex)][value-padded to valueWidth]
  ///
  /// `middle` is either a [Spacer] (plain Row / StatusRow) or a
  /// flex Component containing a [ProgressBar] (ProgressBar row).
  /// Padding the label / value to their column widths makes labels
  /// and values column-aligned across every row in the tile.
  Component _gridRow({
    required String prefix,
    required String? label,
    required int labelWidth,
    required String valueText,
    required int valueWidth,
    required Color valueColor,
    required Component middle,
  }) {
    final paddedLabel = '$prefix${label ?? ""}'.padRight(labelWidth);
    final paddedValue = valueText.padLeft(valueWidth);
    return Row(
      children: [
        Text(
          paddedLabel,
          style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
        Expanded(child: middle),
        Text(paddedValue, style: TextStyle(color: valueColor)),
      ],
    );
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

      // Overhead mirrors the widget Row layout:
      //   prefix + label + SizedBox(2) + bar + SizedBox(1) + pctText
      final labelLen = p.label != null
          ? prefix.length + p.label!.length + 2
          : 0;
      final overhead = labelLen + 1 + pctText.length;
      final barWidth = (width - overhead).clamp(4, 80);
      final filled = (pct * barWidth).round().clamp(0, barWidth);
      final bar = '${'█' * filled}${'░' * (barWidth - filled)}';

      if (p.label != null) {
        out.writeln('$prefix${p.label}  $bar $pctText');
      } else {
        out.writeln('$prefix$bar $pctText');
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
