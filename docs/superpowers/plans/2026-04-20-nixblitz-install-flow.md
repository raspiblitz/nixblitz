# NixBlitz Install Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the guided installation flow so a user can boot a stock NixOS ISO, run `nix flake run github:user/nixblitz`, and get a fully configured Bitcoin/Lightning node.

**Architecture:** An `InstallService` in `common` handles system detection, disk enumeration, and disko-install execution. The TUI gets an `InstallView` with a multi-step wizard. App startup detects whether to show install mode, first-boot setup, or the normal dashboard based on the existence and state of `~/nixblitz/config.json`.

**Tech Stack:** Dart, nocterm, Riverpod, lsblk, disko-install, nixos-install

---

## File Map

### common package (new files)

- Create: `common/lib/src/models/install_state.dart` — install step enum and disk model
- Create: `common/lib/src/services/install_service.dart` — disk detection, disko-install, platform detection
- Create: `common/test/services/install_service_test.dart` — test lsblk/platform parsing
- Create: `common/lib/src/providers/install_provider.dart` — Riverpod provider for install state
- Modify: `common/lib/common.dart` — add exports

### tui package (new/modified files)

- Create: `tui/lib/src/ui/views/install_view.dart` — multi-step install wizard
- Create: `tui/lib/src/ui/views/setup_view.dart` — first-boot setup (passwords, seeds)
- Modify: `tui/lib/src/providers/ui_state_provider.dart` — add install/setup views
- Modify: `tui/lib/src/ui/app.dart` — startup mode detection and routing

---

## Task 1: Install State Model + Disk Model

**Files:**

- Create: `common/lib/src/models/install_state.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Create the install state and disk models**

```dart
// common/lib/src/models/install_state.dart

enum InstallStep {
  detectSystem,
  selectDisk,
  configureServices,
  confirmInstall,
  installing,
  complete,
  failed,
}

class DiskInfo {
  final String name;
  final String path;
  final int sizeBytes;
  final String model;
  final bool removable;

  const DiskInfo({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.model,
    required this.removable,
  });

  String get sizeGb => (sizeBytes / 1000000000).toStringAsFixed(1);

  String get displayName => '$name ($sizeGb GB) $model';

  factory DiskInfo.fromLsblkJson(Map<String, dynamic> json) => DiskInfo(
        name: json['name'] as String,
        path: '/dev/${json['name']}',
        sizeBytes: (json['size'] as num).toInt(),
        model: (json['model'] as String?)?.trim() ?? '',
        removable: json['rm'] == true,
      );
}

class SystemInfo {
  final String platform;
  final int memoryMb;
  final List<DiskInfo> disks;

  const SystemInfo({
    required this.platform,
    required this.memoryMb,
    required this.disks,
  });
}
```

- [ ] **Step 2: Add export to barrel file**

Add to `common/lib/common.dart`:

```dart
export 'src/models/install_state.dart';
```

- [ ] **Step 3: Verify**

Run: `cd /home/f44/dev/blitz/nixblitz/common && dart analyze`
Expected: No errors.

- [ ] **Step 4: Commit**

```
feat: add InstallStep, DiskInfo, and SystemInfo models
```

---

## Task 2: Install Service (detection + disk enumeration + disko-install)

**Files:**

- Create: `common/lib/src/services/install_service.dart`
- Create: `common/test/services/install_service_test.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// common/test/services/install_service_test.dart
import 'package:test/test.dart';
import 'package:common/src/models/install_state.dart';
import 'package:common/src/services/install_service.dart';

void main() {
  group('InstallService', () {
    group('parseLsblkOutput', () {
      test('parses disk list from lsblk JSON', () {
        const output = '''
{
  "blockdevices": [
    {"name":"sda","size":256060514304,"model":"Samsung SSD","rm":false,"type":"disk"},
    {"name":"sdb","size":1000204886016,"model":"WD Blue","rm":false,"type":"disk"},
    {"name":"sr0","size":1073741312,"model":"Virtual CD","rm":true,"type":"rom"}
  ]
}
''';
        final disks = InstallService.parseLsblkOutput(output);
        expect(disks.length, 2);
        expect(disks[0].name, 'sda');
        expect(disks[0].path, '/dev/sda');
        expect(disks[0].model, 'Samsung SSD');
        expect(disks[1].name, 'sdb');
      });

      test('handles empty disk list', () {
        const output = '{"blockdevices":[]}';
        final disks = InstallService.parseLsblkOutput(output);
        expect(disks, isEmpty);
      });

      test('filters out rom devices', () {
        const output = '''
{
  "blockdevices": [
    {"name":"sr0","size":1073741312,"model":"CD-ROM","rm":true,"type":"rom"},
    {"name":"vda","size":21474836480,"model":null,"rm":false,"type":"disk"}
  ]
}
''';
        final disks = InstallService.parseLsblkOutput(output);
        expect(disks.length, 1);
        expect(disks[0].name, 'vda');
      });
    });

    group('detectPlatform', () {
      test('detects x86 from cpuinfo', () {
        const cpuinfo = 'processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel Core i7\n';
        final platform = InstallService.detectPlatformFromCpuinfo(cpuinfo);
        expect(platform, 'x86');
      });

      test('detects pi4 from cpuinfo', () {
        const cpuinfo = 'Hardware\t: BCM2835\nRevision\t: d03114\nModel\t: Raspberry Pi 4 Model B Rev 1.4\n';
        final platform = InstallService.detectPlatformFromCpuinfo(cpuinfo);
        expect(platform, 'pi4');
      });

      test('detects pi5 from cpuinfo', () {
        const cpuinfo = 'Hardware\t: BCM2835\nRevision\t: c04170\nModel\t: Raspberry Pi 5 Model B Rev 1.0\n';
        final platform = InstallService.detectPlatformFromCpuinfo(cpuinfo);
        expect(platform, 'pi5');
      });
    });

    group('parseDiskoStep', () {
      test('detects sgdisk step', () {
        expect(InstallService.parseDiskoStep('+ sgdisk --clear /dev/sda'), 'Partitioning disk...');
      });

      test('detects mount step', () {
        expect(InstallService.parseDiskoStep('+ mount /dev/disk/by-partlabel/root /mnt'), 'Mounting filesystems...');
      });

      test('detects bootloader step', () {
        expect(InstallService.parseDiskoStep('installing the boot loader...'), 'Installing bootloader...');
      });

      test('returns null for unknown line', () {
        expect(InstallService.parseDiskoStep('some random output'), isNull);
      });
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/f44/dev/blitz/nixblitz/common && dart test test/services/install_service_test.dart`
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Implement InstallService**

```dart
// common/lib/src/services/install_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:common/src/models/install_state.dart';

class InstallService {
  /// List available disks using lsblk.
  Future<List<DiskInfo>> listDisks() async {
    final result = await Process.run('lsblk', [
      '--json', '--bytes', '--output', 'NAME,SIZE,MODEL,RM,TYPE', '--nodeps',
    ]);
    return parseLsblkOutput(result.stdout as String);
  }

  /// Parse lsblk JSON output into DiskInfo list.
  /// Filters out non-disk devices (rom, loop, etc).
  static List<DiskInfo> parseLsblkOutput(String output) {
    final json = jsonDecode(output) as Map<String, dynamic>;
    final devices = json['blockdevices'] as List<dynamic>;
    return devices
        .where((d) => (d['type'] as String) == 'disk')
        .map((d) => DiskInfo.fromLsblkJson(d as Map<String, dynamic>))
        .toList();
  }

  /// Detect platform by reading /proc/cpuinfo.
  Future<String> detectPlatform() async {
    try {
      final content = await File('/proc/cpuinfo').readAsString();
      return detectPlatformFromCpuinfo(content);
    } catch (_) {
      return 'x86';
    }
  }

  /// Parse /proc/cpuinfo to determine platform.
  static String detectPlatformFromCpuinfo(String cpuinfo) {
    if (cpuinfo.contains('Raspberry Pi 5')) return 'pi5';
    if (cpuinfo.contains('Raspberry Pi 4')) return 'pi4';
    if (cpuinfo.contains('Raspberry Pi')) return 'pi4';
    return 'x86';
  }

  /// Get total system memory in MB.
  Future<int> getMemoryMb() async {
    try {
      final content = await File('/proc/meminfo').readAsString();
      final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(content);
      if (match != null) {
        return int.parse(match.group(1)!) ~/ 1024;
      }
    } catch (_) {}
    return 0;
  }

  /// Gather all system info for the install wizard.
  Future<SystemInfo> detectSystem() async {
    final results = await Future.wait([
      detectPlatform(),
      getMemoryMb(),
      listDisks(),
    ]);
    return SystemInfo(
      platform: results[0] as String,
      memoryMb: results[1] as int,
      disks: results[2] as List<DiskInfo>,
    );
  }

  /// Run disko-install and stream output.
  /// [flakePath] is the path to the nixblitz config flake (e.g. ~/nixblitz).
  /// [diskPath] is the target disk (e.g. /dev/sda).
  ({Stream<String> output, Future<int> exitCode}) diskoInstall({
    required String flakePath,
    required String diskPath,
  }) {
    final controller = StreamController<String>();
    final exitCodeFuture = () async {
      final process = await Process.start('sudo', [
        'disko-install',
        '--flake', '$flakePath#nixblitz',
        '--disk', 'main', diskPath,
      ]);

      process.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) => controller.add(line));
      process.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) => controller.add(line));

      final code = await process.exitCode;
      await controller.close();
      return code;
    }();

    return (output: controller.stream, exitCode: exitCodeFuture);
  }

  /// Copy the config directory to the installed system.
  Future<bool> copyConfigToTarget({
    required String sourceDir,
    required String mountPoint,
  }) async {
    // Create target directory
    final targetDir = '$mountPoint/home/admin/nixblitz';
    await Process.run('sudo', ['mkdir', '-p', targetDir]);

    // Copy config
    final rsync = await Process.run('sudo', [
      'rsync', '-av', '--delete', '$sourceDir/', '$targetDir/',
    ]);
    if (rsync.exitCode != 0) return false;

    // Fix ownership (UID 1000 = first normal user)
    final chown = await Process.run('sudo', [
      'chown', '-R', '1000:100', targetDir,
    ]);
    return chown.exitCode == 0;
  }

  /// Parse a disko-install output line to detect progress milestones.
  /// Returns a human-readable step description, or null if the line isn't a milestone.
  static String? parseDiskoStep(String line) {
    if (line.contains('sgdisk')) return 'Partitioning disk...';
    if (line.contains('mkfs') || line.contains('formatting')) return 'Formatting partitions...';
    if (line.contains('mount ')) return 'Mounting filesystems...';
    if (line.contains('copying')) return 'Copying NixOS store paths...';
    if (line.contains('boot loader')) return 'Installing bootloader...';
    return null;
  }
}
```

- [ ] **Step 4: Add export to barrel file**

Add to `common/lib/common.dart`:

```dart
export 'src/services/install_service.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /home/f44/dev/blitz/nixblitz/common && dart test test/services/install_service_test.dart`
Expected: All 8 tests PASS.

- [ ] **Step 6: Commit**

```
feat: add InstallService with disk detection, platform detection, and disko-install
```

---

## Task 3: Install Provider

**Files:**

- Create: `common/lib/src/providers/install_provider.dart`
- Modify: `common/lib/common.dart`

- [ ] **Step 1: Create install provider**

```dart
// common/lib/src/providers/install_provider.dart
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/src/models/install_state.dart';
import 'package:common/src/services/install_service.dart';

final installServiceProvider = Provider<InstallService>((ref) {
  return InstallService();
});

final installStepProvider = StateProvider<InstallStep>((ref) {
  return InstallStep.detectSystem;
});

final systemInfoProvider = FutureProvider<SystemInfo>((ref) async {
  final service = ref.watch(installServiceProvider);
  return service.detectSystem();
});

final selectedDiskProvider = StateProvider<DiskInfo?>((ref) => null);

final installLogProvider = StateProvider<List<String>>((ref) => []);

final installCurrentStepLabelProvider = StateProvider<String>((ref) => '');
```

- [ ] **Step 2: Add export**

Add to `common/lib/common.dart`:

```dart
export 'src/providers/install_provider.dart';
```

- [ ] **Step 3: Verify**

Run: `cd /home/f44/dev/blitz/nixblitz/common && dart analyze`
Expected: No errors.

- [ ] **Step 4: Commit**

```
feat: add Riverpod providers for install flow state
```

---

## Task 4: Update UI State + App Routing

**Files:**

- Modify: `tui/lib/src/providers/ui_state_provider.dart`
- Modify: `tui/lib/src/ui/app.dart`

- [ ] **Step 1: Add install and setup views to AppView enum**

Replace the contents of `tui/lib/src/providers/ui_state_provider.dart`:

```dart
// tui/lib/src/providers/ui_state_provider.dart
import 'package:riverpod/legacy.dart';

enum AppView { install, setup, dashboard, configure, apply }

final currentViewProvider = StateProvider<AppView>((ref) => AppView.dashboard);
final selectedServiceIndexProvider = StateProvider<int>((ref) => 0);
```

- [ ] **Step 2: Update app.dart with startup mode detection**

In `tui/lib/src/ui/app.dart`, update the `NixBlitzApp` to detect mode on startup. The ProviderScope should override `baseDirProvider` and set the initial view.

Replace the `NixBlitzApp` class:

```dart
class NixBlitzApp extends StatelessComponent {
  final String baseDir;

  const NixBlitzApp({super.key, required this.baseDir});

  @override
  Component build(BuildContext context) {
    // Detect startup mode
    final configPath = '$baseDir/config.json';
    final configExists = File(configPath).existsSync();

    AppView initialView;
    if (!configExists) {
      initialView = AppView.install;
    } else {
      // Read initialized flag
      try {
        final content = File(configPath).readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        initialView = json['initialized'] == true
            ? AppView.dashboard
            : AppView.setup;
      } catch (_) {
        initialView = AppView.dashboard;
      }
    }

    return ProviderScope(
      overrides: [
        baseDirProvider.overrideWithValue(baseDir),
        currentViewProvider.overrideWith((ref) => initialView),
      ],
      child: NoctermApp(
        title: 'NixBlitz',
        theme: TuiThemeData.dark.copyWith(
          primary: const Color.fromRGB(247, 147, 26),
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
```

Add imports at top of app.dart:

```dart
import 'dart:convert';
import 'dart:io';
```

- [ ] **Step 3: Update the view switch in \_Shell.build()**

Replace the view switch:

```dart
            Expanded(
              child: switch (context.watch(currentViewProvider)) {
                AppView.install => const InstallView(),
                AppView.setup => const SetupView(),
                AppView.dashboard => const DashboardView(),
                AppView.configure => const ConfigureView(),
                AppView.apply => const ApplyView(),
              },
            ),
```

Add imports:

```dart
import 'views/install_view.dart';
import 'views/setup_view.dart';
```

- [ ] **Step 4: Update the help text to be view-aware**

Replace the static help text with a dynamic one based on current view:

```dart
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                switch (context.watch(currentViewProvider)) {
                  AppView.install => '[Enter]: Select  [j/k]: Navigate',
                  AppView.setup => 'Setting up...',
                  AppView.dashboard => '[c]: Configure  [q]: Quit',
                  AppView.configure => '[j/k]: Navigate  [Enter]: Edit  [Esc]: Back',
                  AppView.apply => '[Esc]: Back (when done)',
                },
                style: const TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
```

- [ ] **Step 5: Update tui/bin/nixblitz.dart to pass baseDir**

Replace the `runApp` call in `tui/bin/nixblitz.dart`:

```dart
    final homeDir = Platform.environment['HOME'] ?? '/root';
    final baseDir = '$homeDir/nixblitz';
    runApp(NixBlitzApp(baseDir: baseDir));
```

Add import:

```dart
import 'dart:io';
```

- [ ] **Step 6: Create stub install_view.dart and setup_view.dart** (so it compiles)

```dart
// tui/lib/src/ui/views/install_view.dart
import 'package:nocterm/nocterm.dart';

class InstallView extends StatelessComponent {
  const InstallView({super.key});

  @override
  Component build(BuildContext context) {
    return const Center(child: Text('Install wizard loading...'));
  }
}
```

```dart
// tui/lib/src/ui/views/setup_view.dart
import 'package:nocterm/nocterm.dart';

class SetupView extends StatelessComponent {
  const SetupView({super.key});

  @override
  Component build(BuildContext context) {
    return const Center(child: Text('First boot setup loading...'));
  }
}
```

- [ ] **Step 7: Verify**

Run: `cd /home/f44/dev/blitz/nixblitz/tui && dart analyze`
Expected: No errors.

- [ ] **Step 8: Commit**

```
feat: add startup mode detection and install/setup view routing
```

---

## Task 5: Install View (Multi-Step Wizard)

**Files:**

- Modify: `tui/lib/src/ui/views/install_view.dart` (replace stub)

This is the main install wizard. It progresses through `InstallStep` values, showing different content at each step.

- [ ] **Step 1: Implement the full InstallView**

```dart
// tui/lib/src/ui/views/install_view.dart
import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../providers/ui_state_provider.dart';

final _diskSelectionIndexProvider = StateProvider<int>((ref) => 0);
final _confirmProvider = StateProvider<bool>((ref) => false);

class InstallView extends StatefulComponent {
  const InstallView({super.key});

  @override
  State<InstallView> createState() => _InstallViewState();
}

class _InstallViewState extends State<InstallView> {
  StreamSubscription<String>? _outputSub;

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  void _startInstall() {
    final baseDirPath = context.read(baseDirProvider);
    final disk = context.read(selectedDiskProvider);
    if (disk == null) return;

    final installService = context.read(installServiceProvider);
    context.read(installStepProvider.notifier).state = InstallStep.installing;
    context.read(installLogProvider.notifier).state = [
      '> disko-install --flake $baseDirPath#nixblitz --disk main ${disk.path}',
      '',
    ];

    final (:output, :exitCode) = installService.diskoInstall(
      flakePath: baseDirPath,
      diskPath: disk.path,
    );

    _outputSub = output.listen((line) {
      final current = context.read(installLogProvider);
      context.read(installLogProvider.notifier).state = [...current, line];

      final stepLabel = InstallService.parseDiskoStep(line);
      if (stepLabel != null) {
        context.read(installCurrentStepLabelProvider.notifier).state = stepLabel;
      }
    });

    exitCode.then((code) async {
      if (code == 0) {
        // Copy config to installed system
        context.read(installCurrentStepLabelProvider.notifier).state = 'Copying config to target...';
        final copied = await installService.copyConfigToTarget(
          sourceDir: baseDirPath,
          mountPoint: '/mnt',
        );
        if (copied) {
          context.read(installStepProvider.notifier).state = InstallStep.complete;
        } else {
          final log = context.read(installLogProvider);
          context.read(installLogProvider.notifier).state = [...log, '\nFailed to copy config to target.'];
          context.read(installStepProvider.notifier).state = InstallStep.failed;
        }
      } else {
        final log = context.read(installLogProvider);
        context.read(installLogProvider.notifier).state = [...log, '\nInstallation failed (exit code $code).'];
        context.read(installStepProvider.notifier).state = InstallStep.failed;
      }
    });
  }

  @override
  Component build(BuildContext context) {
    final step = context.watch(installStepProvider);

    return switch (step) {
      InstallStep.detectSystem => _buildDetectSystem(),
      InstallStep.selectDisk => _buildSelectDisk(),
      InstallStep.configureServices => _buildConfigureServices(),
      InstallStep.confirmInstall => _buildConfirmInstall(),
      InstallStep.installing => _buildInstalling(),
      InstallStep.complete => _buildComplete(),
      InstallStep.failed => _buildFailed(),
    };
  }

  Component _buildDetectSystem() {
    final systemInfoAsync = context.watch(systemInfoProvider);

    return systemInfoAsync.when(
      loading: () => Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NixBlitz Installer',
              style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            const Text('Detecting system...'),
          ],
        ),
      ),
      error: (e, _) => Container(
        padding: const EdgeInsets.all(2),
        child: Text('System detection failed: $e'),
      ),
      data: (info) {
        // Auto-advance to disk selection once detection completes
        Future.microtask(() {
          context.read(installStepProvider.notifier).state = InstallStep.selectDisk;
        });

        return Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NixBlitz Installer',
                style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 1),
              Text('Platform: ${info.platform}'),
              Text('Memory: ${info.memoryMb} MB'),
              Text('Disks found: ${info.disks.length}'),
            ],
          ),
        );
      },
    );
  }

  Component _buildSelectDisk() {
    final systemInfoAsync = context.watch(systemInfoProvider);
    final selectedIndex = context.watch(_diskSelectionIndexProvider);

    return systemInfoAsync.when(
      loading: () => const Text('Loading...'),
      error: (e, _) => Text('Error: $e'),
      data: (info) {
        if (info.disks.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(2),
            child: const Text('No disks found. Cannot install.'),
          );
        }

        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            if (event.logicalKey == LogicalKey.keyJ || event.logicalKey == LogicalKey.arrowDown) {
              if (selectedIndex < info.disks.length - 1) {
                context.read(_diskSelectionIndexProvider.notifier).state = selectedIndex + 1;
              }
              return true;
            }
            if (event.logicalKey == LogicalKey.keyK || event.logicalKey == LogicalKey.arrowUp) {
              if (selectedIndex > 0) {
                context.read(_diskSelectionIndexProvider.notifier).state = selectedIndex - 1;
              }
              return true;
            }
            if (event.logicalKey == LogicalKey.enter) {
              context.read(selectedDiskProvider.notifier).state = info.disks[selectedIndex];
              context.read(installStepProvider.notifier).state = InstallStep.configureServices;
              return true;
            }
            return false;
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select Installation Disk',
                  style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 1),
                Text(
                  'WARNING: The selected disk will be completely erased!',
                  style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
                ),
                const SizedBox(height: 1),
                ...List.generate(info.disks.length, (i) {
                  final disk = info.disks[i];
                  final prefix = i == selectedIndex ? '> ' : '  ';
                  final color = i == selectedIndex
                      ? const Color.fromRGB(247, 147, 26)
                      : const Color.fromRGB(200, 200, 200);
                  return Text('$prefix${disk.displayName}', style: TextStyle(color: color));
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Component _buildConfigureServices() {
    final configAsync = context.watch(configProvider);
    final systemInfoAsync = context.watch(systemInfoProvider);

    return configAsync.when(
      loading: () => const Text('Loading...'),
      error: (e, _) => Text('Error: $e'),
      data: (config) {
        final platform = systemInfoAsync.value?.platform ?? 'x86';

        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            if (event.logicalKey == LogicalKey.enter) {
              // Save config with detected platform, then scaffold and proceed
              Future.microtask(() async {
                final baseDirPath = context.read(baseDirProvider);
                final updatedConfig = config.copyWith(
                  system: config.system.copyWith(platform: platform),
                );

                // Scaffold ~/nixblitz/ from templates
                final scaffoldService = ScaffoldService(
                  templateDir: _findTemplateDir(),
                  targetDir: baseDirPath,
                );
                await scaffoldService.scaffold();

                // Write config and git init
                final configService = context.read(configServiceProvider);
                await configService.writeConfig(updatedConfig);

                final gitService = GitService(repoDir: baseDirPath);
                await gitService.init();
                await gitService.commit('config.json', 'Initial configuration');

                context.read(configProvider.notifier).updateConfig(updatedConfig);
                context.read(installStepProvider.notifier).state = InstallStep.confirmInstall;
              });
              return true;
            }
            if (event.logicalKey == LogicalKey.escape) {
              context.read(installStepProvider.notifier).state = InstallStep.selectDisk;
              return true;
            }
            return false;
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Initial Configuration',
                  style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 1),
                Text('Platform: $platform (auto-detected)'),
                Text('Hostname: ${config.system.hostname}'),
                Text('Bitcoin: ${config.bitcoind.network} (${config.bitcoind.pruned ? "pruned" : "full"})'),
                Text('LND: ${config.lnd.enabled ? "enabled" : "disabled"}'),
                Text('CLN: ${config.cln.enabled ? "enabled" : "disabled"}'),
                const SizedBox(height: 1),
                const Text('Press Enter to continue with these defaults,'),
                const Text('or Esc to go back and change disk.'),
                const SizedBox(height: 1),
                const Text(
                  'Tip: You can change all settings after installation via the TUI.',
                  style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Component _buildConfirmInstall() {
    final disk = context.watch(selectedDiskProvider);
    final confirmed = context.watch(_confirmProvider);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.keyY && !confirmed) {
          context.read(_confirmProvider.notifier).state = true;
          _startInstall();
          return true;
        }
        if (event.logicalKey == LogicalKey.keyN || event.logicalKey == LogicalKey.escape) {
          context.read(installStepProvider.notifier).state = InstallStep.configureServices;
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Confirm Installation',
              style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            Text(
              'ALL DATA ON ${disk?.path ?? "?"} WILL BE DESTROYED!',
              style: const TextStyle(color: Color.fromRGB(255, 80, 80), fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            Text('Disk: ${disk?.displayName ?? "none"}'),
            const SizedBox(height: 1),
            const Text('Press [y] to confirm and start installation.'),
            const Text('Press [n] or Esc to go back.'),
          ],
        ),
      ),
    );
  }

  Component _buildInstalling() {
    final logLines = context.watch(installLogProvider);
    final stepLabel = context.watch(installCurrentStepLabelProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Installing NixOS...',
                style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
              ),
              if (stepLabel.isNotEmpty)
                Text(stepLabel, style: const TextStyle(color: Color.fromRGB(110, 220, 110))),
            ],
          ),
        ),
        const SizedBox(height: 1),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: ListView.builder(
              itemCount: logLines.length,
              itemBuilder: (context, index) {
                return Text(
                  logLines[index],
                  style: const TextStyle(color: Color.fromRGB(180, 180, 200)),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Component _buildComplete() {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter) {
          // Trigger reboot
          Process.run('sudo', ['reboot']);
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installation Complete!',
              style: const TextStyle(color: Color.fromRGB(110, 220, 110), fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            const Text('NixOS has been installed successfully.'),
            const Text('After reboot, SSH in and run nixblitz to continue setup.'),
            const SizedBox(height: 1),
            const Text('Press Enter to reboot now.'),
          ],
        ),
      ),
    );
  }

  Component _buildFailed() {
    final logLines = context.watch(installLogProvider);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape) {
          context.read(installStepProvider.notifier).state = InstallStep.selectDisk;
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
              'Installation Failed',
              style: const TextStyle(color: Color.fromRGB(255, 80, 80), fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 1),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ListView.builder(
                itemCount: logLines.length,
                itemBuilder: (context, index) {
                  return Text(
                    logLines[index],
                    style: const TextStyle(color: Color.fromRGB(180, 180, 200)),
                  );
                },
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: const Text('Press Esc to go back and try again.'),
          ),
        ],
      ),
    );
  }

  /// Find the templates directory. When running from source it's at the repo root.
  /// When installed via Nix, templates are bundled alongside the binary.
  String _findTemplateDir() {
    // Check relative to the executable first
    final execDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$execDir/../share/nixblitz/templates',
      '$execDir/../../templates',
      // Development fallback: relative to CWD
      'templates',
    ];
    for (final path in candidates) {
      if (Directory(path).existsSync()) return path;
    }
    return 'templates';
  }
}
```

- [ ] **Step 2: Verify**

Run: `cd /home/f44/dev/blitz/nixblitz/tui && dart analyze`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat: implement multi-step install wizard view
```

---

## Task 6: First Boot Setup View

**Files:**

- Modify: `tui/lib/src/ui/views/setup_view.dart` (replace stub)

- [ ] **Step 1: Implement setup_view.dart**

```dart
// tui/lib/src/ui/views/setup_view.dart
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../providers/ui_state_provider.dart';

enum SetupStep {
  setPassword,
  waitBitcoind,
  initLightning,
  summary,
}

final _setupStepProvider = StateProvider<SetupStep>((ref) => SetupStep.setPassword);
final _setupLogProvider = StateProvider<List<String>>((ref) => []);
final _passwordInputProvider = StateProvider<String>((ref) => '');

class SetupView extends StatelessComponent {
  const SetupView({super.key});

  @override
  Component build(BuildContext context) {
    final step = context.watch(_setupStepProvider);

    return switch (step) {
      SetupStep.setPassword => _buildSetPassword(context),
      SetupStep.waitBitcoind => _buildWaitBitcoind(context),
      SetupStep.initLightning => _buildInitLightning(context),
      SetupStep.summary => _buildSummary(context),
    };
  }

  Component _buildSetPassword(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter) {
          final password = context.read(_passwordInputProvider);
          if (password.length >= 8) {
            Future.microtask(() async {
              // Set admin user password
              final process = await Process.start('sudo', ['chpasswd']);
              process.stdin.writeln('admin:$password');
              await process.stdin.close();
              await process.exitCode;

              context.read(_setupStepProvider.notifier).state = SetupStep.waitBitcoind;
            });
          }
          return true;
        }
        if (event.logicalKey == LogicalKey.backspace) {
          final current = context.read(_passwordInputProvider);
          if (current.isNotEmpty) {
            context.read(_passwordInputProvider.notifier).state =
                current.substring(0, current.length - 1);
          }
          return true;
        }
        // Accept printable characters
        final char = event.character;
        if (char != null && char.isNotEmpty) {
          context.read(_passwordInputProvider.notifier).state =
              context.read(_passwordInputProvider) + char;
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'First Boot Setup',
              style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            const Text('Set a password for the admin user.'),
            const Text('This password is used for SSH access.'),
            const SizedBox(height: 1),
            Text('Password: ${"*" * context.watch(_passwordInputProvider).length}'),
            const SizedBox(height: 1),
            Text(
              context.watch(_passwordInputProvider).length < 8
                  ? 'Minimum 8 characters'
                  : 'Press Enter to continue',
              style: TextStyle(
                color: context.watch(_passwordInputProvider).length < 8
                    ? const Color.fromRGB(255, 80, 80)
                    : const Color.fromRGB(110, 220, 110),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildWaitBitcoind(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;

    if (config != null && !config.bitcoind.enabled) {
      // Skip to lightning if bitcoind is disabled
      Future.microtask(() {
        context.read(_setupStepProvider.notifier).state = SetupStep.initLightning;
      });
      return const Text('Skipping bitcoind (disabled)...');
    }

    // Poll bitcoind status
    final statusAsync = context.watch(serviceStatusProvider);

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Waiting for Bitcoin daemon...',
            style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 1),
          statusAsync.when(
            loading: () => const Text('Checking service status...'),
            error: (e, _) => Text('Error: $e'),
            data: (statuses) {
              final btcStatus = statuses.firstWhere(
                (s) => s.name == 'bitcoind',
                orElse: () => const ServiceStatus(name: 'bitcoind', state: ServiceState.unknown),
              );
              if (btcStatus.isRunning) {
                Future.microtask(() {
                  context.read(_setupStepProvider.notifier).state = SetupStep.initLightning;
                });
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('bitcoind: ${btcStatus.stateLabel}'),
                  const SizedBox(height: 1),
                  const Text('The Bitcoin daemon needs to be running before'),
                  const Text('Lightning wallet initialization can proceed.'),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Component _buildInitLightning(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;
    final hasLightning = config != null && (config.lnd.enabled || config.cln.enabled);

    if (!hasLightning) {
      // Skip to summary if no lightning enabled
      Future.microtask(() {
        context.read(_setupStepProvider.notifier).state = SetupStep.summary;
      });
      return const Text('Skipping Lightning setup (none enabled)...');
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter) {
          // Mark setup complete
          Future.microtask(() {
            context.read(_setupStepProvider.notifier).state = SetupStep.summary;
          });
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Lightning Wallet Setup',
              style: const TextStyle(color: Color.fromRGB(247, 147, 26), fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            if (config!.lnd.enabled) const Text('LND: A new wallet will be created on first start.'),
            if (config.cln.enabled) const Text('CLN: A new wallet will be created on first start.'),
            const SizedBox(height: 1),
            const Text(
              'IMPORTANT: Back up your wallet seed after creation!',
              style: TextStyle(color: Color.fromRGB(255, 80, 80)),
            ),
            const SizedBox(height: 1),
            const Text('Press Enter to continue.'),
          ],
        ),
      ),
    );
  }

  Component _buildSummary(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter) {
          // Mark initialized and switch to dashboard
          Future.microtask(() async {
            final configAsync = context.read(configProvider);
            final config = configAsync.value;
            if (config != null) {
              final updated = config.copyWith(initialized: true);
              await context.read(configProvider.notifier).updateConfig(updated);

              final baseDirPath = context.read(baseDirProvider);
              final git = GitService(repoDir: baseDirPath);
              await git.commit('config.json', 'Setup complete: mark initialized');
            }
            context.read(currentViewProvider.notifier).state = AppView.dashboard;
          });
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Setup Complete!',
              style: const TextStyle(color: Color.fromRGB(110, 220, 110), fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            const Text('Your NixBlitz node is configured and running.'),
            const SizedBox(height: 1),
            const Text('Remember to:'),
            const Text('  - Back up your Lightning wallet seed'),
            const Text('  - Keep your SSH password safe'),
            const SizedBox(height: 1),
            const Text('Press Enter to go to the dashboard.'),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

Run: `cd /home/f44/dev/blitz/nixblitz/tui && dart analyze`
Expected: No errors.

- [ ] **Step 3: Commit**

```
feat: implement first-boot setup wizard with password, bitcoind wait, and lightning init
```

---

## Task 7: Run All Tests + Final Verification

**Files:** No new files.

- [ ] **Step 1: Run all common tests**

Run: `cd /home/f44/dev/blitz/nixblitz/common && dart test`
Expected: All tests pass (existing 19 + new install service tests).

- [ ] **Step 2: Analyze both packages**

Run: `cd /home/f44/dev/blitz/nixblitz && dart pub get && cd common && dart analyze && cd ../tui && dart analyze`
Expected: No analysis errors.

- [ ] **Step 3: Verify TUI launches with --version**

Run: `cd /home/f44/dev/blitz/nixblitz/tui && dart run bin/nixblitz.dart --version`
Expected: `nixblitz version: 0.1.0`

- [ ] **Step 4: Verify TUI starts in install mode** (when ~/nixblitz/ doesn't exist)

Run: `HOME=/tmp/nixblitz_test_home dart run bin/nixblitz.dart`
Expected: TUI starts and shows "NixBlitz Installer" / "Detecting system..." (will fail to detect system on non-NixOS, but the view renders). Press q to quit.

- [ ] **Step 5: Commit any fixes**

```
fix: address issues found during install flow verification
```
