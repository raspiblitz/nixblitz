import 'package:meta/meta.dart';

/// Thrown when a manifest JSON tree is malformed.
class TileManifestError implements Exception {
  final String message;
  TileManifestError(this.message);
  @override
  String toString() => 'TileManifestError: $message';
}

/// Parent type for all primitive nodes. JSON shape is a single-key map
/// whose key names the primitive and whose value is the args map.
@immutable
sealed class Primitive {
  const Primitive();

  factory Primitive.fromJson(
    Map<String, dynamic> json, {
    bool allowFooter = false,
  }) {
    if (json.length != 1) {
      throw TileManifestError(
        'Primitive node must have exactly one key, got ${json.keys.toList()}',
      );
    }
    final name = json.keys.first;
    final args = (json.values.first as Map?)?.cast<String, dynamic>() ?? {};
    switch (name) {
      case 'Row':
        return Row._fromJson(args);
      case 'StatusRow':
        return StatusRow._fromJson(args);
      case 'ProgressBar':
        return ProgressBar._fromJson(args);
      case 'Section':
        return Section._fromJson(args);
      case 'Spacer':
        return Spacer._fromJson(args);
      case 'Footer':
        if (!allowFooter) {
          throw TileManifestError('Footer is only legal inside `footer:`');
        }
        return Footer._fromJson(args);
      default:
        throw TileManifestError('Unknown primitive: $name');
    }
  }
}

@immutable
class Row extends Primitive {
  final String label;
  final dynamic value; // literal, or a binding directive map
  final String? valueColor;
  const Row({required this.label, required this.value, this.valueColor});
  factory Row._fromJson(Map<String, dynamic> a) {
    final label = a['label'];
    if (label is! String) {
      throw TileManifestError('Row.label is required (string)');
    }
    if (!a.containsKey('value')) {
      throw TileManifestError('Row.value is required');
    }
    return Row(
      label: label,
      value: a['value'],
      valueColor: a['value_color'] as String?,
    );
  }
}

@immutable
class StatusRow extends Primitive {
  final String label;
  final dynamic value;
  final dynamic color; // literal or directive
  const StatusRow({
    required this.label,
    required this.value,
    required this.color,
  });
  factory StatusRow._fromJson(Map<String, dynamic> a) {
    final label = a['label'];
    if (label is! String) {
      throw TileManifestError('StatusRow.label is required (string)');
    }
    if (!a.containsKey('value')) {
      throw TileManifestError('StatusRow.value is required');
    }
    if (!a.containsKey('color')) {
      throw TileManifestError('StatusRow.color is required');
    }
    return StatusRow(label: label, value: a['value'], color: a['color']);
  }
}

@immutable
class ProgressBar extends Primitive {
  final dynamic
  value; // 0..1 if format=percent; current count if format=fraction/bytes
  final String? label;
  final dynamic max; // literal number OR a binding directive map
  final String format; // 'percent' | 'fraction' | 'bytes'
  final String? color;
  const ProgressBar({
    required this.value,
    this.label,
    this.max = 1.0,
    this.format = 'percent',
    this.color,
  });
  factory ProgressBar._fromJson(Map<String, dynamic> a) {
    if (!a.containsKey('value')) {
      throw TileManifestError('ProgressBar.value is required');
    }
    final fmt = (a['format'] as String?) ?? 'percent';
    if (!const {'percent', 'fraction', 'bytes'}.contains(fmt)) {
      throw TileManifestError(
        'ProgressBar.format must be percent|fraction|bytes',
      );
    }
    // max may be a literal number or a binding directive map (e.g.
    // {"\$data": "mem_total_bytes"}) — keep it dynamic so the renderer
    // can resolve at render time. Default 1.0 if absent.
    return ProgressBar(
      value: a['value'],
      label: a['label'] as String?,
      max: a['max'] ?? 1.0,
      format: fmt,
      color: a['color'] as String?,
    );
  }
}

@immutable
class Section extends Primitive {
  final String? title;
  final List<Primitive> children;
  const Section({this.title, required this.children});
  factory Section._fromJson(Map<String, dynamic> a) {
    final raw = a['children'];
    if (raw is! List) {
      throw TileManifestError('Section.children must be a list');
    }
    final children = raw
        .cast<Map<String, dynamic>>()
        .map((j) => Primitive.fromJson(j)) // allowFooter defaults false
        .toList();
    return Section(title: a['title'] as String?, children: children);
  }
}

@immutable
class Spacer extends Primitive {
  final int height;
  const Spacer({this.height = 1});
  factory Spacer._fromJson(Map<String, dynamic> a) {
    final h = a['height'] as num?;
    return Spacer(height: h?.toInt() ?? 1);
  }
}

@immutable
class Footer extends Primitive {
  final dynamic text;
  final dynamic color;
  const Footer({required this.text, this.color});
  factory Footer._fromJson(Map<String, dynamic> a) {
    if (!a.containsKey('text')) {
      throw TileManifestError('Footer.text is required');
    }
    return Footer(text: a['text'], color: a['color']);
  }
}
