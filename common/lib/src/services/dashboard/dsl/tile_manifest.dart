import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:common/src/services/dashboard/dsl/primitives.dart';

@immutable
class TileManifest {
  final String id;
  final String title;
  final String? accentColor;
  final List<Primitive> layout;

  /// Either a [Primitive] (Footer) or a Map containing a `$status` directive.
  /// The renderer resolves directives at render time.
  final dynamic footer;

  const TileManifest({
    required this.id,
    required this.title,
    this.accentColor,
    required this.layout,
    this.footer,
  });

  factory TileManifest.fromJsonString(String s) {
    dynamic decoded;
    try {
      decoded = jsonDecode(s);
    } on FormatException catch (e) {
      throw TileManifestError('JSON parse failed: ${e.message}');
    }
    if (decoded is! Map) {
      throw TileManifestError('Manifest root must be an object');
    }
    return TileManifest.fromJson(decoded.cast<String, dynamic>());
  }

  factory TileManifest.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw TileManifestError('Manifest.id is required (non-empty string)');
    }
    final title = json['title'];
    if (title is! String) {
      throw TileManifestError('Manifest.title is required');
    }
    final layoutRaw = json['layout'];
    if (layoutRaw is! List) {
      throw TileManifestError('Manifest.layout must be a list');
    }
    final layout = layoutRaw
        .cast<Map<String, dynamic>>()
        .map((j) => Primitive.fromJson(j))
        .toList();

    dynamic footer;
    final f = json['footer'];
    if (f is Map) {
      // If the map has a single primitive key (Footer), parse it.
      // Otherwise leave as a Map (likely a $status directive) for the
      // renderer to resolve later.
      final keys = f.keys.toList();
      if (keys.length == 1 && keys.first == 'Footer') {
        footer = Primitive.fromJson(
          f.cast<String, dynamic>(),
          allowFooter: true,
        );
      } else {
        footer = f;
      }
    }

    return TileManifest(
      id: id,
      title: title,
      accentColor: json['accent_color'] as String?,
      layout: layout,
      footer: footer,
    );
  }
}
