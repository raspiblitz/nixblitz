# UI Generalization — Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded per-app structure in `configure_view.dart` (900-line switch tree), `install_view.dart` (`_LightningChoice` enum), and the debug views' service list with **manifest-driven** discovery and rendering. Each of the 5 bundled apps gains a JSON manifest declaring its config field schema and capability tags. Plugin manifests gain an optional `config_schema` so Phase 4–6 plugin extraction lifts the manifest unchanged.

**Architecture:** New `AppManifest` model with 4 field types (`bool`, `string`, `int`, `enum<choices>`). 5 bundled manifests under `common/lib/src/services/configure/bundled/manifests/` embedded via codegen. `AppManifestRegistry` combines bundled + plugin sources; query API (`withCapability(tag)`, `serviceIds()`). Generic `FieldEditor` dispatcher replaces the per-app switch tree. `installed.nix` and per-app NixOS modules untouched (Phases 4–6).

**Tech Stack:** Dart, Riverpod, JSON, codegen mirroring Phase 1's `gen_dashboard_manifests` pattern.

**Spec:** `docs/superpowers/specs/2026-05-06-ui-generalization-design.md`

---

## File Structure

### New files

```
common/lib/src/models/configure/
  app_config_field.dart                    # sealed class + 4 subtypes
  app_manifest.dart                        # AppManifest model + parser

common/lib/src/services/configure/
  app_manifest_registry.dart               # bundled + plugin combined registry
  bundled/
    manifests/
      bitcoind.json                        # 5 bundled manifests
      lnd.json
      cln.json
      blitz_api.json
      blitz_web.json
    embedded_schemas.dart                  # `part of` host
    embedded_schemas.g.dart                # GENERATED
    registry.dart                          # bundledAppManifests getter

common/lib/src/providers/
  app_manifest_registry_provider.dart      # Riverpod provider

tui/lib/src/ui/views/configure/
  field_editor.dart                        # generic editor dispatcher

scripts/
  gen_app_config_schemas.dart              # codegen
```

### Modified files

```
common/lib/src/models/
  plugin_manifest.dart                     # add optional config_schema field

tui/lib/src/ui/views/
  configure_view.dart                      # full rewrite from switch tree to generic walker
  install_view.dart                        # wizard reads capabilities
  debug/service_health.dart                # service list from registry
  debug/tail_log.dart                      # service list from registry

common/lib/src/services/
  system_service.dart                      # getAllServiceStatuses reads from registry

justfile                                   # add gen-app-schemas recipe
```

### Untouched

- `templates/hosts/installed.nix` and per-app NixOS modules — Nix template wiring stays per-app named (Phases 4–6).
- `NixblitzConfig` and `app_configs` JSON shape — unchanged from Phase 2.
- Plugin install / refresh / pin lifecycle — only the manifest _schema_ gains a `config_schema` section.
- `SystemConfig` — stays typed.

---

## Conventions

- **Trio gate** at the end of every task: `just test && just analyze && just format`. All tasks land green-trio (no intentional mid-stream red — Phase 3's incremental nature allows clean shipping per task).
- **Per-test runs**: `cd common && dart test test/path/foo_test.dart` or `cd tui && dart test test/path/foo_test.dart`.
- **Commit format**: `<type>(<scope>): <subject>` + concise body focused on the why + `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` footer. **No issue refs. No personal email addresses anywhere.**
- **VCS**: jj. Subagents commit per task via `jj commit -m '...'` with HEREDOC.

---

## Task 1: `AppConfigField` + `AppManifest` models + parser

**Files:**

- Create: `common/lib/src/models/configure/app_config_field.dart`
- Create: `common/lib/src/models/configure/app_manifest.dart`
- Test: `common/test/models/configure/app_config_field_test.dart`
- Test: `common/test/models/configure/app_manifest_test.dart`

**Spec reference:** "Schema design" section.

- [ ] **Step 1: Write failing tests for `AppConfigField`**

```dart
// common/test/models/configure/app_config_field_test.dart
import 'package:common/src/models/configure/app_config_field.dart';
import 'package:test/test.dart';

void main() {
  group('AppConfigField.fromJson', () {
    test('bool field', () {
      final f = AppConfigField.fromJson({
        'name': 'enabled', 'type': 'bool', 'label': 'Enabled', 'default': false,
      });
      expect(f, isA<BoolField>());
      expect(f.name, 'enabled');
      expect((f as BoolField).defaultValue, isFalse);
    });

    test('string field with placeholder', () {
      final f = AppConfigField.fromJson({
        'name': 'alias', 'type': 'string', 'label': 'Alias',
        'default': '', 'placeholder': 'my-node',
      });
      expect(f, isA<StringField>());
      expect((f as StringField).placeholder, 'my-node');
    });

    test('int field with min/max', () {
      final f = AppConfigField.fromJson({
        'name': 'prune_size_gb', 'type': 'int', 'label': 'Prune size',
        'default': 0, 'min': 0, 'max': 4096,
      });
      expect(f, isA<IntField>());
      expect((f as IntField).min, 0);
      expect(f.max, 4096);
    });

    test('enum field', () {
      final f = AppConfigField.fromJson({
        'name': 'network', 'type': 'enum', 'label': 'Network',
        'choices': ['mainnet', 'testnet', 'regtest', 'signet'],
        'default': 'mainnet',
      });
      expect(f, isA<EnumField>());
      expect((f as EnumField).choices, ['mainnet', 'testnet', 'regtest', 'signet']);
      expect(f.defaultValue, 'mainnet');
    });

    test('description is optional', () {
      final f = AppConfigField.fromJson({
        'name': 'enabled', 'type': 'bool', 'label': 'L', 'default': false,
        'description': 'turn it on',
      });
      expect(f.description, 'turn it on');
    });

    test('unknown type throws AppManifestError', () {
      expect(
        () => AppConfigField.fromJson({
          'name': 'x', 'type': 'donut', 'label': 'X', 'default': 'glaze',
        }),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('missing required name throws', () {
      expect(
        () => AppConfigField.fromJson({'type': 'bool', 'label': 'X', 'default': false}),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('missing required label throws', () {
      expect(
        () => AppConfigField.fromJson({'name': 'x', 'type': 'bool', 'default': false}),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('enum default not in choices throws', () {
      expect(
        () => AppConfigField.fromJson({
          'name': 'n', 'type': 'enum', 'label': 'N',
          'choices': ['a', 'b'], 'default': 'c',
        }),
        throwsA(isA<AppManifestError>()),
      );
    });
  });
}
```

- [ ] **Step 2: Write failing tests for `AppManifest`**

```dart
// common/test/models/configure/app_manifest_test.dart
import 'package:common/src/models/configure/app_config_field.dart';
import 'package:common/src/models/configure/app_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('AppManifest.fromJsonString', () {
    test('full round-trip', () {
      final m = AppManifest.fromJsonString(r'''
        {
          "id": "lnd",
          "label": "LND",
          "description": "Lightning Network Daemon",
          "capabilities": ["lightning_backend"],
          "fields": [
            {"name": "enabled", "type": "bool", "label": "Enabled", "default": false},
            {"name": "alias",   "type": "string", "label": "Alias",   "default": "", "placeholder": "my-node"}
          ]
        }
      ''');
      expect(m.id, 'lnd');
      expect(m.label, 'LND');
      expect(m.capabilities, contains('lightning_backend'));
      expect(m.fields.length, 2);
      expect(m.fields.first, isA<BoolField>());
      expect(m.serviceUnit, isNull);
      expect(m.unitName, 'lnd');   // falls back to id
    });

    test('service_unit override', () {
      final m = AppManifest.fromJsonString(r'''
        {
          "id": "cln",
          "label": "CLN",
          "service_unit": "clightning",
          "fields": []
        }
      ''');
      expect(m.serviceUnit, 'clightning');
      expect(m.unitName, 'clightning');
    });

    test('field(name) lookup', () {
      final m = AppManifest.fromJsonString(r'''
        {"id": "x", "label": "X", "fields": [
          {"name": "enabled", "type": "bool", "label": "Enabled", "default": false}
        ]}
      ''');
      expect(m.field('enabled'), isA<BoolField>());
      expect(m.field('missing'), isNull);
    });

    test('rejects missing id', () {
      expect(
        () => AppManifest.fromJsonString(r'{"label": "X", "fields": []}'),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('rejects missing label', () {
      expect(
        () => AppManifest.fromJsonString(r'{"id": "x", "fields": []}'),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => AppManifest.fromJsonString('not json'),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('empty fields list is allowed', () {
      final m = AppManifest.fromJsonString(r'{"id": "x", "label": "X", "fields": []}');
      expect(m.fields, isEmpty);
    });

    test('empty capabilities default', () {
      final m = AppManifest.fromJsonString(r'{"id": "x", "label": "X", "fields": []}');
      expect(m.capabilities, isEmpty);
    });
  });
}
```

- [ ] **Step 3: Implement `app_config_field.dart`**

```dart
// common/lib/src/models/configure/app_config_field.dart
import 'package:meta/meta.dart';

class AppManifestError implements Exception {
  final String message;
  AppManifestError(this.message);
  @override String toString() => 'AppManifestError: $message';
}

@immutable
sealed class AppConfigField {
  final String name;
  final String label;
  final String? description;
  const AppConfigField({required this.name, required this.label, this.description});

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
    return switch (type) {
      'bool'   => BoolField._fromJson(json),
      'string' => StringField._fromJson(json),
      'int'    => IntField._fromJson(json),
      'enum'   => EnumField._fromJson(json),
      _ => throw AppManifestError('unknown field type: $type'),
    };
  }
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
}

@immutable
class IntField extends AppConfigField {
  final int defaultValue;
  final int? min, max;
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
      throw AppManifestError('enum field "${j['name']}".default required (string)');
    }
    if (!choices.contains(def)) {
      throw AppManifestError(
        'enum field "${j['name']}".default "$def" not in choices ${choices}',
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
}
```

- [ ] **Step 4: Implement `app_manifest.dart`**

```dart
// common/lib/src/models/configure/app_manifest.dart
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
```

- [ ] **Step 5: Run tests + trio + commit**

```bash
cd common && dart test test/models/configure/
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(configure): AppConfigField + AppManifest models + parser

Sealed AppConfigField with four subtypes (BoolField, StringField,
IntField, EnumField) covering every existing field across the 5
bundled apps. AppManifest holds id, label, description, capabilities,
fields, optional service_unit override. Field-level validation:
required name + label + type, enum defaults must be in choices.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 5 bundled manifest JSON files

**Files:**

- Create: `common/lib/src/services/configure/bundled/manifests/bitcoind.json`
- Create: `common/lib/src/services/configure/bundled/manifests/lnd.json`
- Create: `common/lib/src/services/configure/bundled/manifests/cln.json`
- Create: `common/lib/src/services/configure/bundled/manifests/blitz_api.json`
- Create: `common/lib/src/services/configure/bundled/manifests/blitz_web.json`
- Test: `common/test/services/configure/bundled/manifests_test.dart`

**Spec reference:** "Bundled-app manifests" section.

- [ ] **Step 1: Write `bitcoind.json`**

```json
{
  "id": "bitcoind",
  "label": "Bitcoin Core",
  "description": "Bitcoin reference client (full or pruned node)",
  "capabilities": [],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
    {
      "name": "network",
      "type": "enum",
      "label": "Network",
      "choices": ["mainnet", "testnet", "regtest", "signet"],
      "default": "mainnet"
    },
    {
      "name": "pruned",
      "type": "bool",
      "label": "Prune mode",
      "default": false
    },
    {
      "name": "prune_size_gb",
      "type": "int",
      "label": "Prune size (GB)",
      "default": 0,
      "min": 0
    }
  ]
}
```

- [ ] **Step 2: Write `lnd.json`**

```json
{
  "id": "lnd",
  "label": "LND",
  "description": "Lightning Network Daemon (LND backend)",
  "capabilities": ["lightning_backend"],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
    {
      "name": "alias",
      "type": "string",
      "label": "Alias",
      "default": "",
      "placeholder": "my-node"
    }
  ]
}
```

- [ ] **Step 3: Write `cln.json`**

```json
{
  "id": "cln",
  "label": "Core Lightning",
  "description": "Core Lightning (CLN) backend",
  "capabilities": ["lightning_backend"],
  "service_unit": "clightning",
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false }
  ]
}
```

- [ ] **Step 4: Write `blitz_api.json`**

```json
{
  "id": "blitz_api",
  "label": "Blitz API",
  "description": "FastAPI backend for the Blitz web frontend",
  "capabilities": [],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false }
  ]
}
```

- [ ] **Step 5: Write `blitz_web.json`**

```json
{
  "id": "blitz_web",
  "label": "Blitz Web",
  "description": "Web frontend for monitoring + managing the node",
  "capabilities": [],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false }
  ]
}
```

- [ ] **Step 6: Write parse-validation test**

```dart
// common/test/services/configure/bundled/manifests_test.dart
import 'dart:io';

import 'package:common/src/models/configure/app_manifest.dart';
import 'package:test/test.dart';

void main() {
  for (final name in ['bitcoind', 'lnd', 'cln', 'blitz_api', 'blitz_web']) {
    test('$name.json parses', () {
      final s = File('lib/src/services/configure/bundled/manifests/$name.json')
          .readAsStringSync();
      final m = AppManifest.fromJsonString(s);
      expect(m.id, name);
      expect(m.label.isNotEmpty, isTrue);
    });
  }

  test('lnd + cln declare lightning_backend', () {
    for (final name in ['lnd', 'cln']) {
      final s = File('lib/src/services/configure/bundled/manifests/$name.json')
          .readAsStringSync();
      final m = AppManifest.fromJsonString(s);
      expect(m.capabilities, contains('lightning_backend'));
    }
  });

  test('cln has service_unit override to clightning', () {
    final s = File('lib/src/services/configure/bundled/manifests/cln.json')
        .readAsStringSync();
    final m = AppManifest.fromJsonString(s);
    expect(m.serviceUnit, 'clightning');
    expect(m.unitName, 'clightning');
  });
}
```

- [ ] **Step 7: Run tests + trio + commit**

```bash
cd common && dart test test/services/configure/bundled/manifests_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(configure): bundled manifests for the five core apps

bitcoind, lnd, cln, blitz_api, blitz_web manifests declare each app's
config field schema (current contents of NixblitzConfig.app_configs
keys). lnd + cln declare the lightning_backend capability for install
wizard discovery. cln declares service_unit: clightning for the
debug views' service-status polling.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Codegen + bundled registry

**Files:**

- Create: `scripts/gen_app_config_schemas.dart`
- Create: `common/lib/src/services/configure/bundled/embedded_schemas.dart` (`part of` host)
- Create: `common/lib/src/services/configure/bundled/embedded_schemas.g.dart` (generated)
- Create: `common/lib/src/services/configure/bundled/registry.dart`
- Modify: `justfile` — add `gen-app-schemas` recipe
- Test: `common/test/services/configure/bundled/registry_test.dart`

**Spec reference:** Bundled-app codegen mirrors Phase 1's `gen_dashboard_manifests.dart` pattern.

- [ ] **Step 1: Read Phase 1's pattern**

```bash
cat scripts/gen_dashboard_manifests.dart
head -30 common/lib/src/services/dashboard/bundled/embedded_manifests.dart
head -30 common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart
```

- [ ] **Step 2: Write `scripts/gen_app_config_schemas.dart`**

Mirror the structure exactly. Read JSON files from
`common/lib/src/services/configure/bundled/manifests/`, sort, write a
generated `.g.dart` with raw-string constants + a top-level Map.

```dart
// scripts/gen_app_config_schemas.dart
import 'dart:io';

void main() {
  final dir = Directory(
    'common/lib/src/services/configure/bundled/manifests',
  );
  final files = dir.listSync().whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final out = StringBuffer()
    ..writeln(
      "// GENERATED — do not edit. Run 'just gen-app-schemas' to regenerate.",
    )
    ..writeln(
      '// Source: common/lib/src/services/configure/bundled/manifests/',
    )
    ..writeln()
    ..writeln("part of 'embedded_schemas.dart';")
    ..writeln();

  final names = <String>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last.replaceAll('.json', '');
    names.add(name);
    final content = f.readAsStringSync();
    out
      ..writeln("const String _${name}Json = r'''")
      ..write(content)
      ..writeln("''';")
      ..writeln();
  }

  out
    ..writeln('const Map<String, String> _allAppSchemas = {')
    ..writeAll(names.map((n) => "  '$n': _${n}Json,"), '\n')
    ..writeln()
    ..writeln('};');

  File(
    'common/lib/src/services/configure/bundled/embedded_schemas.g.dart',
  ).writeAsStringSync(out.toString());
  stdout.writeln(
    'Wrote embedded_schemas.g.dart with ${files.length} manifests',
  );
}
```

- [ ] **Step 3: Write `embedded_schemas.dart` (the part-of host)**

```dart
// common/lib/src/services/configure/bundled/embedded_schemas.dart
library;

part 'embedded_schemas.g.dart';

class EmbeddedAppSchemas {
  /// All bundled app manifests as raw JSON strings, keyed by app name
  /// (filename without extension).
  static Map<String, String> getAll() => Map.unmodifiable(_allAppSchemas);
}
```

- [ ] **Step 4: Add justfile recipe**

Append to `justfile` (matching the style of `gen-templates`):

```
# Regenerate embedded app config schemas from bundled/manifests/
gen-app-schemas:
  dart run scripts/gen_app_config_schemas.dart
```

- [ ] **Step 5: Run the generator**

```bash
just gen-app-schemas
```

Expected: writes
`common/lib/src/services/configure/bundled/embedded_schemas.g.dart` with
five `_<name>Json` constants and a `_allAppSchemas` map.

- [ ] **Step 6: Write `registry.dart`**

```dart
// common/lib/src/services/configure/bundled/registry.dart
import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/services/configure/bundled/embedded_schemas.dart';

/// Manifests bundled in the TUI binary. In Phase 4-6 each manifest moves
/// alongside its app's Nix module into a real plugin; the AppManifest
/// shape doesn't change, only the source.
List<AppManifest> get bundledAppManifests {
  final raw = EmbeddedAppSchemas.getAll();
  // Stable order: alphabetical by id.
  final list = raw.values.map(AppManifest.fromJsonString).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(list);
}
```

- [ ] **Step 7: Write `registry_test.dart`**

```dart
// common/test/services/configure/bundled/registry_test.dart
import 'package:common/src/services/configure/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledAppManifests', () {
    test('contains all five apps in stable order', () {
      final ids = bundledAppManifests.map((m) => m.id).toList();
      expect(ids, ['bitcoind', 'blitz_api', 'blitz_web', 'cln', 'lnd']);
    });

    test('each manifest has a non-empty label', () {
      for (final m in bundledAppManifests) {
        expect(m.label.isNotEmpty, isTrue, reason: 'app=${m.id}');
      }
    });

    test('lnd + cln have lightning_backend capability', () {
      final lnApps = bundledAppManifests
          .where((m) => m.capabilities.contains('lightning_backend'))
          .map((m) => m.id)
          .toSet();
      expect(lnApps, {'lnd', 'cln'});
    });

    test('cln resolves to clightning unit name', () {
      final cln = bundledAppManifests.firstWhere((m) => m.id == 'cln');
      expect(cln.unitName, 'clightning');
    });
  });
}
```

- [ ] **Step 8: Run tests + trio + commit**

```bash
cd common && dart test test/services/configure/bundled/
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(configure): codegen + registry for bundled app manifests

scripts/gen_app_config_schemas.dart embeds the five bundled JSON
manifests into a generated .g.dart, mirroring the dashboard pattern
from Phase 1. registry.dart parses them at TUI startup and exposes a
sorted bundledAppManifests list (alphabetical by id). Just recipe
gen-app-schemas regenerates on manifest edits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `AppManifestRegistry` + Riverpod provider

**Files:**

- Create: `common/lib/src/services/configure/app_manifest_registry.dart`
- Create: `common/lib/src/providers/app_manifest_registry_provider.dart`
- Test: `common/test/services/configure/app_manifest_registry_test.dart`

**Spec reference:** "AppManifestRegistry" section.

- [ ] **Step 1: Write failing tests**

```dart
// common/test/services/configure/app_manifest_registry_test.dart
import 'package:common/src/models/configure/app_config_field.dart';
import 'package:common/src/models/configure/app_manifest.dart';
import 'package:common/src/services/configure/app_manifest_registry.dart';
import 'package:test/test.dart';

AppManifest _m(String id, {Set<String> caps = const {}, String? unit}) =>
    AppManifest(
      id: id,
      label: id,
      capabilities: caps,
      fields: const [],
      serviceUnit: unit,
    );

void main() {
  group('AppManifestRegistry', () {
    test('allApps combines bundled + plugin', () {
      final r = AppManifestRegistry(
        bundled: [_m('a'), _m('b')],
        plugin: [_m('c')],
      );
      expect(r.allApps.map((m) => m.id).toSet(), {'a', 'b', 'c'});
    });

    test('get(id) returns the matching manifest or null', () {
      final r = AppManifestRegistry(
        bundled: [_m('a')],
        plugin: const [],
      );
      expect(r.get('a')?.id, 'a');
      expect(r.get('missing'), isNull);
    });

    test('withCapability filters', () {
      final r = AppManifestRegistry(
        bundled: [
          _m('lnd', caps: {'lightning_backend'}),
          _m('cln', caps: {'lightning_backend'}),
          _m('bitcoind'),
        ],
        plugin: const [],
      );
      final ln = r.withCapability('lightning_backend').map((m) => m.id).toSet();
      expect(ln, {'lnd', 'cln'});
      expect(r.withCapability('bitcoin_node'), isEmpty);
    });

    test('serviceIds returns unit names (honouring service_unit override)', () {
      final r = AppManifestRegistry(
        bundled: [
          _m('cln', unit: 'clightning'),
          _m('lnd'),
        ],
        plugin: const [],
      );
      expect(r.serviceIds().toSet(), {'clightning', 'lnd'});
    });

    test('allApps unmodifiable', () {
      final r = AppManifestRegistry(bundled: [_m('a')], plugin: const []);
      expect(() => r.allApps.add(_m('b')), throwsUnsupportedError);
    });
  });
}
```

- [ ] **Step 2: Implement `app_manifest_registry.dart`**

```dart
// common/lib/src/services/configure/app_manifest_registry.dart
import 'package:common/src/models/configure/app_manifest.dart';

class AppManifestRegistry {
  final List<AppManifest> _all;

  AppManifestRegistry({
    required List<AppManifest> bundled,
    required List<AppManifest> plugin,
  }) : _all = [...bundled, ...plugin];

  List<AppManifest> get allApps => List.unmodifiable(_all);

  AppManifest? get(String id) {
    for (final m in _all) {
      if (m.id == id) return m;
    }
    return null;
  }

  List<AppManifest> withCapability(String tag) =>
      _all.where((m) => m.capabilities.contains(tag)).toList();

  /// systemd unit names for every app in the registry (honouring
  /// `service_unit` override).
  List<String> serviceIds() => _all.map((m) => m.unitName).toList();
}
```

- [ ] **Step 3: Implement Riverpod provider**

```dart
// common/lib/src/providers/app_manifest_registry_provider.dart
import 'package:riverpod/riverpod.dart';

import 'package:common/src/services/configure/app_manifest_registry.dart';
import 'package:common/src/services/configure/bundled/registry.dart';

/// Combined bundled + plugin app manifests.
/// Plugin manifests come from installed plugins that declare a
/// config_schema (Task 5 wires this up). For Phase 3's initial commit,
/// the plugin list is empty; Task 5 populates it.
final appManifestRegistryProvider = Provider<AppManifestRegistry>((ref) {
  return AppManifestRegistry(
    bundled: bundledAppManifests,
    plugin: const [],   // Task 5: read from pluginConfigService
  );
});
```

- [ ] **Step 4: Run tests + trio + commit**

```bash
cd common && dart test test/services/configure/app_manifest_registry_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(configure): AppManifestRegistry + Riverpod provider

Combines bundled manifests (Tasks 2-3) with plugin-shipped manifests
(populated in Task 5). Query API: allApps, get(id), withCapability(tag),
serviceIds() (honouring service_unit override).

The plugin list is empty for now; Task 5 hooks it up to
pluginConfigService.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Plugin manifest `config_schema` integration

**Files:**

- Modify: `common/lib/src/models/plugin_manifest.dart` — add optional `configSchema` field
- Modify: `common/lib/src/providers/app_manifest_registry_provider.dart` — populate the plugin list
- Test: `common/test/models/plugin_manifest_test.dart` — add cases for `config_schema` parsing

**Spec reference:** "Plugin manifest integration" section.

- [ ] **Step 1: Read existing PluginManifest**

```bash
grep -n 'class PluginManifest\|fromJson\|configSchema\|config_schema' common/lib/src/models/plugin_manifest.dart | head -20
```

- [ ] **Step 2: Add `configSchema` to PluginManifest**

Add a nullable `AppManifest? configSchema` field. In `fromJson`, parse the optional `config_schema` key if present, propagating the plugin's `id` into the resulting AppManifest:

```dart
// In PluginManifest:
final AppManifest? configSchema;

// In fromJson (after reading id, name, etc.):
final csRaw = json['config_schema'];
AppManifest? configSchema;
if (csRaw is Map) {
  // Inject id from outer manifest if absent in config_schema
  final csJson = Map<String, dynamic>.from(csRaw)..putIfAbsent('id', () => id);
  configSchema = AppManifest.fromJson(csJson);
}
```

- [ ] **Step 3: Add tests for `config_schema` parsing**

```dart
// In plugin_manifest_test.dart, extend:
test('plugin without config_schema parses fine', () {
  final m = PluginManifest.fromJson({
    'id': 'p', 'name': 'P', 'version': '1.0.0',
    // no config_schema
  });
  expect(m.configSchema, isNull);
});

test('plugin with config_schema parses + inherits id', () {
  final m = PluginManifest.fromJson({
    'id': 'p',
    'name': 'P',
    'version': '1.0.0',
    'config_schema': {
      'label': 'P',
      'fields': [
        {'name': 'enabled', 'type': 'bool', 'label': 'Enabled', 'default': false},
      ],
    },
  });
  expect(m.configSchema, isNotNull);
  expect(m.configSchema!.id, 'p');
});
```

- [ ] **Step 4: Wire plugin manifests into the registry provider**

In `app_manifest_registry_provider.dart`:

```dart
import 'package:common/src/providers/plugin_provider.dart';

final appManifestRegistryProvider = Provider<AppManifestRegistry>((ref) {
  final plugins = ref.watch(pluginListProvider);   // adapt to actual provider
  final pluginManifests = plugins
      .map((p) => p.configSchema)
      .whereType<AppManifest>()
      .toList();
  return AppManifestRegistry(
    bundled: bundledAppManifests,
    plugin: pluginManifests,
  );
});
```

(Adapt `pluginListProvider` to whatever the actual plugin-list provider is —
look for `plugin_provider.dart` or `plugin_config_provider.dart`.)

- [ ] **Step 5: Run tests + trio + commit**

```bash
cd common && dart test test/models/plugin_manifest_test.dart
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(configure): plugin manifest gains optional config_schema

PluginManifest can now declare a config_schema using the same
AppManifest shape as the bundled apps. Plugins without it keep
their opaque-config status. The AppManifestRegistry provider
now combines bundled manifests with plugin-shipped ones, so
Phase 4-6 plugin extraction lifts the config UI for free.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Generic `FieldEditor` widget

**Files:**

- Create: `tui/lib/src/ui/views/configure/field_editor.dart`
- Test: `tui/test/ui/views/configure/field_editor_test.dart`
- Read: `tui/lib/src/ui/widgets/option_editor.dart` (existing primitive editors to reuse)

**Spec reference:** "Generic field editors" section.

- [ ] **Step 1: Survey existing editor primitives**

```bash
grep -n 'class.*Editor' tui/lib/src/ui/widgets/option_editor.dart
```

The existing configure_view uses helpers for toggle, text edit, numeric edit, and select. Identify them; the generic dispatcher reuses these.

- [ ] **Step 2: Implement `field_editor.dart`**

```dart
// tui/lib/src/ui/views/configure/field_editor.dart
import 'package:common/src/models/configure/app_config_field.dart';
import 'package:nocterm/nocterm.dart';
import 'package:tui/src/ui/widgets/option_editor.dart';   // existing primitives

/// Read-only display row for one field's current value (label + value).
/// The actual editing flow uses the existing OptionEditor / SelectOptionEditor
/// chain, just dispatched per field type.
class FieldDisplayRow extends StatelessComponent {
  final AppConfigField field;
  final dynamic currentValue;
  final bool selected;
  final bool pending;
  const FieldDisplayRow({
    required this.field,
    required this.currentValue,
    this.selected = false,
    this.pending = false,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final value = _formatValue(field, currentValue);
    final marker = pending ? '* ' : (selected ? '> ' : '  ');
    return Text('$marker${field.label.padRight(20)} : $value');
  }
}

String _formatValue(AppConfigField field, dynamic value) {
  return switch (field) {
    BoolField()   => (value as bool? ?? field.defaultValue) ? 'on' : 'off',
    StringField() => (value as String? ?? field.defaultValue),
    IntField()    => '${value as int? ?? field.defaultValue}',
    EnumField()   => (value as String? ?? field.defaultValue),
  };
}

/// Resolve a field-edit invocation into the appropriate editor.
/// Returns the new field value, or null if the user cancelled.
Future<dynamic> editField({
  required BuildContext context,
  required AppConfigField field,
  required dynamic currentValue,
}) async {
  switch (field) {
    case BoolField():
      return !(currentValue as bool? ?? field.defaultValue);
    case StringField():
      // Reuse existing _textEdit flow from configure_view (extract or call).
      return await editStringField(
        context,
        currentValue as String? ?? field.defaultValue,
        placeholder: field.placeholder,
      );
    case IntField():
      return await editIntField(
        context,
        currentValue as int? ?? field.defaultValue,
        min: field.min,
        max: field.max,
      );
    case EnumField():
      return await editEnumField(
        context,
        currentValue as String? ?? field.defaultValue,
        choices: field.choices,
      );
  }
}
```

The `editStringField`, `editIntField`, `editEnumField` helpers either come
from existing `option_editor.dart` (rename/expose them) or are extracted
from configure_view's current internal helpers. Reuse, don't reinvent.

- [ ] **Step 3: Write tests**

```dart
// tui/test/ui/views/configure/field_editor_test.dart
import 'package:common/src/models/configure/app_config_field.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/configure/field_editor.dart';

void main() {
  group('_formatValue (smoke; private but tested via FieldDisplayRow)', () {
    // The function is private; test it indirectly via the widget's
    // build output, OR mark it @visibleForTesting and import it.
    // Use NoctermTester or a simpler snapshot of the built widget tree.
  });

  // Additional tests as needed for editField — mostly mock-driven since
  // the editor flows depend on UI state.
}
```

(Tests for editField specifically are tricky without a TUI tester; rely on
the existing configure_view tests in Task 7 to exercise the integrated
flow. Phase 3 unit tests for FieldEditor are best-effort.)

- [ ] **Step 4: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
feat(configure): generic FieldEditor dispatcher

FieldDisplayRow renders a manifest-declared field as one row with
label + current value. editField() dispatches to the appropriate
editor (toggle / text / int / enum) based on AppConfigField subtype,
reusing the existing OptionEditor primitives.

Phase 3 Task 7 will replace configure_view's per-app switch tree
with a generic walker over manifest fields driving these dispatchers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `configure_view.dart` rewrite

**Files:**

- Modify (substantial rewrite): `tui/lib/src/ui/views/configure_view.dart`
- Modify: `tui/test/ui/views/configure_view_test.dart` (or create — adapt to existing tests)

**Spec reference:** "configure_view.dart rewrite" section.

This is the largest single rewrite in Phase 3. The 900-line per-app switch tree is replaced with a generic walker driven by the registry.

- [ ] **Step 1: Read current configure_view structure**

```bash
wc -l tui/lib/src/ui/views/configure_view.dart
grep -n 'case .bitcoind\|case .lnd\|case .cln\|case .blitz\|services =' tui/lib/src/ui/views/configure_view.dart | head -20
```

Identify:

- The hardcoded services list
- Each per-app switch case
- The text-edit and toggle flows
- Pending-change tracking
- The system block (stays as-is — typed)

- [ ] **Step 2: Rewrite the services menu source**

Replace the hardcoded `services = ['system', 'bitcoind', ...]` list with:

```dart
final registry = context.watch(appManifestRegistryProvider);
final menuEntries = [
  _MenuEntry.system(),
  for (final m in registry.allApps) _MenuEntry.fromManifest(m),
  _MenuEntry.plugins(),
];
```

`_MenuEntry` is a small sum type that holds either:

- the system block sentinel
- an `AppManifest`
- the plugins screen sentinel

The menu rendering uses `entry.label` for display.

- [ ] **Step 3: Rewrite the per-entry rendering**

The big change: when the user selects an `_MenuEntry.fromManifest(m)`, render
its fields generically:

```dart
// Old: switch tree with case 'bitcoind': ... case 'lnd': ...
// New:
final manifest = selectedEntry.manifest;
final config = ref.read(configProvider).value;
final appConfig = config.appConfig(manifest.id);

return Column(children: [
  for (final field in manifest.fields)
    FieldDisplayRow(
      field: field,
      currentValue: appConfig[field.name],
      selected: field.name == _selectedFieldName,
      pending: _isPending(manifest.id, field.name),
    ),
]);
```

When the user activates a field (Enter), call `editField()` from Task 6's
dispatcher and write back via `setAppOption(manifest.id, field.name, newValue)`.

The `system` block keeps its existing typed editor (don't generalise it).
The `plugins` screen keeps its existing flow.

- [ ] **Step 4: Update / adapt existing tests**

```bash
ls tui/test/ui/views/configure_view*
```

If there's an existing test, it likely asserts specific menu items and field
behaviours. Adapt to the new generic flow:

- Menu order matches registry order (alphabetical by id, with system + plugins
  pinned)
- Toggling each app's `enabled` updates the config via `setAppOption`
- Bitcoind's network choice cycles through the manifest's choices

- [ ] **Step 5: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
refactor(configure): manifest-driven configure_view (drops 900-line switch tree)

Configure menu populated from AppManifestRegistry; per-entry rendering
walks the manifest's fields and dispatches to the generic FieldEditor.
Pending-change tracking, cancel/apply semantics, system + plugins
blocks all preserved.

The view's structural coupling to the five named apps is gone —
adding a new app (or installing a plugin with config_schema)
auto-populates the menu without touching the view code.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Install wizard refactor

**Files:**

- Modify: `tui/lib/src/ui/views/install_view.dart`
- Test: `tui/test/ui/views/install_view_test.dart` (extend existing)

**Spec reference:** "Install wizard refactor" section.

- [ ] **Step 1: Find the LightningChoice block**

```bash
grep -n '_LightningChoice\|LightningChoice\|lightning' tui/lib/src/ui/views/install_view.dart | head -20
```

- [ ] **Step 2: Replace `_LightningChoice` enum with manifest-driven choices**

```dart
// Old:
enum _LightningChoice { lnd, cln, none }

// New:
@immutable
class _LightningChoice {
  final String? appId;     // null means "no LN backend"
  final String label;
  const _LightningChoice({this.appId, required this.label});
  bool get isNone => appId == null;
}

// Build choices from registry:
final registry = context.read(appManifestRegistryProvider);
final lnApps = registry.withCapability('lightning_backend');
final lnChoices = [
  ...lnApps.map((m) => _LightningChoice(appId: m.id, label: m.label)),
  const _LightningChoice(appId: null, label: 'None'),
];
```

The wizard's apply path already uses `setAppOption` (from Phase 2). Update it
to write per choice: enable the chosen app, disable the others:

```dart
config = config;
for (final m in lnApps) {
  config = config.setAppOption(m.id, 'enabled', m.id == chosen.appId);
}
```

- [ ] **Step 3: Bitcoin network choice — read from manifest**

```dart
// Old: hardcoded list
final networks = ['mainnet', 'testnet', 'regtest', 'signet'];

// New: from manifest, with fallback if missing
final networkField = registry.get('bitcoind')?.field('network');
final networks = networkField is EnumField
    ? networkField.choices
    : const ['mainnet', 'testnet', 'regtest', 'signet'];
```

If `bitcoind` isn't in the registry (true homelab base case), the wizard's
network step can be skipped. Phase 3 keeps it (bitcoind IS in the registry
as a bundled manifest), but the code structure works in both cases.

- [ ] **Step 4: Run tests + trio + commit**

```bash
cd tui && dart test test/ui/views/install_view_test.dart 2>&1 | tail -10
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
refactor(install): wizard discovers LN backends from manifest registry

_LightningChoice no longer hardcodes lnd/cln; reads
withCapability('lightning_backend') from AppManifestRegistry. Bitcoin
network choice reads from the bitcoind manifest's network field's
choices. Phases 6 (lnd/cln plugins) inherit the wizard's discovery
for free.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Debug views + `system_service.dart` registry hookup

**Files:**

- Modify: `common/lib/src/services/system_service.dart`
- Modify: `tui/lib/src/ui/views/debug/service_health.dart`
- Modify: `tui/lib/src/ui/views/debug/tail_log.dart`
- Test: `common/test/services/system_service_test.dart` (if exists, adapt)

**Spec reference:** "Debug views service-list registry hookup" section.

- [ ] **Step 1: Find the hardcoded service lists**

```bash
grep -nE "'bitcoind'|'lnd'|'clightning'|'cln'|'blitz" \
  common/lib/src/services/system_service.dart \
  tui/lib/src/ui/views/debug/service_health.dart \
  tui/lib/src/ui/views/debug/tail_log.dart
```

- [ ] **Step 2: Update `system_service.dart`**

```dart
// Add a parameter or read from a provider — depends on how the service
// is instantiated. If it has a constructor:
class SystemService {
  final List<String> serviceUnits;
  SystemService({required this.serviceUnits});

  Future<Map<String, ServiceState>> getAllServiceStatuses() async {
    final result = <String, ServiceState>{};
    for (final unit in serviceUnits) {
      result[unit] = await _checkUnit(unit);
    }
    return result;
  }
}
```

If `SystemService` is provided via Riverpod, update its provider to read
the unit list from the registry:

```dart
final systemServiceProvider = Provider<SystemService>((ref) {
  final registry = ref.watch(appManifestRegistryProvider);
  return SystemService(serviceUnits: registry.serviceIds());
});
```

(Adapt to the actual existing structure.)

- [ ] **Step 3: Update debug views**

Both `service_health.dart` and `tail_log.dart` should iterate
`registry.serviceIds()` (or read from `systemServiceProvider`'s service list)
instead of their hardcoded `['bitcoind', 'lnd', 'clightning']`.

- [ ] **Step 4: Trio + commit**

```bash
just test && just analyze && just format
jj commit -m "$(cat <<'EOF'
refactor(debug): service list from manifest registry

system_service.getAllServiceStatuses, debug/service_health, and
debug/tail_log all read the service-unit list from
AppManifestRegistry.serviceIds() (which honours the cln→clightning
service_unit override) instead of their hardcoded lists.

Adding a new app (bundled or plugin) automatically appears in the
debug views' service polling without touching the views.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Manual smoke + final trio

**Files:** none (verification only).

- [ ] **Step 1: Final trio**

```bash
just test && just analyze && just format
```

All three green.

- [ ] **Step 2: Smoke the Configure view**

In a VM or on the Pi 5:

- Configure menu shows: System, bitcoind, blitz_api, blitz_web, cln, lnd, Plugins (alphabetical by id, with System + Plugins pinned).
- Each app's page renders its manifest fields in declaration order.
- Toggling `enabled` works; cancel returns to the list with no change; Apply commits the change.
- bitcoind network cycles through mainnet/testnet/regtest/signet.
- lnd alias text-edit works.
- bitcoind prune_size_gb int-edit honours min=0.

- [ ] **Step 3: Smoke the install wizard**

Fresh install path:

- Wizard's lightning step presents LND, Core Lightning, None.
- Choosing LND writes `app_configs.lnd.enabled = true`,
  `app_configs.cln.enabled = false`.
- Choosing CLN writes the inverse.
- Choosing None writes both `false`.
- Bitcoin network step shows mainnet/testnet/regtest/signet.

- [ ] **Step 4: Smoke debug views**

- Debug → Service Health shows all 5 services (regardless of enabled state),
  using the right unit names (`clightning` for cln, not `cln`).
- Debug → Tail Log can pick any of those services.

- [ ] **Step 5: No commit needed unless capturing a screenshot/asciinema**

```bash
# Optional asciinema capture for the spec's record:
# jj commit -m "docs(configure): asciinema snapshot post-Phase-3"
```

---

## Self-review

**Spec coverage:**

| Spec section                               | Implementing task |
| ------------------------------------------ | ----------------- |
| `AppConfigField` sealed class + 4 subtypes | Task 1            |
| `AppManifest` model + parser               | Task 1            |
| 5 bundled manifest JSON files              | Task 2            |
| Codegen + bundled registry                 | Task 3            |
| `AppManifestRegistry` + provider           | Task 4            |
| Plugin `config_schema` integration         | Task 5            |
| Generic `FieldEditor` dispatcher           | Task 6            |
| `configure_view.dart` rewrite              | Task 7            |
| Install wizard capability discovery        | Task 8            |
| Debug views service-list hookup            | Task 9            |
| `system_service.dart` registry hookup      | Task 9            |
| `cln` → `clightning` service_unit override | Tasks 2, 4, 9     |
| Manual smoke                               | Task 10           |

All spec sections covered.

**Type consistency:** `AppManifest`, `AppConfigField`, `BoolField`,
`StringField`, `IntField`, `EnumField`, `AppManifestError`,
`AppManifestRegistry` — names consistent across tasks. Method names
(`get`, `withCapability`, `serviceIds`, `field`, `unitName`,
`fromJsonString`, `fromJson`) match across tasks. JSON keys match
between spec, manifests, and parser (snake_case in JSON, camelCase in
Dart).

**Placeholder scan:** every code step shows complete code. No "TBD" /
"similar to" / "implement later." `editStringField` / `editIntField` /
`editEnumField` in Task 6 are described as "reuse / extract from
existing helpers" — that's an instruction, not a placeholder; the
implementer reads existing code to find the right primitives.

**Trio gate per task:** every task ends green. No mid-stream-red episodes
unlike Phase 2 (Phase 3's incremental nature allows clean shipping per
task).

---

## Plan complete

Saved to: `docs/superpowers/plans/2026-05-06-ui-generalization.md`
