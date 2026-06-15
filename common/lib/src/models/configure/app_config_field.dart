import 'package:meta/meta.dart';

class AppManifestError implements Exception {
  final String message;
  AppManifestError(this.message);
  @override
  String toString() => 'AppManifestError: $message';
}

@immutable
sealed class AppConfigField {
  final String name;
  final String label;
  final String? description;
  const AppConfigField({
    required this.name,
    required this.label,
    this.description,
  });

  factory AppConfigField.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw AppManifestError('field.name is required (non-empty string)');
    }
    final label = json['label'];
    if (label is! String) {
      throw AppManifestError('field.label is required (string)');
    }
    final type = json['type'];
    if (type is! String) {
      throw AppManifestError('field.type is required (string)');
    }
    // `str` accepted as an alias for `string` — a plausible typo
    // some plugin manifests already shipped with. Canonical name
    // remains `string` (what the docs spec). Same for `integer`,
    // which a Python-flavored author may reach for over `int`.
    return switch (type) {
      'bool' => BoolField._fromJson(json),
      'string' || 'str' => StringField._fromJson(json),
      'secret' => SecretField._fromJson(json),
      'int' || 'integer' => IntField._fromJson(json),
      'enum' => EnumField._fromJson(json),
      'string_list' => StringListField._fromJson(json),
      _ => throw AppManifestError('unknown field type: $type'),
    };
  }

  Map<String, dynamic> toJson();
}

@immutable
class BoolField extends AppConfigField {
  final bool defaultValue;
  const BoolField({
    required super.name,
    required super.label,
    super.description,
    required this.defaultValue,
  });
  factory BoolField._fromJson(Map<String, dynamic> j) => BoolField(
    name: j['name'] as String,
    label: j['label'] as String,
    description: j['description'] as String?,
    defaultValue: (j['default'] as bool?) ?? false,
  );

  @override
  Map<String, dynamic> toJson() => {
    'name': name,
    'type': 'bool',
    'label': label,
    'default': defaultValue,
    if (description != null) 'description': description,
  };
}

@immutable
class StringField extends AppConfigField {
  final String defaultValue;
  final String? placeholder;
  const StringField({
    required super.name,
    required super.label,
    super.description,
    required this.defaultValue,
    this.placeholder,
  });
  factory StringField._fromJson(Map<String, dynamic> j) => StringField(
    name: j['name'] as String,
    label: j['label'] as String,
    description: j['description'] as String?,
    defaultValue: (j['default'] as String?) ?? '',
    placeholder: j['placeholder'] as String?,
  );

  @override
  Map<String, dynamic> toJson() => {
    'name': name,
    'type': 'string',
    'label': label,
    'default': defaultValue,
    if (description != null) 'description': description,
    if (placeholder != null) 'placeholder': placeholder,
  };
}

/// String-shaped field that stores a credential — auth keys, tokens,
/// passwords, etc. Differs from [StringField] only in the form-rendering
/// UX: the editor masks input as the operator types, and
/// [FieldDisplayRow] renders a placeholder (`•••` or `(set)`) instead
/// of the value to avoid shoulder-surfing / accidental screenshot leaks.
///
/// Storage in `app_configs.<id>.<name>` is plain string — no encryption
/// at rest. The expectation is that operators on shared screens or
/// recording sessions don't want the value visible mid-config-edit.
@immutable
class SecretField extends AppConfigField {
  final String defaultValue;
  final String? placeholder;
  const SecretField({
    required super.name,
    required super.label,
    super.description,
    required this.defaultValue,
    this.placeholder,
  });
  factory SecretField._fromJson(Map<String, dynamic> j) => SecretField(
    name: j['name'] as String,
    label: j['label'] as String,
    description: j['description'] as String?,
    defaultValue: (j['default'] as String?) ?? '',
    placeholder: j['placeholder'] as String?,
  );

  @override
  Map<String, dynamic> toJson() => {
    'name': name,
    'type': 'secret',
    'label': label,
    'default': defaultValue,
    if (description != null) 'description': description,
    if (placeholder != null) 'placeholder': placeholder,
  };
}

@immutable
class IntField extends AppConfigField {
  final int defaultValue;
  final int? min;
  final int? max;
  const IntField({
    required super.name,
    required super.label,
    super.description,
    required this.defaultValue,
    this.min,
    this.max,
  });
  factory IntField._fromJson(Map<String, dynamic> j) => IntField(
    name: j['name'] as String,
    label: j['label'] as String,
    description: j['description'] as String?,
    defaultValue: (j['default'] as num?)?.toInt() ?? 0,
    min: (j['min'] as num?)?.toInt(),
    max: (j['max'] as num?)?.toInt(),
  );

  @override
  Map<String, dynamic> toJson() => {
    'name': name,
    'type': 'int',
    'label': label,
    'default': defaultValue,
    if (description != null) 'description': description,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
  };
}

/// List-of-opaque-strings field. Each row is a free-form string
/// (no per-row choices); the editor surfaces an add / remove UI
/// over the list. Plugin authors use this for declarative
/// inventories the operator owns — e.g. LNBits extension ids managed
/// via Nix packages in manually-managed mode.
///
/// Validation is deliberately thin: per-row strings are stored
/// verbatim, no allow-list, no regex. Plugins that need a closed
/// set should use [EnumField] (single-select) or wait for a future
/// multi-select-from-choices field. Empty default `[]`.
@immutable
class StringListField extends AppConfigField {
  final List<String> defaultValue;
  final String? placeholder;
  const StringListField({
    required super.name,
    required super.label,
    super.description,
    required this.defaultValue,
    this.placeholder,
  });
  factory StringListField._fromJson(Map<String, dynamic> j) {
    final rawDefault = j['default'];
    final def = rawDefault is List
        ? rawDefault.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    return StringListField(
      name: j['name'] as String,
      label: j['label'] as String,
      description: j['description'] as String?,
      defaultValue: def,
      placeholder: j['placeholder'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'name': name,
    'type': 'string_list',
    'label': label,
    'default': defaultValue,
    if (description != null) 'description': description,
    if (placeholder != null) 'placeholder': placeholder,
  };
}

@immutable
class EnumField extends AppConfigField {
  final List<String> choices;
  final String defaultValue;
  const EnumField({
    required super.name,
    required super.label,
    super.description,
    required this.choices,
    required this.defaultValue,
  });
  factory EnumField._fromJson(Map<String, dynamic> j) {
    final choices = (j['choices'] as List?)?.cast<String>() ?? const [];
    if (choices.isEmpty) {
      throw AppManifestError('enum field "${j['name']}" requires choices');
    }
    final def = j['default'];
    if (def is! String) {
      throw AppManifestError(
        'enum field "${j['name']}".default required (string)',
      );
    }
    if (!choices.contains(def)) {
      throw AppManifestError(
        'enum field "${j['name']}".default "$def" not in choices $choices',
      );
    }
    return EnumField(
      name: j['name'] as String,
      label: j['label'] as String,
      description: j['description'] as String?,
      choices: choices,
      defaultValue: def,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'name': name,
    'type': 'enum',
    'label': label,
    'choices': choices,
    'default': defaultValue,
    if (description != null) 'description': description,
  };
}
