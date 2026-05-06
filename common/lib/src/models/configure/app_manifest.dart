import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:common/src/models/configure/app_config_field.dart';

@immutable
class AppManifest {
  final String id;
  final String label;
  final String? description;
  final Set<String> capabilities;
  final List<AppConfigField> fields;
  final String? serviceUnit;

  const AppManifest({
    required this.id,
    required this.label,
    this.description,
    this.capabilities = const {},
    required this.fields,
    this.serviceUnit,
  });

  /// Resolved systemd unit name. Use this for service-status polling /
  /// log tailing (NOT [id], which matches the JSON key in app_configs).
  String get unitName => serviceUnit ?? id;

  /// Find a field by name. Returns null if absent.
  AppConfigField? field(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  factory AppManifest.fromJsonString(String s) {
    dynamic decoded;
    try {
      decoded = jsonDecode(s);
    } on FormatException catch (e) {
      throw AppManifestError('JSON parse failed: ${e.message}');
    }
    if (decoded is! Map) {
      throw AppManifestError('AppManifest root must be an object');
    }
    return AppManifest.fromJson(decoded.cast<String, dynamic>());
  }

  factory AppManifest.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw AppManifestError('AppManifest.id is required (non-empty string)');
    }
    final label = json['label'];
    if (label is! String) {
      throw AppManifestError('AppManifest.label is required (string)');
    }
    final caps = (json['capabilities'] as List?)?.cast<String>() ?? const [];
    final rawFields = (json['fields'] as List?) ?? const [];
    final parsed = <AppConfigField>[
      for (final f in rawFields.cast<Map<String, dynamic>>())
        AppConfigField.fromJson(f),
    ];
    return AppManifest(
      id: id,
      label: label,
      description: json['description'] as String?,
      capabilities: caps.toSet(),
      fields: parsed,
      serviceUnit: json['service_unit'] as String?,
    );
  }
}
