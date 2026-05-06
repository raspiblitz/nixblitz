# UI Generalization — Phase 3 Design

**Date:** 2026-05-06
**Status:** Draft
**Tracking:** Phase 3 of "extract bitcoind/lnd/cln/blitz-api/blitz-web into plugins"

## Goal

Replace the structural hardcoding in `configure_view.dart` (900-line per-app
switch tree), the install wizard's `_LightningChoice` enum, and the debug
views' hardcoded service list with **manifest-driven** discovery and
rendering.

After Phase 3:

- Each of the 5 bundled apps (bitcoind, lnd, cln, blitz-api, blitz-web) ships
  a JSON manifest declaring its configurable fields and capability tags.
- `configure_view` renders any app's schema generically — adding a new app
  doesn't require touching the view code.
- The install wizard discovers LN-capable apps via a `lightning_backend`
  capability tag.
- The debug views' service list comes from the same manifest registry.
- Plugin manifests gain an optional `config_schema` section using the same
  shape, so Phase 4+ plugin extraction lifts the manifest unchanged.

## Non-goals (deferred)

- **Generalising `templates/hosts/installed.nix`.** The Nix template's
  `features.apps.bitcoind.network = appOpt "bitcoind" "network" "mainnet"`
  wiring is module-coupled; can't generalise without moving the per-app
  NixOS modules into plugins. That's Phases 4–6.
- **Moving any app to a real plugin.** Phase 3 is Dart-side UI only.
  Bundled-app manifests live in core under
  `common/lib/src/services/configure/bundled/`. Phases 4–6 lift each
  manifest into its plugin alongside the Nix module.
- **Plugin install lifecycle changes.** Plugins still install/refresh/pin
  exactly as before. Only the manifest _schema_ gains a `config_schema`
  section; plugins without it keep their opaque-config status (the same
  raw-JSON editing they have today, if any).
- **System config generalisation.** `SystemConfig` stays typed — always-on
  identity, dashboard chrome reads it directly. Not part of the per-app
  generalisation.
- **Editing arbitrary nested config.** Phase 3 supports flat fields under an
  app key. Nested objects (e.g. `bitcoind.rpc.bind`) are deferred until a
  real plugin actually needs them.

## Architecture

### Today

```
configure_view.dart  (~900 lines)
  ├── hardcoded services menu: ['system', 'bitcoind', 'lnd', 'cln',
  │                              'blitz-api', 'blitz-web', 'plugins']
  └── per-service switch tree:
        case 'bitcoind':
          renders specific options with specific editors
        case 'lnd': …
        case 'cln': …
        case 'blitz-api': …
        case 'blitz-web': …

install_view.dart
  └── _LightningChoice { lnd, cln, none }   (hardcoded enum)

system_service.dart
  └── getAllServiceStatuses uses ['bitcoind', 'lnd', 'clightning']
debug/{tail_log,service_health}.dart
  └── same hardcoded service list
```

### After Phase 3

```
common/lib/src/services/configure/bundled/manifests/
  ├── bitcoind.json
  ├── lnd.json
  ├── cln.json
  ├── blitz_api.json
  └── blitz_web.json
        each declares: id, label, capabilities[], fields[]

AppManifestRegistry
  ├── bundledManifests   (the 5 above)
  ├── pluginManifests    (from installed plugins, if they declare config_schema)
  └── query API:
        - allApps() → List<AppManifest>
        - get(id) → AppManifest?
        - withCapability(tag) → List<AppManifest>

configure_view.dart  (rewritten)
  ├── services menu populated from registry.allApps()
  └── for each app: walk its fields[], emit a primitive editor per field

install_view.dart
  ├── wizard's lightning step calls registry.withCapability('lightning_backend')
  └── presents […apps] + 'none' as choices

system_service.dart + debug views
  └── service list read from registry
```

## Schema design

### `AppManifest` (JSON shape)

```jsonc
{
  "id": "bitcoind",
  "label": "Bitcoin Core",
  "description": "The Bitcoin reference client",
  "capabilities": [],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
    {
      "name": "network",
      "type": "enum",
      "label": "Network",
      "choices": ["mainnet", "testnet", "regtest", "signet"],
      "default": "mainnet",
    },
    { "name": "pruned", "type": "bool", "label": "Pruned", "default": false },
    {
      "name": "prune_size_gb",
      "type": "int",
      "label": "Prune Size (GB)",
      "default": 0,
      "min": 0,
    },
  ],
}
```

`capabilities` is an array of strings; query API supports lookup by tag.
`lightning_backend` is the one defined in Phase 3; future capabilities
(`bitcoin_node`, `web_ui`, etc.) can land as needed.

### `AppConfigField` (Dart model)

```dart
@immutable
sealed class AppConfigField {
  final String name;        // matches JSON key in NixblitzConfig.appConfigs[id]
  final String label;       // UI label
  final String? description;
  const AppConfigField({required this.name, required this.label, this.description});

  factory AppConfigField.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'bool'   => BoolField._fromJson(json),
      'string' => StringField._fromJson(json),
      'int'    => IntField._fromJson(json),
      'enum'   => EnumField._fromJson(json),
      _ => throw AppManifestError('unknown field type: $type'),
    };
  }
}

class BoolField extends AppConfigField {
  final bool defaultValue;
  const BoolField({required super.name, required super.label, super.description,
      required this.defaultValue});
}

class StringField extends AppConfigField {
  final String defaultValue;
  final String? placeholder;
  const StringField({required super.name, required super.label, super.description,
      required this.defaultValue, this.placeholder});
}

class IntField extends AppConfigField {
  final int defaultValue;
  final int? min, max;
  const IntField({required super.name, required super.label, super.description,
      required this.defaultValue, this.min, this.max});
}

class EnumField extends AppConfigField {
  final List<String> choices;
  final String defaultValue;
  const EnumField({required super.name, required super.label, super.description,
      required this.choices, required this.defaultValue});
}
```

`v1 type set` covers every existing field across the 5 bundled apps. Future
types (`password`, `path`, `multiline_string`) added when a real plugin
needs them.

### `AppManifest` (Dart model)

```dart
@immutable
class AppManifest {
  final String id;              // matches the JSON key in app_configs
  final String label;
  final String? description;
  final Set<String> capabilities;
  final List<AppConfigField> fields;
  final String? serviceUnit;    // systemd unit name; defaults to `id` if null

  const AppManifest({
    required this.id,
    required this.label,
    this.description,
    this.capabilities = const {},
    required this.fields,
    this.serviceUnit,
  });

  factory AppManifest.fromJson(Map<String, dynamic> json) { … }
  factory AppManifest.fromJsonString(String s) { … }

  AppConfigField? field(String name) => fields.firstWhereOrNull((f) => f.name == name);

  /// Resolved systemd unit name. Use this for service-status polling /
  /// log tailing (NOT the manifest `id`, which matches the JSON key).
  String get unitName => serviceUnit ?? id;
}
```

## Bundled-app manifests

Five JSON files at
`common/lib/src/services/configure/bundled/manifests/`:

**bitcoind.json:**

```jsonc
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
      "default": "mainnet",
    },
    {
      "name": "pruned",
      "type": "bool",
      "label": "Prune mode",
      "default": false,
    },
    {
      "name": "prune_size_gb",
      "type": "int",
      "label": "Prune size (GB)",
      "default": 0,
      "min": 0,
    },
  ],
}
```

**lnd.json:**

```jsonc
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
      "placeholder": "my-node",
    },
  ],
}
```

**cln.json:**

```jsonc
{
  "id": "cln",
  "label": "Core Lightning",
  "description": "Core Lightning (CLN) backend",
  "capabilities": ["lightning_backend"],
  "service_unit": "clightning",
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
  ],
}
```

**blitz_api.json:**

```jsonc
{
  "id": "blitz_api",
  "label": "Blitz API",
  "description": "FastAPI backend for the Blitz web frontend",
  "capabilities": [],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
  ],
}
```

**blitz_web.json:**

```jsonc
{
  "id": "blitz_web",
  "label": "Blitz Web",
  "description": "Web frontend for monitoring + managing the node",
  "capabilities": [],
  "fields": [
    { "name": "enabled", "type": "bool", "label": "Enabled", "default": false },
  ],
}
```

Embedded into the binary via codegen mirroring Phase 1's
`gen_dashboard_manifests.dart` pattern. New script
`scripts/gen_app_config_schemas.dart`; new `just gen-app-schemas` recipe (or
fold into existing `gen-templates`).

## Plugin manifest integration

The existing `PluginManifest` (in
`common/lib/src/models/plugin_manifest.dart`) gains an optional field:

```dart
class PluginManifest {
  // … existing fields …
  final AppManifest? configSchema;   // NEW — optional
  // …
}
```

JSON shape:

```jsonc
{
  "id": "my-plugin",
  "version": "1.0.0",
  // … existing keys …
  "config_schema": {
    "label": "My Plugin",
    "fields": [ … ]
  }
}
```

Note the `id` is omitted inside `config_schema` (the plugin's `id` is
already the outer key). When parsed, `AppManifest.id` is set to the
plugin's id.

Plugins without `config_schema` keep their opaque-config status — they
don't appear in the Configure menu's editable list (or appear as a
non-editable "no config schema declared" entry; small UX call).

## `AppManifestRegistry`

```dart
class AppManifestRegistry {
  final List<AppManifest> _all;

  AppManifestRegistry({
    required List<AppManifest> bundled,
    required List<AppManifest> plugin,
  }) : _all = [...bundled, ...plugin];

  List<AppManifest> get allApps => List.unmodifiable(_all);
  AppManifest? get(String id) => _all.firstWhereOrNull((m) => m.id == id);
  List<AppManifest> withCapability(String tag) =>
      _all.where((m) => m.capabilities.contains(tag)).toList();
  List<String> serviceIds() => _all.map((m) => m.id).toList();
}
```

Surfaced as `appManifestRegistryProvider` (Riverpod). Bundled list comes
from the codegen output; plugin list comes from `pluginConfigService`'s
existing manifest cache, filtered to those with a `config_schema`.

## Generic field editors

`tui/lib/src/ui/views/configure/field_editor.dart` — one generic widget
that dispatches per `AppConfigField` subtype:

- `BoolField` → toggle (Enter / Space flips)
- `StringField` → existing `_textEdit` flow with placeholder
- `IntField` → existing numeric editor with min/max bounds
- `EnumField` → existing `SelectOptionEditor` over `choices`

The current configure_view already has these primitive editors hardcoded
inline; Phase 3 extracts them into the generic dispatcher and the per-app
switch tree disappears.

## `configure_view.dart` rewrite

After:

```dart
@override
Component build(BuildContext context) {
  final registry = context.watch(appManifestRegistryProvider);
  final config = context.watch(configProvider).value;

  // Top-level menu: 'system' + each app from the registry + 'plugins'
  final entries = [
    _ServiceMenuEntry.system(),
    ...registry.allApps.map(_ServiceMenuEntry.fromManifest),
    _ServiceMenuEntry.plugins(),
  ];

  // Render the menu, then for the selected entry render its fields
  // generically via the field-editor dispatcher.
  // …
}
```

The 900-line switch tree collapses to a generic walker that reads the
selected app's manifest, iterates its `fields[]`, and renders an editor
per field. Pending-change tracking, cancel/apply semantics, and the
`system` block (which keeps its typed editor) all preserved.

## Install wizard refactor

`install_view.dart` currently has:

```dart
enum _LightningChoice { lnd, cln, none }
```

Replace with:

```dart
final lnApps = registry.withCapability('lightning_backend');
final lnChoices = [
  ...lnApps.map((m) => LightningChoice(id: m.id, label: m.label)),
  const LightningChoice.none(),
];
```

The wizard's apply step writes via `setAppOption` (already done in Phase 2);
only the choice-presentation logic changes. Network choice for bitcoind also
discovers from the registry: `registry.get('bitcoind')?.field('network')` → if
present, present its `choices`; otherwise the wizard skips the network step
(consistent with the homelab base case where bitcoind isn't configured).

## Debug views service-list registry hookup

`common/lib/src/services/system_service.dart`'s
`getAllServiceStatuses()` currently has hardcoded
`['bitcoind', 'lnd', 'clightning']`. Replace with the registry's
`serviceIds()`. Edge case: `cln` in our manifest maps to `clightning` in
systemd. Two options:

- **(a)** Manifest `id` matches the systemd unit name (`clightning` instead
  of `cln`). Cleaner but breaks the JSON key mapping (config.json uses
  `"cln"`).
- **(b)** Manifest gains an optional `service_unit` field that defaults to
  `id` if absent. CLN's manifest declares `"service_unit": "clightning"`.

_Recommend (b)._ Keeps JSON keys readable; explicit declaration for the one
case where they differ. The Nix template wiring stays unchanged (template
already names units explicitly).

`debug/tail_log.dart` and `debug/service_health.dart` inherit the new
service list via the registry.

## File-level changes

**New:**

- `common/lib/src/models/configure/app_config_field.dart` — sealed `AppConfigField`
- `common/lib/src/models/configure/app_manifest.dart` — `AppManifest` model + parser
- `common/lib/src/services/configure/bundled/manifests/bitcoind.json`
- `common/lib/src/services/configure/bundled/manifests/lnd.json`
- `common/lib/src/services/configure/bundled/manifests/cln.json`
- `common/lib/src/services/configure/bundled/manifests/blitz_api.json`
- `common/lib/src/services/configure/bundled/manifests/blitz_web.json`
- `common/lib/src/services/configure/bundled/embedded_schemas.dart` (`part of` host)
- `common/lib/src/services/configure/bundled/embedded_schemas.g.dart` (generated)
- `common/lib/src/services/configure/bundled/registry.dart` — `bundledAppManifests` getter
- `common/lib/src/services/configure/app_manifest_registry.dart` — combined registry
- `common/lib/src/providers/app_manifest_registry_provider.dart` — Riverpod provider
- `tui/lib/src/ui/views/configure/field_editor.dart` — generic editor dispatcher
- `scripts/gen_app_config_schemas.dart` — codegen
- Tests for each of the above under `common/test/...` and `tui/test/...`

**Modified:**

- `common/lib/src/models/plugin_manifest.dart` — add optional
  `configSchema` field; tolerate manifests without it
- `tui/lib/src/ui/views/configure_view.dart` — full rewrite from switch tree
  to generic renderer
- `tui/lib/src/ui/views/install_view.dart` — wizard reads capabilities
- `common/lib/src/services/system_service.dart` — service list from registry
- `tui/lib/src/ui/views/debug/service_health.dart` — registry hookup
- `tui/lib/src/ui/views/debug/tail_log.dart` — registry hookup
- `justfile` — add `gen-app-schemas` recipe (or fold into `gen-templates`)

**Untouched:**

- `templates/hosts/installed.nix` — module-coupled wiring stays per-app
  named (Phases 4–6).
- `templates/modules/apps/*.nix` — per-app NixOS modules consume
  `features.apps.X.*` (Phases 4–6).
- `NixblitzConfig` and its generic accessors — unchanged from Phase 2.
- `scaffold_service.dart` — unchanged.

## Migration / compatibility

- **No JSON schema bump.** Phase 3 reads the existing v18 `app_configs`
  shape; the schema migration was Phase 2's job.
- **Plugins without `config_schema`** keep working unchanged. Manifest
  parser handles missing/optional field gracefully.
- **Configure view's existing keyboard model** (Enter to edit, Esc to back,
  pending-change tracking) preserved verbatim. Internals change; UX same.

## Testing strategy

### Schema parser

- `app_manifest_test.dart`: round-trip the 5 bundled manifests through
  `fromJsonString` + `toJson`. Check id, label, capabilities, field list
  preserved.
- `app_config_field_test.dart`: each field type's parser handles its `type`
  string, default value, optional metadata. Unknown types throw
  `AppManifestError`.
- Edge cases: missing required fields (`name`, `label`, `type`), bad enum
  default (default not in choices), out-of-range int defaults.

### Registry

- `app_manifest_registry_test.dart`: bundled-only construction; bundled +
  plugin combination; `get(id)` for present + missing; `withCapability`
  matches sets correctly; `serviceIds()` returns the union.

### Field editors

- `field_editor_test.dart`: each editor type renders its primitive (toggle,
  text, int, enum). Editing produces correct `setAppOption` calls.

### Configure view

- `configure_view_test.dart`: the rewritten view's services menu mirrors the
  registry. Each app's fields render in declaration order. Toggling a field
  updates the config via the generic API. Pending-change indicator works.
  System block still has its typed editor.

### Install wizard

- `install_view_test.dart`: `LightningChoice` discovery returns the
  manifests with `lightning_backend` capability. Bitcoin network choice
  reads from manifest. Apply path uses generic API (already covered by
  Phase 2 tests).

### Debug views

- `service_health_test.dart`: service list comes from registry. Adding a
  manifest entry would make it appear (with the appropriate `service_unit`
  override).

### Manual smoke

- All 5 apps' Configure pages render correctly (fields in expected order
  and types).
- Toggle each app's `enabled` and Apply succeeds.
- Bitcoind network choice still works.
- Install wizard's lightning choice presents lnd + cln + none.
- Debug → service health shows all 5 services (regardless of
  enabled/disabled state).

## Verification

```bash
just test
just analyze
just format
```

All green. Plus a Pi 5 / VM smoke covering the manual cases above.

## Phasing handoff

| Phase               | Work                                                                                                                                                                  | Depends on |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| **3** _(this spec)_ | UI generalisation: bundled-app manifests, registry, generic Configure view, install wizard capabilities, debug views                                                  | 1, 2       |
| 4                   | Move blitz-api Nix module into a plugin; rip out InProcessAdapterSource; ship blitz-api-bridge as subprocess streamer; lift `blitz_api.json` manifest into the plugin | 1, 2, 3    |
| 5                   | Move blitz-web Nix module into a plugin; lift its manifest                                                                                                            | 2, 3, 4    |
| 6                   | Move lnd, cln Nix modules into plugins; lift their manifests; install wizard's `lightning_backend` capability discovery now finds plugin-shipped manifests            | 2, 3, 4    |
| later               | Move bitcoind into a plugin (last; transitively depended on by all LN/api plugins). Plugin dependency declarations probably formalise here.                           | 4, 5, 6    |

After Phase 3 alone, no user-visible UX change beyond polish — same
Configure menu, same wizard flow, same debug views. The big internal
payoff: Phases 4–6 only need to lift manifest files; no UI code touches.

## Decisions (locked in 2026-05-06)

1. **Bundled-app manifests live in core JSON files** at
   `common/lib/src/services/configure/bundled/manifests/`. Codegen via
   `scripts/gen_app_config_schemas.dart`. Lifts into plugins in
   Phases 4–6.
2. **Plugin manifests gain optional `config_schema`.** Same shape as
   bundled-app manifests. Plugins without it keep their opaque-config
   status.
3. **v1 field types: `bool`, `string`, `int`, `enum<choices>`.** Each
   declares `name`, `label`, `default`, plus type-specific metadata
   (`choices` for enum, `min`/`max` for int, `placeholder` for string).
4. **Capability tags drive the install wizard's choice discovery.**
   `lightning_backend` is the one capability defined in Phase 3;
   `lnd.json` and `cln.json` declare it. Wizard queries
   `registry.withCapability('lightning_backend')`.
5. **Service unit name override** (`service_unit` field on `AppManifest`)
   handles the `cln` → `clightning` mismatch. Optional; defaults to `id`.
6. **System config stays typed.** Always-on identity, dashboard chrome
   reads it directly. Unchanged from Phase 2.
7. **Nix template stays module-coupled.** `installed.nix` reads per-app
   field names by hand (`appOpt "bitcoind" "network" "mainnet"`); can't
   generalise until Phases 4–6 actually move the modules into plugins.
