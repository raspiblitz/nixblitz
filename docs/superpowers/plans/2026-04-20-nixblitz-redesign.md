# NixBlitz Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 6-crate Rust workspace with a Dart TUI + dendritic NixOS modules, enabling Bitcoin/Lightning node setup and configuration over SSH without touching Nix.

**Architecture:** Dart workspace with two packages (`common` for business logic, `tui` for UI). The TUI manages a git-tracked `~/nixblitz/` directory containing `config.json` and NixOS modules that use the dendritic auto-discovery pattern from the folio example. System commands (`disko`, `nixos-rebuild`, `systemctl`, `git`) are called via `Process.start()` exclusively from the `common` package.

**Tech Stack:** Dart 3.11+, nocterm (TUI framework), Riverpod (state management), Nix flakes, dendritic NixOS module pattern

**Reference examples:**
- `examples_redesign/port_surgeon/` — Dart TUI patterns
- `examples_redesign/folio/` — Dendritic NixOS module pattern
- `examples_redesign/radrss/frontend/` — Dart workspace structure
- `examples_redesign/nocterm/` — Nocterm framework source

---

## File Map

### Dart Workspace Root
- Create: `pubspec.yaml` — workspace definition
- Create: `analysis_options.yaml` — shared lint rules

### common package
- Create: `common/pubspec.yaml`
- Create: `common/lib/common.dart` — barrel export
- Create: `common/lib/src/models/nixblitz_config.dart` — typed config model
- Create: `common/lib/src/models/service_status.dart` — systemctl status model
- Create: `common/lib/src/services/config_service.dart` — JSON read/write
- Create: `common/lib/src/services/git_service.dart` — git init/commit/revert
- Create: `common/lib/src/services/system_service.dart` — nixos-rebuild, systemctl, disko
- Create: `common/lib/src/providers/config_provider.dart` — Riverpod provider for config
- Create: `common/lib/src/providers/service_status_provider.dart` — Riverpod provider for service status

### tui package
- Create: `tui/pubspec.yaml`
- Create: `tui/bin/nixblitz.dart` — entry point
- Create: `tui/lib/src/ui/app.dart` — root NoctermApp + Shell
- Create: `tui/lib/src/ui/views/dashboard_view.dart` — service status overview
- Create: `tui/lib/src/ui/views/configure_view.dart` — config editor
- Create: `tui/lib/src/ui/views/apply_view.dart` — nixos-rebuild progress
- Create: `tui/lib/src/ui/widgets/service_card.dart` — status indicator widget
- Create: `tui/lib/src/ui/widgets/option_editor.dart` — config option input widgets
- Create: `tui/lib/src/providers/ui_state_provider.dart` — navigation, selection, focus state

### NixOS templates (scaffolded to ~/nixblitz/ at install time)
- Create: `templates/flake.nix` — flake with findModules auto-discovery
- Create: `templates/hosts/default.nix` — reads config.json, maps to features
- Create: `templates/modules/system/base.nix` — core system config
- Create: `templates/modules/apps/bitcoind.nix` — Bitcoin daemon module
- Create: `templates/modules/apps/lnd.nix` — LND module
- Create: `templates/modules/apps/cln.nix` — Core Lightning module
- Create: `templates/modules/apps/blitz-api.nix` — Blitz API module
- Create: `templates/modules/apps/blitz-web.nix` — Blitz Web module
- Create: `templates/hardware/pi4.nix` — Raspberry Pi 4 hardware config
- Create: `templates/hardware/pi5.nix` — Raspberry Pi 5 hardware config
- Create: `templates/hardware/x86.nix` — x86_64 hardware config
- Create: `templates/hardware/vm.nix` — QEMU VM hardware config

### Nix build
- Create: `flake.nix` — builds TUI, exposes as nix package
- Create: `nix/tui_pkg.nix` — Dart application build

### Tests
- Create: `common/test/models/nixblitz_config_test.dart`
- Create: `common/test/services/config_service_test.dart`
- Create: `common/test/services/git_service_test.dart`
- Create: `common/test/services/system_service_test.dart`

---

## Task 1: Dart Workspace Scaffold

**Files:**
- Create: `pubspec.yaml`
- Create: `analysis_options.yaml`
- Create: `common/pubspec.yaml`
- Create: `common/lib/common.dart`
- Create: `tui/pubspec.yaml`
- Create: `tui/bin/nixblitz.dart`

- [ ] **Step 1: Create workspace root pubspec.yaml**

```yaml
# pubspec.yaml
name: nixblitz_workspace
publish_to: none

environment:
  sdk: ^3.11.4

workspace:
  - common
  - tui
```

- [ ] **Step 2: Create shared analysis_options.yaml**

```yaml
# analysis_options.yaml
include: package:lints/recommended.yaml
```

- [ ] **Step 3: Create common/pubspec.yaml**

```yaml
# common/pubspec.yaml
name: common
description: NixBlitz shared business logic — config, git, system operations.
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.11.4

resolution: workspace

dependencies:
  riverpod: ^3.2.1
  path: ^1.9.1

dev_dependencies:
  lints: ^6.1.0
  test: ^1.31.0
```

- [ ] **Step 4: Create common/lib/common.dart barrel export**

```dart
// common/lib/common.dart
library common;
```

- [ ] **Step 5: Create tui/pubspec.yaml**

```yaml
# tui/pubspec.yaml
name: tui
description: NixBlitz terminal user interface.
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.11.4

resolution: workspace

dependencies:
  args: ^2.7.0
  nocterm: ^0.6.0
  nocterm_riverpod:
    git:
      url: https://forge.f44.fyi/f44/nocterm
      path: packages/nocterm_riverpod
  common:
    path: ../common

dev_dependencies:
  lints: ^6.1.0
  test: ^1.31.0
```

- [ ] **Step 6: Create tui/bin/nixblitz.dart entry point**

```dart
// tui/bin/nixblitz.dart
import 'dart:io';
import 'package:args/args.dart';
import 'package:nocterm/nocterm.dart';
import 'package:tui/src/ui/app.dart';

const String version = '0.1.0';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print version information',
    );

  try {
    final results = parser.parse(arguments);

    if (results['version'] as bool) {
      print('nixblitz version: $version');
      exit(0);
    }

    runApp(const NixBlitzApp());
  } on FormatException catch (e) {
    print(e.message);
    exit(1);
  }
}
```

- [ ] **Step 7: Create minimal tui/lib/src/ui/app.dart**

```dart
// tui/lib/src/ui/app.dart
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

class NixBlitzApp extends StatelessComponent {
  const NixBlitzApp({super.key});

  @override
  Component build(BuildContext context) {
    return ProviderScope(
      child: NoctermApp(
        title: 'NixBlitz',
        theme: TuiThemeData.dark.copyWith(
          primary: const Color.fromRGB(247, 147, 26), // Bitcoin orange
          background: const Color.fromRGB(24, 24, 36),
          surface: const Color.fromRGB(36, 36, 54),
          onBackground: const Color.fromRGB(220, 220, 220),
          onSurface: const Color.fromRGB(200, 200, 200),
          onPrimary: const Color.fromRGB(0, 0, 0),
          outline: const Color.fromRGB(80, 80, 100),
          outlineVariant: const Color.fromRGB(60, 60, 80),
          selectionColor: const Color.fromRGB(80, 80, 120),
        ),
        home: const _Shell(),
      ),
    );
  }
}

class _Shell extends StatelessComponent {
  const _Shell({super.key});

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.keyQ) {
          shutdownApp();
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              decoration: const BoxDecoration(
                border: BoxBorder(
                  bottom: BorderSide(color: Color.fromRGB(80, 80, 100)),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'NIXBLITZ',
                    style: TextStyle(
                      color: Color.fromRGB(247, 147, 26),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'v0.1.0',
                    style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 1),
            const Expanded(
              child: Center(
                child: Text('NixBlitz is starting...'),
              ),
            ),
            const Divider(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: const Text(
                '[q]: Quit',
                style: TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 8: Verify workspace resolves**

Run: `dart pub get`
Expected: Dependencies resolve successfully for both packages.

- [ ] **Step 9: Run the TUI to verify it launches**

Run: `cd tui && dart run bin/nixblitz.dart`
Expected: TUI renders with header "NIXBLITZ", placeholder content, footer "[q]: Quit". Press q to exit cleanly.

- [ ] **Step 10: Commit**

```bash
git add pubspec.yaml analysis_options.yaml common/ tui/
git commit -m "feat: scaffold Dart workspace with common and tui packages"
```

---

## Task 2: Config Model + JSON Serialization

**Files:**
- Create: `common/lib/src/models/nixblitz_config.dart`
- Create: `common/test/models/nixblitz_config_test.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Write the failing test**

```dart
// common/test/models/nixblitz_config_test.dart
import 'dart:convert';
import 'package:test/test.dart';
import 'package:common/src/models/nixblitz_config.dart';

void main() {
  group('NixblitzConfig', () {
    test('should create default config', () {
      final config = NixblitzConfig.defaults();

      expect(config.initialized, false);
      expect(config.system.hostname, 'nixblitz');
      expect(config.system.timezone, 'UTC');
      expect(config.system.platform, 'x86');
      expect(config.bitcoind.enabled, true);
      expect(config.bitcoind.network, 'mainnet');
      expect(config.bitcoind.pruned, true);
      expect(config.bitcoind.pruneSizeGb, 550);
      expect(config.lnd.enabled, false);
      expect(config.cln.enabled, false);
      expect(config.blitzApi.enabled, true);
      expect(config.blitzWeb.enabled, true);
    });

    test('should serialize to JSON and back', () {
      final config = NixblitzConfig.defaults();
      final json = jsonEncode(config.toJson());
      final restored = NixblitzConfig.fromJson(jsonDecode(json));

      expect(restored.initialized, config.initialized);
      expect(restored.system.hostname, config.system.hostname);
      expect(restored.bitcoind.network, config.bitcoind.network);
      expect(restored.lnd.enabled, config.lnd.enabled);
    });

    test('should produce diff description for changed fields', () {
      final before = NixblitzConfig.defaults();
      final after = before.copyWith(
        bitcoind: before.bitcoind.copyWith(network: 'testnet'),
      );

      final diff = after.diffFrom(before);
      expect(diff, contains('bitcoind'));
      expect(diff, contains('testnet'));
    });

    test('should round-trip unknown fields in JSON', () {
      final json = {
        'initialized': false,
        'system': {'hostname': 'test', 'timezone': 'UTC', 'platform': 'x86'},
        'bitcoind': {
          'enabled': true,
          'network': 'mainnet',
          'pruned': false,
          'prune_size_gb': 550,
        },
        'lnd': {'enabled': false, 'alias': ''},
        'cln': {'enabled': false},
        'blitz_api': {'enabled': false},
        'blitz_web': {'enabled': false},
        'some_future_field': {'value': 42},
      };

      final config = NixblitzConfig.fromJson(json);
      final reencoded = config.toJson();
      expect(reencoded['some_future_field'], {'value': 42});
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/models/nixblitz_config_test.dart`
Expected: FAIL — `nixblitz_config.dart` doesn't exist yet.

- [ ] **Step 3: Implement the config model**

```dart
// common/lib/src/models/nixblitz_config.dart
import 'dart:convert';

class SystemConfig {
  final String hostname;
  final String timezone;
  final String platform;

  const SystemConfig({
    required this.hostname,
    required this.timezone,
    required this.platform,
  });

  factory SystemConfig.defaults() => const SystemConfig(
        hostname: 'nixblitz',
        timezone: 'UTC',
        platform: 'x86',
      );

  factory SystemConfig.fromJson(Map<String, dynamic> json) => SystemConfig(
        hostname: json['hostname'] as String,
        timezone: json['timezone'] as String,
        platform: json['platform'] as String,
      );

  Map<String, dynamic> toJson() => {
        'hostname': hostname,
        'timezone': timezone,
        'platform': platform,
      };

  SystemConfig copyWith({String? hostname, String? timezone, String? platform}) =>
      SystemConfig(
        hostname: hostname ?? this.hostname,
        timezone: timezone ?? this.timezone,
        platform: platform ?? this.platform,
      );
}

class BitcoindConfig {
  final bool enabled;
  final String network;
  final bool pruned;
  final int pruneSizeGb;

  const BitcoindConfig({
    required this.enabled,
    required this.network,
    required this.pruned,
    required this.pruneSizeGb,
  });

  factory BitcoindConfig.defaults() => const BitcoindConfig(
        enabled: true,
        network: 'mainnet',
        pruned: true,
        pruneSizeGb: 550,
      );

  factory BitcoindConfig.fromJson(Map<String, dynamic> json) => BitcoindConfig(
        enabled: json['enabled'] as bool,
        network: json['network'] as String,
        pruned: json['pruned'] as bool,
        pruneSizeGb: json['prune_size_gb'] as int,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'network': network,
        'pruned': pruned,
        'prune_size_gb': pruneSizeGb,
      };

  BitcoindConfig copyWith({
    bool? enabled,
    String? network,
    bool? pruned,
    int? pruneSizeGb,
  }) =>
      BitcoindConfig(
        enabled: enabled ?? this.enabled,
        network: network ?? this.network,
        pruned: pruned ?? this.pruned,
        pruneSizeGb: pruneSizeGb ?? this.pruneSizeGb,
      );
}

class LndConfig {
  final bool enabled;
  final String alias;

  const LndConfig({required this.enabled, required this.alias});

  factory LndConfig.defaults() =>
      const LndConfig(enabled: false, alias: '');

  factory LndConfig.fromJson(Map<String, dynamic> json) => LndConfig(
        enabled: json['enabled'] as bool,
        alias: json['alias'] as String,
      );

  Map<String, dynamic> toJson() => {'enabled': enabled, 'alias': alias};

  LndConfig copyWith({bool? enabled, String? alias}) =>
      LndConfig(enabled: enabled ?? this.enabled, alias: alias ?? this.alias);
}

class ClnConfig {
  final bool enabled;

  const ClnConfig({required this.enabled});

  factory ClnConfig.defaults() => const ClnConfig(enabled: false);

  factory ClnConfig.fromJson(Map<String, dynamic> json) =>
      ClnConfig(enabled: json['enabled'] as bool);

  Map<String, dynamic> toJson() => {'enabled': enabled};

  ClnConfig copyWith({bool? enabled}) =>
      ClnConfig(enabled: enabled ?? this.enabled);
}

class BlitzApiConfig {
  final bool enabled;

  const BlitzApiConfig({required this.enabled});

  factory BlitzApiConfig.defaults() => const BlitzApiConfig(enabled: true);

  factory BlitzApiConfig.fromJson(Map<String, dynamic> json) =>
      BlitzApiConfig(enabled: json['enabled'] as bool);

  Map<String, dynamic> toJson() => {'enabled': enabled};

  BlitzApiConfig copyWith({bool? enabled}) =>
      BlitzApiConfig(enabled: enabled ?? this.enabled);
}

class BlitzWebConfig {
  final bool enabled;

  const BlitzWebConfig({required this.enabled});

  factory BlitzWebConfig.defaults() => const BlitzWebConfig(enabled: true);

  factory BlitzWebConfig.fromJson(Map<String, dynamic> json) =>
      BlitzWebConfig(enabled: json['enabled'] as bool);

  Map<String, dynamic> toJson() => {'enabled': enabled};

  BlitzWebConfig copyWith({bool? enabled}) =>
      BlitzWebConfig(enabled: enabled ?? this.enabled);
}

class NixblitzConfig {
  final bool initialized;
  final SystemConfig system;
  final BitcoindConfig bitcoind;
  final LndConfig lnd;
  final ClnConfig cln;
  final BlitzApiConfig blitzApi;
  final BlitzWebConfig blitzWeb;

  /// Preserves unknown top-level keys for forward compatibility.
  final Map<String, dynamic> _extra;

  NixblitzConfig({
    required this.initialized,
    required this.system,
    required this.bitcoind,
    required this.lnd,
    required this.cln,
    required this.blitzApi,
    required this.blitzWeb,
    Map<String, dynamic> extra = const {},
  }) : _extra = extra;

  factory NixblitzConfig.defaults() => NixblitzConfig(
        initialized: false,
        system: SystemConfig.defaults(),
        bitcoind: BitcoindConfig.defaults(),
        lnd: LndConfig.defaults(),
        cln: ClnConfig.defaults(),
        blitzApi: BlitzApiConfig.defaults(),
        blitzWeb: BlitzWebConfig.defaults(),
      );

  factory NixblitzConfig.fromJson(Map<String, dynamic> json) {
    final knownKeys = {
      'initialized', 'system', 'bitcoind', 'lnd', 'cln', 'blitz_api', 'blitz_web'
    };
    final extra = Map<String, dynamic>.from(json)
      ..removeWhere((k, _) => knownKeys.contains(k));

    return NixblitzConfig(
      initialized: json['initialized'] as bool,
      system: SystemConfig.fromJson(json['system']),
      bitcoind: BitcoindConfig.fromJson(json['bitcoind']),
      lnd: LndConfig.fromJson(json['lnd']),
      cln: ClnConfig.fromJson(json['cln']),
      blitzApi: BlitzApiConfig.fromJson(json['blitz_api']),
      blitzWeb: BlitzWebConfig.fromJson(json['blitz_web']),
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => {
        'initialized': initialized,
        'system': system.toJson(),
        'bitcoind': bitcoind.toJson(),
        'lnd': lnd.toJson(),
        'cln': cln.toJson(),
        'blitz_api': blitzApi.toJson(),
        'blitz_web': blitzWeb.toJson(),
        ..._extra,
      };

  String toJsonString() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(toJson());
  }

  /// Returns a human-readable description of what changed between [other] and this.
  /// Used for auto-generating git commit messages.
  String diffFrom(NixblitzConfig other) {
    final changes = <String>[];

    if (initialized != other.initialized) {
      changes.add('initialized: ${other.initialized} -> $initialized');
    }
    if (system.hostname != other.system.hostname) {
      changes.add('system: hostname -> ${system.hostname}');
    }
    if (system.timezone != other.system.timezone) {
      changes.add('system: timezone -> ${system.timezone}');
    }
    if (bitcoind.enabled != other.bitcoind.enabled) {
      changes.add('bitcoind: ${bitcoind.enabled ? "enable" : "disable"}');
    }
    if (bitcoind.network != other.bitcoind.network) {
      changes.add('bitcoind: network -> ${bitcoind.network}');
    }
    if (bitcoind.pruned != other.bitcoind.pruned) {
      changes.add('bitcoind: pruned -> ${bitcoind.pruned}');
    }
    if (bitcoind.pruneSizeGb != other.bitcoind.pruneSizeGb) {
      changes.add('bitcoind: prune_size -> ${bitcoind.pruneSizeGb}GB');
    }
    if (lnd.enabled != other.lnd.enabled) {
      changes.add('lnd: ${lnd.enabled ? "enable" : "disable"}');
    }
    if (lnd.alias != other.lnd.alias) {
      changes.add('lnd: alias -> ${lnd.alias}');
    }
    if (cln.enabled != other.cln.enabled) {
      changes.add('cln: ${cln.enabled ? "enable" : "disable"}');
    }
    if (blitzApi.enabled != other.blitzApi.enabled) {
      changes.add('blitz-api: ${blitzApi.enabled ? "enable" : "disable"}');
    }
    if (blitzWeb.enabled != other.blitzWeb.enabled) {
      changes.add('blitz-web: ${blitzWeb.enabled ? "enable" : "disable"}');
    }

    return changes.isEmpty ? 'no changes' : changes.join(', ');
  }

  NixblitzConfig copyWith({
    bool? initialized,
    SystemConfig? system,
    BitcoindConfig? bitcoind,
    LndConfig? lnd,
    ClnConfig? cln,
    BlitzApiConfig? blitzApi,
    BlitzWebConfig? blitzWeb,
  }) =>
      NixblitzConfig(
        initialized: initialized ?? this.initialized,
        system: system ?? this.system,
        bitcoind: bitcoind ?? this.bitcoind,
        lnd: lnd ?? this.lnd,
        cln: cln ?? this.cln,
        blitzApi: blitzApi ?? this.blitzApi,
        blitzWeb: blitzWeb ?? this.blitzWeb,
        extra: _extra,
      );
}
```

- [ ] **Step 4: Update barrel export**

```dart
// common/lib/common.dart
library common;

export 'src/models/nixblitz_config.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd common && dart test test/models/nixblitz_config_test.dart`
Expected: All 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add common/
git commit -m "feat: add NixblitzConfig model with JSON serialization and diff"
```

---

## Task 3: Config Service (JSON read/write + file operations)

**Files:**
- Create: `common/lib/src/services/config_service.dart`
- Create: `common/test/services/config_service_test.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Write the failing test**

```dart
// common/test/services/config_service_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/services/config_service.dart';

void main() {
  group('ConfigService', () {
    late Directory tempDir;
    late ConfigService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_test_');
      service = ConfigService(baseDir: tempDir.path);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('configExists returns false when no config.json', () {
      expect(service.configExists(), false);
    });

    test('writeConfig creates config.json and readConfig restores it', () async {
      final config = NixblitzConfig.defaults();
      await service.writeConfig(config);

      expect(service.configExists(), true);

      final restored = await service.readConfig();
      expect(restored.system.hostname, config.system.hostname);
      expect(restored.bitcoind.network, config.bitcoind.network);
    });

    test('readConfig returns initialized state correctly', () async {
      final config = NixblitzConfig.defaults().copyWith(initialized: true);
      await service.writeConfig(config);

      final restored = await service.readConfig();
      expect(restored.initialized, true);
    });

    test('writeConfig produces pretty-printed JSON', () async {
      final config = NixblitzConfig.defaults();
      await service.writeConfig(config);

      final file = File('${tempDir.path}/config.json');
      final content = await file.readAsString();
      expect(content, contains('\n'));
      expect(content, contains('  '));
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/config_service_test.dart`
Expected: FAIL — `config_service.dart` doesn't exist yet.

- [ ] **Step 3: Implement ConfigService**

```dart
// common/lib/src/services/config_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:common/src/models/nixblitz_config.dart';

class ConfigService {
  final String baseDir;

  ConfigService({required this.baseDir});

  String get configPath => '$baseDir/config.json';

  bool configExists() => File(configPath).existsSync();

  Future<NixblitzConfig> readConfig() async {
    final file = File(configPath);
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    return NixblitzConfig.fromJson(json);
  }

  Future<void> writeConfig(NixblitzConfig config) async {
    final file = File(configPath);
    await file.writeAsString(config.toJsonString());
  }
}
```

- [ ] **Step 4: Update barrel export**

```dart
// common/lib/common.dart
library common;

export 'src/models/nixblitz_config.dart';
export 'src/services/config_service.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd common && dart test test/services/config_service_test.dart`
Expected: All 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add common/
git commit -m "feat: add ConfigService for config.json read/write"
```

---

## Task 4: Git Service

**Files:**
- Create: `common/lib/src/services/git_service.dart`
- Create: `common/test/services/git_service_test.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Write the failing test**

```dart
// common/test/services/git_service_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:common/src/services/git_service.dart';

void main() {
  group('GitService', () {
    late Directory tempDir;
    late GitService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_git_test_');
      service = GitService(repoDir: tempDir.path);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('init creates a git repository', () async {
      final result = await service.init();
      expect(result, true);

      final gitDir = Directory('${tempDir.path}/.git');
      expect(gitDir.existsSync(), true);
    });

    test('commit stages and commits a file', () async {
      await service.init();

      // Create a file to commit
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('hello');

      final result = await service.commit('test.txt', 'initial commit');
      expect(result, true);

      // Verify commit exists
      final log = await service.log(count: 1);
      expect(log, contains('initial commit'));
    });

    test('revertLast reverts the most recent commit', () async {
      await service.init();

      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('version 1');
      await service.commit('test.txt', 'first');

      await file.writeAsString('version 2');
      await service.commit('test.txt', 'second');

      await service.revertLast();

      final content = await file.readAsString();
      expect(content, 'version 1');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/git_service_test.dart`
Expected: FAIL — `git_service.dart` doesn't exist yet.

- [ ] **Step 3: Implement GitService**

```dart
// common/lib/src/services/git_service.dart
import 'dart:io';

class GitService {
  final String repoDir;

  GitService({required this.repoDir});

  Future<bool> init() async {
    final result = await Process.run('git', ['init'], workingDirectory: repoDir);
    if (result.exitCode != 0) return false;

    // Configure user for commits (needed on fresh systems)
    await Process.run(
      'git', ['config', 'user.email', 'nixblitz@localhost'],
      workingDirectory: repoDir,
    );
    await Process.run(
      'git', ['config', 'user.name', 'NixBlitz'],
      workingDirectory: repoDir,
    );
    return true;
  }

  Future<bool> commit(String filePath, String message) async {
    final add = await Process.run(
      'git', ['add', filePath],
      workingDirectory: repoDir,
    );
    if (add.exitCode != 0) return false;

    final commit = await Process.run(
      'git', ['commit', '-m', message],
      workingDirectory: repoDir,
    );
    return commit.exitCode == 0;
  }

  Future<bool> revertLast() async {
    final result = await Process.run(
      'git', ['revert', '--no-edit', 'HEAD'],
      workingDirectory: repoDir,
    );
    return result.exitCode == 0;
  }

  Future<String> log({int count = 10}) async {
    final result = await Process.run(
      'git', ['log', '--oneline', '-$count'],
      workingDirectory: repoDir,
    );
    return result.stdout as String;
  }
}
```

- [ ] **Step 4: Update barrel export**

```dart
// common/lib/common.dart
library common;

export 'src/models/nixblitz_config.dart';
export 'src/services/config_service.dart';
export 'src/services/git_service.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd common && dart test test/services/git_service_test.dart`
Expected: All 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add common/
git commit -m "feat: add GitService for git init, commit, revert, and log"
```

---

## Task 5: System Service (nixos-rebuild, systemctl)

**Files:**
- Create: `common/lib/src/services/system_service.dart`
- Create: `common/lib/src/models/service_status.dart`
- Create: `common/test/services/system_service_test.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Write the failing test**

```dart
// common/test/services/system_service_test.dart
import 'package:test/test.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/system_service.dart';

void main() {
  group('SystemService', () {
    late SystemService service;

    setUp(() {
      service = SystemService();
    });

    test('parseServiceStatus parses active running', () {
      const output = 'ActiveState=active\nSubState=running\n';
      final status = SystemService.parseServiceStatus('bitcoind', output);
      expect(status.name, 'bitcoind');
      expect(status.state, ServiceState.running);
    });

    test('parseServiceStatus parses inactive dead', () {
      const output = 'ActiveState=inactive\nSubState=dead\n';
      final status = SystemService.parseServiceStatus('lnd', output);
      expect(status.name, 'lnd');
      expect(status.state, ServiceState.stopped);
    });

    test('parseServiceStatus parses failed', () {
      const output = 'ActiveState=failed\nSubState=failed\n';
      final status = SystemService.parseServiceStatus('cln', output);
      expect(status.name, 'cln');
      expect(status.state, ServiceState.failed);
    });

    test('parseServiceStatus handles activating', () {
      const output = 'ActiveState=activating\nSubState=start\n';
      final status = SystemService.parseServiceStatus('bitcoind', output);
      expect(status.state, ServiceState.activating);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/system_service_test.dart`
Expected: FAIL — files don't exist yet.

- [ ] **Step 3: Implement ServiceStatus model**

```dart
// common/lib/src/models/service_status.dart

enum ServiceState {
  running,
  stopped,
  failed,
  activating,
  unknown,
}

class ServiceStatus {
  final String name;
  final ServiceState state;

  const ServiceStatus({required this.name, required this.state});

  bool get isRunning => state == ServiceState.running;

  String get stateLabel => switch (state) {
        ServiceState.running => 'running',
        ServiceState.stopped => 'stopped',
        ServiceState.failed => 'failed',
        ServiceState.activating => 'activating',
        ServiceState.unknown => 'unknown',
      };
}
```

- [ ] **Step 4: Implement SystemService**

```dart
// common/lib/src/services/system_service.dart
import 'dart:async';
import 'dart:io';
import 'package:common/src/models/service_status.dart';

class SystemService {
  /// Query the status of a systemd service by name.
  Future<ServiceStatus> getServiceStatus(String serviceName) async {
    final result = await Process.run('systemctl', [
      'show',
      serviceName,
      '--property=ActiveState,SubState',
      '--no-pager',
    ]);

    return parseServiceStatus(serviceName, result.stdout as String);
  }

  /// Parse systemctl show output into a ServiceStatus.
  static ServiceStatus parseServiceStatus(String name, String output) {
    final lines = output.trim().split('\n');
    String? activeState;

    for (final line in lines) {
      if (line.startsWith('ActiveState=')) {
        activeState = line.substring('ActiveState='.length);
      }
    }

    final state = switch (activeState) {
      'active' => ServiceState.running,
      'inactive' => ServiceState.stopped,
      'failed' => ServiceState.failed,
      'activating' => ServiceState.activating,
      _ => ServiceState.unknown,
    };

    return ServiceStatus(name: name, state: state);
  }

  /// Get status of all NixBlitz services.
  Future<List<ServiceStatus>> getAllServiceStatuses() async {
    final services = ['bitcoind', 'lnd', 'clightning', 'blitz-api', 'blitz-web'];
    return Future.wait(services.map(getServiceStatus));
  }

  /// Run nixos-rebuild switch and stream output.
  /// Returns a Stream of output lines and a Future that completes with the exit code.
  ({Stream<String> output, Future<int> exitCode}) rebuild(String flakePath) {
    final controller = StreamController<String>();

    final exitCodeFuture = () async {
      final process = await Process.start(
        'sudo',
        ['nixos-rebuild', 'switch', '--flake', flakePath],
      );

      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen((data) => controller.add(data));
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen((data) => controller.add(data));

      final code = await process.exitCode;
      await controller.close();
      return code;
    }();

    return (output: controller.stream, exitCode: exitCodeFuture);
  }
}
```

- [ ] **Step 5: Update barrel export**

```dart
// common/lib/common.dart
library common;

export 'src/models/nixblitz_config.dart';
export 'src/models/service_status.dart';
export 'src/services/config_service.dart';
export 'src/services/git_service.dart';
export 'src/services/system_service.dart';
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd common && dart test test/services/system_service_test.dart`
Expected: All 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add common/
git commit -m "feat: add SystemService and ServiceStatus for systemctl and nixos-rebuild"
```

---

## Task 6: Riverpod Providers

**Files:**
- Create: `common/lib/src/providers/config_provider.dart`
- Create: `common/lib/src/providers/service_status_provider.dart`
- Create: `tui/lib/src/providers/ui_state_provider.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Create config provider**

```dart
// common/lib/src/providers/config_provider.dart
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/services/config_service.dart';

/// The base directory for the nixblitz config repo (~/nixblitz/).
final baseDirProvider = Provider<String>((ref) {
  throw UnimplementedError('baseDirProvider must be overridden');
});

final configServiceProvider = Provider<ConfigService>((ref) {
  return ConfigService(baseDir: ref.watch(baseDirProvider));
});

/// Holds the current in-memory config. Initialized from disk on first load.
final configProvider =
    StateNotifierProvider<ConfigNotifier, AsyncValue<NixblitzConfig>>((ref) {
  return ConfigNotifier(ref.watch(configServiceProvider));
});

class ConfigNotifier extends StateNotifier<AsyncValue<NixblitzConfig>> {
  final ConfigService _configService;

  ConfigNotifier(this._configService) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      if (_configService.configExists()) {
        final config = await _configService.readConfig();
        state = AsyncValue.data(config);
      } else {
        state = AsyncValue.data(NixblitzConfig.defaults());
      }
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> updateConfig(NixblitzConfig config) async {
    await _configService.writeConfig(config);
    state = AsyncValue.data(config);
  }

  Future<void> reload() async => _load();
}
```

- [ ] **Step 2: Create service status provider**

```dart
// common/lib/src/providers/service_status_provider.dart
import 'package:riverpod/riverpod.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/system_service.dart';

final systemServiceProvider = Provider<SystemService>((ref) {
  return SystemService();
});

final serviceStatusProvider =
    FutureProvider<List<ServiceStatus>>((ref) async {
  final service = ref.watch(systemServiceProvider);
  return service.getAllServiceStatuses();
});
```

- [ ] **Step 3: Create UI state provider**

```dart
// tui/lib/src/providers/ui_state_provider.dart
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';

enum AppView { dashboard, configure, apply }

final currentViewProvider = StateProvider<AppView>((ref) => AppView.dashboard);

final selectedServiceIndexProvider = StateProvider<int>((ref) => 0);
```

- [ ] **Step 4: Update barrel export**

```dart
// common/lib/common.dart
library common;

export 'src/models/nixblitz_config.dart';
export 'src/models/service_status.dart';
export 'src/services/config_service.dart';
export 'src/services/git_service.dart';
export 'src/services/system_service.dart';
export 'src/providers/config_provider.dart';
export 'src/providers/service_status_provider.dart';
```

- [ ] **Step 5: Verify everything compiles**

Run: `dart pub get && cd common && dart analyze && cd ../tui && dart analyze`
Expected: No analysis errors.

- [ ] **Step 6: Commit**

```bash
git add common/ tui/
git commit -m "feat: add Riverpod providers for config, service status, and UI state"
```

---

## Task 7: Dashboard View

**Files:**
- Create: `tui/lib/src/ui/views/dashboard_view.dart`
- Create: `tui/lib/src/ui/widgets/service_card.dart`
- Modify: `tui/lib/src/ui/app.dart`

- [ ] **Step 1: Create service_card widget**

```dart
// tui/lib/src/ui/widgets/service_card.dart
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

class ServiceCard extends StatelessComponent {
  final ServiceStatus status;
  final bool isDisabled;

  const ServiceCard({
    super.key,
    required this.status,
    this.isDisabled = false,
  });

  @override
  Component build(BuildContext context) {
    final Color stateColor;
    final String stateIcon;

    if (isDisabled) {
      stateColor = const Color.fromRGB(100, 100, 120);
      stateIcon = '-';
    } else {
      switch (status.state) {
        case ServiceState.running:
          stateColor = const Color.fromRGB(110, 220, 110);
          stateIcon = '*';
        case ServiceState.failed:
          stateColor = const Color.fromRGB(255, 80, 80);
          stateIcon = '!';
        case ServiceState.activating:
          stateColor = const Color.fromRGB(247, 147, 26);
          stateIcon = '~';
        default:
          stateColor = const Color.fromRGB(100, 100, 120);
          stateIcon = 'x';
      }
    }

    final label = isDisabled ? 'disabled' : status.stateLabel;

    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            '${status.name}:',
            style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
          ),
        ),
        Text(
          '$stateIcon $label',
          style: TextStyle(color: stateColor),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Create dashboard_view**

```dart
// tui/lib/src/ui/views/dashboard_view.dart
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../widgets/service_card.dart';

class DashboardView extends StatelessComponent {
  const DashboardView({super.key});

  @override
  Component build(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final statusAsync = context.watch(serviceStatusProvider);

    return configAsync.when(
      loading: () => const Center(child: Text('Loading config...')),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (config) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header line
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    config.system.hostname,
                    style: const TextStyle(
                      color: Color.fromRGB(220, 220, 220),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${config.system.platform} | ${config.bitcoind.network}',
                    style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 1),

            // Service status grid
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: statusAsync.when(
                  loading: () => const Text('Checking services...'),
                  error: (e, _) => Text('Could not read services: $e'),
                  data: (statuses) {
                    final statusMap = {
                      for (final s in statuses) s.name: s,
                    };

                    ServiceStatus statusFor(String name) =>
                        statusMap[name] ??
                        ServiceStatus(
                          name: name,
                          state: ServiceState.unknown,
                        );

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: ServiceCard(
                                status: statusFor('bitcoind'),
                                isDisabled: !config.bitcoind.enabled,
                              ),
                            ),
                            Expanded(
                              child: ServiceCard(
                                status: statusFor('lnd'),
                                isDisabled: !config.lnd.enabled,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: ServiceCard(
                                status: statusFor('clightning'),
                                isDisabled: !config.cln.enabled,
                              ),
                            ),
                            Expanded(
                              child: ServiceCard(
                                status: statusFor('blitz-api'),
                                isDisabled: !config.blitzApi.enabled,
                              ),
                            ),
                          ],
                        ),
                        ServiceCard(
                          status: statusFor('blitz-web'),
                          isDisabled: !config.blitzWeb.enabled,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
```

- [ ] **Step 3: Wire dashboard into app.dart Shell**

Replace the placeholder `Expanded` center content in `tui/lib/src/ui/app.dart` `_Shell.build()`:

Replace:
```dart
            const Expanded(
              child: Center(
                child: Text('NixBlitz is starting...'),
              ),
            ),
```

With:
```dart
            const Expanded(child: DashboardView()),
```

Add import at top of `app.dart`:
```dart
import 'views/dashboard_view.dart';
```

Update help text from `'[q]: Quit'` to `'[c]: Configure  [q]: Quit'`.

- [ ] **Step 4: Verify it compiles**

Run: `cd tui && dart analyze`
Expected: No analysis errors.

- [ ] **Step 5: Commit**

```bash
git add tui/
git commit -m "feat: add dashboard view with service status cards"
```

---

## Task 8: Configure View

**Files:**
- Create: `tui/lib/src/ui/views/configure_view.dart`
- Create: `tui/lib/src/ui/widgets/option_editor.dart`
- Modify: `tui/lib/src/ui/app.dart`

- [ ] **Step 1: Create option_editor widgets**

```dart
// tui/lib/src/ui/widgets/option_editor.dart
import 'package:nocterm/nocterm.dart';

class BoolOptionEditor extends StatelessComponent {
  final String label;
  final bool value;
  final bool focused;
  final ValueChanged<bool>? onChanged;

  const BoolOptionEditor({
    super.key,
    required this.label,
    required this.value,
    this.focused = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final check = value ? 'x' : ' ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);

    return Text(
      '$prefix$label: [$check]',
      style: TextStyle(color: color),
    );
  }
}

class SelectOptionEditor extends StatelessComponent {
  final String label;
  final String value;
  final List<String> options;
  final bool focused;
  final ValueChanged<String>? onChanged;

  const SelectOptionEditor({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    this.focused = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);

    return Text(
      '$prefix$label: [$value]',
      style: TextStyle(color: color),
    );
  }
}

class NumberOptionEditor extends StatelessComponent {
  final String label;
  final int value;
  final String unit;
  final bool focused;
  final ValueChanged<int>? onChanged;

  const NumberOptionEditor({
    super.key,
    required this.label,
    required this.value,
    this.unit = '',
    this.focused = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    final suffix = unit.isNotEmpty ? ' $unit' : '';

    return Text(
      '$prefix$label: [$value$suffix]',
      style: TextStyle(color: color),
    );
  }
}

class TextOptionEditor extends StatelessComponent {
  final String label;
  final String value;
  final bool focused;
  final ValueChanged<String>? onChanged;

  const TextOptionEditor({
    super.key,
    required this.label,
    required this.value,
    this.focused = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);

    return Text(
      '$prefix$label: [$value]',
      style: TextStyle(color: color),
    );
  }
}
```

- [ ] **Step 2: Create configure_view**

```dart
// tui/lib/src/ui/views/configure_view.dart
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/option_editor.dart';
import '../../providers/ui_state_provider.dart';

final _selectedOptionProvider = StateProvider<int>((ref) => 0);

class ConfigureView extends StatelessComponent {
  const ConfigureView({super.key});

  @override
  Component build(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final serviceIndex = context.watch(selectedServiceIndexProvider);
    final selectedOption = context.watch(_selectedOptionProvider);

    return configAsync.when(
      loading: () => const Center(child: Text('Loading...')),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (config) {
        final services = ['system', 'bitcoind', 'lnd', 'cln', 'blitz-api', 'blitz-web'];
        final currentService = services[serviceIndex];

        final options = _buildOptions(config, currentService, selectedOption);

        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            if (event.logicalKey == LogicalKey.keyJ ||
                event.logicalKey == LogicalKey.arrowDown) {
              final max = options.length - 1;
              if (selectedOption < max) {
                context.read(_selectedOptionProvider.notifier).state =
                    selectedOption + 1;
              }
              return true;
            }
            if (event.logicalKey == LogicalKey.keyK ||
                event.logicalKey == LogicalKey.arrowUp) {
              if (selectedOption > 0) {
                context.read(_selectedOptionProvider.notifier).state =
                    selectedOption - 1;
              }
              return true;
            }
            if (event.logicalKey == LogicalKey.escape) {
              context.read(currentViewProvider.notifier).state =
                  AppView.dashboard;
              return true;
            }
            return false;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  'Configure: $currentService',
                  style: const TextStyle(
                    color: Color.fromRGB(247, 147, 26),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 1),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: options,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Component> _buildOptions(
      NixblitzConfig config, String service, int selectedIndex) {
    switch (service) {
      case 'system':
        return [
          TextOptionEditor(
            label: 'hostname',
            value: config.system.hostname,
            focused: selectedIndex == 0,
          ),
          TextOptionEditor(
            label: 'timezone',
            value: config.system.timezone,
            focused: selectedIndex == 1,
          ),
          SelectOptionEditor(
            label: 'platform',
            value: config.system.platform,
            options: const ['pi4', 'pi5', 'x86', 'vm'],
            focused: selectedIndex == 2,
          ),
        ];
      case 'bitcoind':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.bitcoind.enabled,
            focused: selectedIndex == 0,
          ),
          SelectOptionEditor(
            label: 'network',
            value: config.bitcoind.network,
            options: const ['mainnet', 'testnet', 'signet'],
            focused: selectedIndex == 1,
          ),
          BoolOptionEditor(
            label: 'pruned',
            value: config.bitcoind.pruned,
            focused: selectedIndex == 2,
          ),
          NumberOptionEditor(
            label: 'prune size',
            value: config.bitcoind.pruneSizeGb,
            unit: 'GB',
            focused: selectedIndex == 3,
          ),
        ];
      case 'lnd':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.lnd.enabled,
            focused: selectedIndex == 0,
          ),
          TextOptionEditor(
            label: 'alias',
            value: config.lnd.alias,
            focused: selectedIndex == 1,
          ),
        ];
      case 'cln':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.cln.enabled,
            focused: selectedIndex == 0,
          ),
        ];
      case 'blitz-api':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.blitzApi.enabled,
            focused: selectedIndex == 0,
          ),
        ];
      case 'blitz-web':
        return [
          BoolOptionEditor(
            label: 'enabled',
            value: config.blitzWeb.enabled,
            focused: selectedIndex == 0,
          ),
        ];
      default:
        return [const Text('Unknown service')];
    }
  }
}
```

- [ ] **Step 3: Wire view switching into app.dart**

Update `_Shell.build()` in `tui/lib/src/ui/app.dart` to swap views based on `currentViewProvider`:

Replace:
```dart
            const Expanded(child: DashboardView()),
```

With:
```dart
            Expanded(
              child: switch (context.watch(currentViewProvider)) {
                AppView.dashboard => const DashboardView(),
                AppView.configure => const ConfigureView(),
                AppView.apply => const Center(child: Text('Applying...')),
              },
            ),
```

Add imports:
```dart
import 'views/configure_view.dart';
import '../providers/ui_state_provider.dart';
```

Add `c` key handler in the `_Shell` `Focusable.onKeyEvent`:
```dart
        if (event.logicalKey == LogicalKey.keyC) {
          context.read(currentViewProvider.notifier).state = AppView.configure;
          return true;
        }
```

- [ ] **Step 4: Verify it compiles**

Run: `cd tui && dart analyze`
Expected: No analysis errors.

- [ ] **Step 5: Commit**

```bash
git add tui/
git commit -m "feat: add configure view with option editors and view switching"
```

---

## Task 9: Apply View (nixos-rebuild progress)

**Files:**
- Create: `tui/lib/src/ui/views/apply_view.dart`
- Modify: `tui/lib/src/ui/app.dart`

- [ ] **Step 1: Create apply_view**

```dart
// tui/lib/src/ui/views/apply_view.dart
import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../providers/ui_state_provider.dart';

final _rebuildOutputProvider = StateProvider<List<String>>((ref) => []);
final _rebuildRunningProvider = StateProvider<bool>((ref) => false);

class ApplyView extends StatefulComponent {
  const ApplyView({super.key});

  @override
  State<ApplyView> createState() => _ApplyViewState();
}

class _ApplyViewState extends State<ApplyView> {
  StreamSubscription<String>? _outputSub;

  @override
  void initState() {
    super.initState();
    _startRebuild();
  }

  void _startRebuild() {
    final configAsync = context.read(configProvider);
    final config = configAsync.value;
    if (config == null) return;

    final baseDirPath = context.read(baseDirProvider);
    final systemService = context.read(systemServiceProvider);

    context.read(_rebuildRunningProvider.notifier).state = true;
    context.read(_rebuildOutputProvider.notifier).state = [
      '> sudo nixos-rebuild switch --flake $baseDirPath',
      '',
    ];

    final (:output, :exitCode) = systemService.rebuild(baseDirPath);

    _outputSub = output.listen((line) {
      final current = context.read(_rebuildOutputProvider);
      context.read(_rebuildOutputProvider.notifier).state = [...current, line];
    });

    exitCode.then((code) {
      final current = context.read(_rebuildOutputProvider);
      final msg = code == 0
          ? '\nRebuild successful. Press Esc to return.'
          : '\nRebuild failed (exit code $code). Press Esc to return.';
      context.read(_rebuildOutputProvider.notifier).state = [...current, msg];
      context.read(_rebuildRunningProvider.notifier).state = false;
    });
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final outputLines = context.watch(_rebuildOutputProvider);
    final running = context.watch(_rebuildRunningProvider);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape && !running) {
          context.read(currentViewProvider.notifier).state = AppView.dashboard;
          return true;
        }
        return false;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              running ? 'Applying configuration...' : 'Rebuild complete',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 1),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ListView.builder(
                itemCount: outputLines.length,
                itemBuilder: (context, index) {
                  return Text(
                    outputLines[index],
                    style: const TextStyle(color: Color.fromRGB(180, 180, 200)),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Wire apply view into app.dart**

Replace the placeholder in the view switch:
```dart
                AppView.apply => const Center(child: Text('Applying...')),
```

With:
```dart
                AppView.apply => const ApplyView(),
```

Add import:
```dart
import 'views/apply_view.dart';
```

- [ ] **Step 3: Verify it compiles**

Run: `cd tui && dart analyze`
Expected: No analysis errors.

- [ ] **Step 4: Commit**

```bash
git add tui/
git commit -m "feat: add apply view with streaming nixos-rebuild output"
```

---

## Task 10: NixOS Template Flake (Dendritic Pattern)

**Files:**
- Create: `templates/flake.nix`
- Create: `templates/hosts/default.nix`

- [ ] **Step 1: Create templates/flake.nix with findModules**

```nix
# templates/flake.nix
{
  description = "NixBlitz node configuration";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    excludedFiles = ["package.nix" "flake.nix"];

    findModules = dir: let
      entries = builtins.readDir dir;
      processEntry = name: type: let
        path = dir + "/${name}";
      in
        if type == "directory"
        then findModules path
        else if type == "regular" && lib.hasSuffix ".nix" name && !builtins.elem name excludedFiles
        then [path]
        else [];
    in
      lib.concatLists (lib.mapAttrsToList processEntry entries);
  in {
    nixosModules.default = {
      imports = findModules ./modules;
    };

    nixosConfigurations.nixblitz = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux"; # overridden per-platform at install time
      modules = [
        ./hosts/default.nix
        self.nixosModules.default
      ];
    };
  };
}
```

- [ ] **Step 2: Create templates/hosts/default.nix**

```nix
# templates/hosts/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = builtins.fromJSON (builtins.readFile ../config.json);
  sys = cfg.system;
in {
  imports = [
    ../hardware/${sys.platform}.nix
  ];

  networking.hostName = sys.hostname;
  time.timeZone = sys.timezone;

  # Map config.json to feature toggles
  features.system.base.enable = true;

  features.apps.bitcoind.enable = cfg.bitcoind.enabled;
  features.apps.bitcoind.network = cfg.bitcoind.network;
  features.apps.bitcoind.pruned = cfg.bitcoind.pruned;
  features.apps.bitcoind.pruneSizeGb = cfg.bitcoind.prune_size_gb;

  features.apps.lnd.enable = cfg.lnd.enabled;
  features.apps.lnd.alias = cfg.lnd.alias;

  features.apps.cln.enable = cfg.cln.enabled;

  features.apps.blitz-api.enable = cfg.blitz_api.enabled;
  features.apps.blitz-web.enable = cfg.blitz_web.enabled;

  # User setup
  users.users.admin = {
    isNormalUser = true;
    extraGroups = ["wheel"];
  };

  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  system.stateVersion = "25.11";
}
```

- [ ] **Step 3: Commit**

```bash
git add templates/
git commit -m "feat: add NixOS template flake with dendritic module auto-discovery"
```

---

## Task 11: NixOS System Module

**Files:**
- Create: `templates/modules/system/base.nix`

- [ ] **Step 1: Create base system module**

```nix
# templates/modules/system/base.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.system.base;
in {
  options.features.system.base.enable = lib.mkEnableOption "base NixBlitz system configuration";

  config = lib.mkIf cfg.enable {
    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["root" "admin"];
    };

    environment.systemPackages = with pkgs; [
      git
      htop
      btop
      tree
      jq
    ];

    # Enable nushell as default shell
    programs.nushell.enable = true;
    users.defaultUserShell = pkgs.nushell;
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add templates/modules/system/
git commit -m "feat: add base NixOS system module"
```

---

## Task 12: NixOS App Modules (bitcoind, lnd, cln, blitz-api, blitz-web)

**Files:**
- Create: `templates/modules/apps/bitcoind.nix`
- Create: `templates/modules/apps/lnd.nix`
- Create: `templates/modules/apps/cln.nix`
- Create: `templates/modules/apps/blitz-api.nix`
- Create: `templates/modules/apps/blitz-web.nix`

- [ ] **Step 1: Create bitcoind module**

```nix
# templates/modules/apps/bitcoind.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.bitcoind;
in {
  options.features.apps.bitcoind = {
    enable = lib.mkEnableOption "Bitcoin daemon";
    network = lib.mkOption {
      type = lib.types.enum ["mainnet" "testnet" "signet"];
      default = "mainnet";
      description = "Bitcoin network to connect to.";
    };
    pruned = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to prune the blockchain.";
    };
    pruneSizeGb = lib.mkOption {
      type = lib.types.int;
      default = 550;
      description = "Prune target size in GB (minimum 550).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.bitcoind."nixblitz" = {
      enable = true;
      dataDir = "/mnt/data/bitcoind";
      prune = if cfg.pruned then cfg.pruneSizeGb * 1000 else 0;
      extraConfig = ''
        server=1
        txindex=${if cfg.pruned then "0" else "1"}
        ${lib.optionalString (cfg.network == "testnet") "testnet=1"}
        ${lib.optionalString (cfg.network == "signet") "signet=1"}

        # ZMQ
        zmqpubrawtx=tcp://127.0.0.1:28333
        zmqpubrawblock=tcp://127.0.0.1:28332
      '';
    };
  };
}
```

- [ ] **Step 2: Create lnd module**

```nix
# templates/modules/apps/lnd.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.lnd;
  btcCfg = config.features.apps.bitcoind;
in {
  options.features.apps.lnd = {
    enable = lib.mkEnableOption "Lightning Network Daemon (LND)";
    alias = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Node alias visible on the Lightning Network.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.lnd = {
      enable = true;
      dataDir = "/mnt/data/lnd";
      extraConfig = ''
        ${lib.optionalString (cfg.alias != "") "alias=${cfg.alias}"}

        [Bitcoin]
        bitcoin.active=1
        bitcoin.${btcCfg.network}=1
        bitcoin.node=bitcoind

        [Bitcoind]
        bitcoind.rpchost=127.0.0.1:8332
        bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333
        bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
      '';
    };
  };
}
```

- [ ] **Step 3: Create cln module**

```nix
# templates/modules/apps/cln.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.cln;
  btcCfg = config.features.apps.bitcoind;
in {
  options.features.apps.cln = {
    enable = lib.mkEnableOption "Core Lightning (CLN)";
  };

  config = lib.mkIf cfg.enable {
    services.clightning = {
      enable = true;
      dataDir = "/mnt/data/clightning";
      bitcoin-rpcconnect = "127.0.0.1";
      network = btcCfg.network;
    };
  };
}
```

- [ ] **Step 4: Create blitz-api module**

```nix
# templates/modules/apps/blitz-api.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.blitz-api;
in {
  options.features.apps.blitz-api = {
    enable = lib.mkEnableOption "Blitz API";
  };

  config = lib.mkIf cfg.enable {
    # TODO: configure blitz-api service
    # This depends on the blitz-api package being available in nixpkgs or as a flake input
  };
}
```

- [ ] **Step 5: Create blitz-web module**

```nix
# templates/modules/apps/blitz-web.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.blitz-web;
in {
  options.features.apps.blitz-web = {
    enable = lib.mkEnableOption "Blitz Web UI";
  };

  config = lib.mkIf cfg.enable {
    # TODO: configure blitz-web service
    # This depends on the blitz-web package being available in nixpkgs or as a flake input
  };
}
```

- [ ] **Step 6: Commit**

```bash
git add templates/modules/apps/
git commit -m "feat: add NixOS app modules for bitcoind, lnd, cln, blitz-api, blitz-web"
```

---

## Task 13: Hardware Configs

**Files:**
- Create: `templates/hardware/pi4.nix`
- Create: `templates/hardware/pi5.nix`
- Create: `templates/hardware/x86.nix`
- Create: `templates/hardware/vm.nix`

- [ ] **Step 1: Create pi4.nix**

```nix
# templates/hardware/pi4.nix
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  hardware.enableRedistributableFirmware = true;

  # RPi4 specific
  boot.kernelParams = ["cma=64M"];
}
```

- [ ] **Step 2: Create pi5.nix**

```nix
# templates/hardware/pi5.nix
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  hardware.enableRedistributableFirmware = true;
}
```

- [ ] **Step 3: Create x86.nix**

```nix
# templates/hardware/x86.nix
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
```

- [ ] **Step 4: Create vm.nix**

```nix
# templates/hardware/vm.nix
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  services.qemuGuest.enable = true;
}
```

- [ ] **Step 5: Commit**

```bash
git add templates/hardware/
git commit -m "feat: add hardware configs for pi4, pi5, x86, and vm"
```

---

## Task 14: Nix Flake for Building the TUI

**Files:**
- Create: `flake.nix`
- Create: `nix/tui_pkg.nix`

- [ ] **Step 1: Create nix/tui_pkg.nix**

```nix
# nix/tui_pkg.nix
{
  lib,
  buildDartApplication,
  nixFilter,
  version,
}:
buildDartApplication {
  pname = "nixblitz";
  inherit version;

  src = nixFilter {
    root = ./..;
    include = [
      "common"
      "tui"
      "pubspec.yaml"
      "analysis_options.yaml"
    ];
  };

  # Workspace root so dartConfigHook sees the workspace pubspec.yaml
  sourceRoot = "source";

  dartEntryPoints = {
    "bin/nixblitz" = "tui/bin/nixblitz.dart";
  };

  pubspecLock = lib.importJSON ./workspace_pubspec.lock.json;

  workspaceMembers = ["common" "tui"];
  workspaceMember = "tui";
  workspaceDependencyGraph = lib.importJSON ./workspace_dependency_graph.json;

  preBuild = ''
    mkdir -p bin
  '';

  meta = with lib; {
    description = "NixBlitz - Bitcoin/Lightning node manager TUI";
    license = licenses.mit;
    inherit version;
    mainProgram = "nixblitz";
  };
}
```

- [ ] **Step 2: Create flake.nix**

```nix
# flake.nix
{
  description = "NixBlitz - Bitcoin/Lightning NixOS node manager";

  inputs = {
    nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";
    # Custom nixpkgs with Dart workspace support
    # TODO: Switch to upstream once PR is merged
    nixpkgs-unstable.url = "github:fusion44/nixpkgs/dart-workspace-member-filter";
    flake-utils.url = "github:numtide/flake-utils";
    nix-filter.url = "github:numtide/nix-filter";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    flake-utils,
    nix-filter,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
        version = "0.1.0";
      in {
        packages = {
          default = self.packages.${system}.nixblitz;
          nixblitz = pkgsUnstable.callPackage ./nix/tui_pkg.nix {
            nixFilter = nix-filter.lib;
            inherit version;
          };
        };

        # Enables: nix run github:user/nixblitz
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.nixblitz}/bin/nixblitz";
        };
      }
    );
}
```

- [ ] **Step 3: Commit**

```bash
git add flake.nix nix/
git commit -m "feat: add Nix flake for building nixblitz TUI"
```

---

## Task 15: Scaffold Service (install-time ~/nixblitz/ generation)

**Files:**
- Create: `common/lib/src/services/scaffold_service.dart`
- Create: `common/test/services/scaffold_service_test.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Write the failing test**

```dart
// common/test/services/scaffold_service_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:common/src/services/scaffold_service.dart';

void main() {
  group('ScaffoldService', () {
    late Directory tempDir;
    late Directory templateDir;
    late ScaffoldService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_scaffold_test_');
      templateDir =
          Directory.systemTemp.createTempSync('nixblitz_scaffold_tpl_');

      // Create minimal template structure
      File('${templateDir.path}/flake.nix').writeAsStringSync('{ }');
      Directory('${templateDir.path}/hosts').createSync();
      File('${templateDir.path}/hosts/default.nix').writeAsStringSync('{ }');
      Directory('${templateDir.path}/modules/apps').createSync(recursive: true);
      File('${templateDir.path}/modules/apps/bitcoind.nix')
          .writeAsStringSync('{ }');
      Directory('${templateDir.path}/hardware').createSync();
      File('${templateDir.path}/hardware/x86.nix').writeAsStringSync('{ }');

      final targetDir = '${tempDir.path}/nixblitz';
      service = ScaffoldService(
        templateDir: templateDir.path,
        targetDir: targetDir,
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
      templateDir.deleteSync(recursive: true);
    });

    test('scaffold copies template directory to target', () async {
      await service.scaffold();

      final targetDir = Directory('${tempDir.path}/nixblitz');
      expect(targetDir.existsSync(), true);
      expect(File('${targetDir.path}/flake.nix').existsSync(), true);
      expect(
        File('${targetDir.path}/modules/apps/bitcoind.nix').existsSync(),
        true,
      );
    });

    test('scaffold does not overwrite existing directory', () async {
      final targetDir = Directory('${tempDir.path}/nixblitz');
      targetDir.createSync();
      File('${targetDir.path}/existing.txt').writeAsStringSync('keep');

      await service.scaffold();

      expect(
        File('${targetDir.path}/existing.txt').readAsStringSync(),
        'keep',
      );
    });

    test('needsScaffold returns true when target does not exist', () {
      expect(service.needsScaffold(), true);
    });

    test('needsScaffold returns false when target exists', () {
      Directory('${tempDir.path}/nixblitz').createSync();
      expect(service.needsScaffold(), false);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/scaffold_service_test.dart`
Expected: FAIL — `scaffold_service.dart` doesn't exist yet.

- [ ] **Step 3: Implement ScaffoldService**

```dart
// common/lib/src/services/scaffold_service.dart
import 'dart:io';

class ScaffoldService {
  final String templateDir;
  final String targetDir;

  ScaffoldService({required this.templateDir, required this.targetDir});

  bool needsScaffold() => !Directory(targetDir).existsSync();

  Future<void> scaffold() async {
    if (!needsScaffold()) return;

    await _copyDirectory(Directory(templateDir), Directory(targetDir));
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);

    await for (final entity in source.list()) {
      final newPath = '${target.path}/${entity.uri.pathSegments.last}';

      if (entity is File) {
        await entity.copy(newPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      }
    }
  }
}
```

- [ ] **Step 4: Update barrel export**

```dart
// common/lib/common.dart
library common;

export 'src/models/nixblitz_config.dart';
export 'src/models/service_status.dart';
export 'src/services/config_service.dart';
export 'src/services/git_service.dart';
export 'src/services/scaffold_service.dart';
export 'src/services/system_service.dart';
export 'src/providers/config_provider.dart';
export 'src/providers/service_status_provider.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd common && dart test test/services/scaffold_service_test.dart`
Expected: All 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add common/
git commit -m "feat: add ScaffoldService for install-time ~/nixblitz/ generation"
```

---

## Task 16: Run All Tests + Final Verification

**Files:** No new files.

- [ ] **Step 1: Run all common tests**

Run: `cd common && dart test`
Expected: All tests pass (config model, config service, git service, system service, scaffold service).

- [ ] **Step 2: Run analysis on both packages**

Run: `dart pub get && cd common && dart analyze && cd ../tui && dart analyze`
Expected: No analysis issues.

- [ ] **Step 3: Launch TUI and verify it renders**

Run: `cd tui && dart run bin/nixblitz.dart`
Expected: TUI launches with "NIXBLITZ" header, dashboard view (will show errors for service status since systemctl won't have nixblitz services — that's expected). Press q to quit cleanly.

- [ ] **Step 4: Verify --version flag**

Run: `cd tui && dart run bin/nixblitz.dart --version`
Expected: `nixblitz version: 0.1.0`

- [ ] **Step 5: Commit any fixes**

If any issues were found and fixed, commit them:
```bash
git add -A
git commit -m "fix: address issues found during final verification"
```

---

## Deferred: Follow-Up Plans

The following spec requirements are **not covered** in this plan and require their own implementation plans once the foundation above is complete:

### Install Mode (TUI)
The guided installer flow: system check, disk selection, disko partitioning, nixos-install, scaffold ~/nixblitz/, and reboot. This depends on Tasks 1-15 being complete. It requires:
- An `InstallService` in `common` wrapping `disko` and `nixos-install` via `Process.start()`
- An `InstallView` in `tui` with a multi-step wizard UI
- Integration with `ScaffoldService`, `ConfigService`, and `GitService`
- The `nix flake run` entry point (add `apps.default` to `flake.nix`)

### First Boot Setup Mode
The post-install initialization: setting passwords, initializing bitcoin wallet, generating lightning seed, API credentials. This depends on Install Mode being complete. It requires:
- A `SetupService` in `common` wrapping wallet/credential initialization commands
- A `SetupView` in `tui` with sequential steps that wait for service readiness
- Service health polling (wait for bitcoind to be ready before LND setup)
