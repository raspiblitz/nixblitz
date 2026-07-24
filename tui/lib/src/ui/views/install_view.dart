// tui/lib/src/ui/views/install_view.dart
import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/ascii_banner.dart';
import '../widgets/build_progress_panel.dart';
import '../widgets/confirm_prompt.dart';
import '../widgets/experimental_warning.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/spinner.dart';

final _diskSelectionIndexProvider = StateProvider<int>((ref) => 0);

/// "Show all" toggle for the disk picker. When false (default),
/// disks with a [DiskFilterReason] are hidden — only viable
/// install targets render. `[s]` flips this on the picker
/// screen.
final _showAllDisksProvider = StateProvider<bool>((ref) => false);
final _confirmProvider = StateProvider<bool>((ref) => false);
final _confirmSelectionProvider = StateProvider<int>(
  (ref) => 1,
); // 0=install, 1=go back (default safe)

class InstallView extends StatefulComponent {
  const InstallView({super.key});

  @override
  State<InstallView> createState() => _InstallViewState();
}

class _InstallViewState extends State<InstallView> {
  StreamSubscription<String>? _outputSub;
  bool _saving = false;
  Timer? _elapsedTimer;
  InstallProgressTracker? _tracker;

  /// Whether the full `ScrollableLog` is shown instead of the
  /// `BuildProgressPanel` during `InstallStep.installing`.
  /// Toggled by `[l]`.
  bool _logOpen = false;

  /// Seconds since the install kicked off — drives the
  /// "Installing NixOS (Xs)" header. Never reset between steps.
  int _totalSeconds = 0;

  /// Seconds since the current disko step began — drives the
  /// per-step label "mounting drive (Ys)". Reset to 0 each time
  /// `parseDiskoStep` matches a new line.
  int _stepSeconds = 0;
  @override
  void dispose() {
    _outputSub?.cancel();
    _elapsedTimer?.cancel();
    _tracker?.dispose();
    super.dispose();
  }

  void _startElapsedTimer() {
    _totalSeconds = 0;
    _stepSeconds = 0;
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _totalSeconds++;
      _stepSeconds++;
      // Force a rebuild by re-stamping the step label's "(Ys)"
      // suffix. The header's total elapsed reads `_totalSeconds`
      // directly; the rebuild triggered by this provider write
      // re-reads it for free.
      final stepLabel = context.read(installCurrentStepLabelProvider);
      final base = stepLabel.replaceAll(RegExp(r' \(\d+s\)$'), '');
      context.read(installCurrentStepLabelProvider.notifier).state =
          '$base (${_stepSeconds}s)';
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  /// Append [lines] to both the in-memory install log (visible
  /// in the TUI) and `~/nixblitz.log` (the on-disk record). All
  /// install-flow narration should go through here so post-mortem
  /// debugging from the log file isn't missing the "what was
  /// about to happen" context.
  void _appendInstallLog(List<String> lines) {
    for (final line in lines) {
      LogService.info('[install] $line');
    }
    final current = context.read(installLogProvider);
    context.read(installLogProvider.notifier).state = [...current, ...lines];
  }

  Future<void> _startInstall() async {
    try {
      final baseDirPath = context.read(baseDirProvider);
      final disk = context.read(selectedDiskProvider);
      if (disk == null) {
        LogService.error('_startInstall called with no disk selected');
        return;
      }

      // Use the auto-detected platform to pick the install
      // target — pi5 lands on `nixblitz-pi5-installer` (aarch64,
      // upstream Pi 5 modules + our disko-pi5 layout), everything
      // else falls through to the x86 `nixblitz-installer`.
      final platform =
          context.read(systemInfoProvider).value?.platform ?? 'x86';
      final installerAttr = installerAttributeFor(platform);

      LogService.info(
        'Starting install: disk=${disk.path}, flake=$baseDirPath, '
        'platform=$platform, attribute=$installerAttr',
      );
      final installService = context.read(installServiceProvider);
      context.read(installStepProvider.notifier).state = InstallStep.installing;
      context.read(installCurrentStepLabelProvider.notifier).state =
          'Starting...';
      // Reset the in-memory log buffer to empty, then funnel every
      // subsequent line through `_appendInstallLog` so it lands in
      // both the TUI buffer and `~/nixblitz.log`.
      context.read(installLogProvider.notifier).state = const [];

      // Pre-install memory check: live NixOS ISOs size root tmpfs
      // at roughly half RAM, and the NixBlitz eval can spill over
      // that on ≤8 GB hosts (we hit it on a stock 8 GB box —
      // `error: writing to file: No space left on device` mid-eval).
      // Set up zram-backed swap if none is already configured;
      // it's lazy-allocated (no upfront RAM cost) and compresses
      // ~2-3× on Nix store paths.
      _appendInstallLog(['> Pre-install memory check']);
      context.read(installCurrentStepLabelProvider.notifier).state =
          'Checking memory...';
      final swapResult = await installService.ensureSwapForInstall();
      _appendInstallLog(swapResult.log);
      if (!swapResult.succeeded) {
        _appendInstallLog([
          '  WARNING: zram setup failed; install may run out of memory',
          '  if RAM is tight. Continuing anyway.',
        ]);
      }
      _appendInstallLog(['']);

      _appendInstallLog(['> nix flake update nixblitz (refresh remote cache)']);

      // Nix caches git+https inputs aggressively. Force-refresh the nixblitz
      // input so disko-install pins the *current* remote tip in flake.lock,
      // not a stale cached revision.
      final updateResult = runCheckedSync('nix', [
        'flake',
        'update',
        'nixblitz',
      ], workingDirectory: baseDirPath);
      final updateOutput = [
        ...updateResult.stderr.trim().split('\n'),
        ...updateResult.stdout.trim().split('\n'),
      ].where((l) => l.isNotEmpty).toList();
      _appendInstallLog([
        ...updateOutput,
        if (updateResult.exitCode != 0)
          'nix flake update exit=${updateResult.exitCode} (continuing anyway)',
        '',
        '> sudo disko-install --flake $baseDirPath#$installerAttr '
            '--disk main ${disk.path}',
        '',
      ]);

      _startElapsedTimer();

      _tracker = InstallProgressTracker(
        readTotalBytes: () => duSourceBytes(),
        readUsedBytes: () => dfUsedBytes('/mnt/disko-install-root'),
        onChange: (p) {
          // Stream-listener context (not a key handler) — provider write is
          // safe here.
          context.read(installProgressProvider.notifier).state = p;
        },
      );

      final (:output, :exitCode) = installService.diskoInstall(
        flakePath: baseDirPath,
        diskPath: disk.path,
        attribute: installerAttr,
      );

      _outputSub = output.listen(
        (line) {
          LogService.info('[disko] $line');
          final current = context.read(installLogProvider);
          context.read(installLogProvider.notifier).state = [...current, line];
          final stepLabel = InstallService.parseDiskoStep(line);
          if (stepLabel != null) {
            // Only the per-step counter resets; the install-wide
            // total keeps ticking so the header stays useful.
            _stepSeconds = 0;
            context.read(installCurrentStepLabelProvider.notifier).state =
                stepLabel;
          }
          _tracker?.addLine(line);
        },
        onError: (e, st) {
          LogService.error('disko output stream error', e, st);
        },
      );

      exitCode
          .then((code) async {
            _stopElapsedTimer();
            LogService.info('disko-install exited with code $code');
            if (code == 0) {
              context.read(installCurrentStepLabelProvider.notifier).state =
                  'Copying config to target...';
              final homeDir = Platform.environment['HOME'] ?? '/root';
              final copied = await installService.copyConfigToTarget(
                sourceDir: baseDirPath,
                logFile: '$homeDir/nixblitz.log',
                mountPoint: '/mnt',
              );
              if (copied) {
                LogService.info('Config copied to target successfully');
                context.read(installStepProvider.notifier).state =
                    InstallStep.complete;
              } else {
                LogService.error('Failed to copy config to target');
                _appendInstallLog(['', 'Failed to copy config to target.']);
                context.read(installStepProvider.notifier).state =
                    InstallStep.failed;
              }
            } else {
              LogService.error('Installation failed with exit code $code');
              _appendInstallLog(['', 'Installation failed (exit code $code).']);
              context.read(installStepProvider.notifier).state =
                  InstallStep.failed;
            }
          })
          .catchError((e, st) {
            LogService.error('Unexpected error during install', e, st);
            context.read(installStepProvider.notifier).state =
                InstallStep.failed;
          });
    } catch (e, st) {
      LogService.error('Failed to start installation flow', e, st);
      context.read(installStepProvider.notifier).state = InstallStep.failed;
    }
  }

  @override
  Component build(BuildContext context) {
    final step = context.watch(installStepProvider);
    return switch (step) {
      InstallStep.detectSystem => _buildDetectSystem(),
      InstallStep.selectDisk => _buildSelectDisk(),
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
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
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
        Future.microtask(() {
          context.read(installStepProvider.notifier).state =
              InstallStep.selectDisk;
        });
        return Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NixBlitz Installer',
                style: const TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
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
    final showAll = context.watch(_showAllDisksProvider);
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
        // Default mode: only viable disks. If filtering would
        // leave the picker empty (e.g. operator booted from the
        // only attached disk and inserted nothing else), fall
        // back to the unfiltered list — better to surface a
        // tagged warning than no choices at all.
        final viableDisks = info.disks
            .where((d) => d.filterReason == null)
            .toList();
        final visibleDisks = (showAll || viableDisks.isEmpty)
            ? info.disks
            : viableDisks;
        // Keep the selection inside bounds when the visible list
        // shrinks — otherwise toggling Show-all off after picking
        // a filtered disk indexes off the end.
        final clampedIndex = selectedIndex
            .clamp(0, visibleDisks.length - 1)
            .toInt();
        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            try {
              if (event.logicalKey == LogicalKey.keyJ ||
                  event.logicalKey == LogicalKey.arrowDown) {
                if (clampedIndex < visibleDisks.length - 1) {
                  context.read(_diskSelectionIndexProvider.notifier).state =
                      clampedIndex + 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyK ||
                  event.logicalKey == LogicalKey.arrowUp) {
                if (clampedIndex > 0) {
                  context.read(_diskSelectionIndexProvider.notifier).state =
                      clampedIndex - 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyS) {
                // Toggle Show-all. Reset the selection so the
                // cursor doesn't land on a hidden disk on the
                // way back to filtered mode.
                context.read(_showAllDisksProvider.notifier).state = !showAll;
                context.read(_diskSelectionIndexProvider.notifier).state = 0;
                return true;
              }
              if (event.logicalKey == LogicalKey.enter) {
                context.read(selectedDiskProvider.notifier).state =
                    visibleDisks[clampedIndex];
                final config = context.read(configProvider).value;
                if (config == null) {
                  LogService.error(
                    'Disk picker Enter: config not loaded yet, '
                    'cannot scaffold and proceed',
                  );
                  return true;
                }
                final platform =
                    context.read(systemInfoProvider).value?.platform ?? 'x86';
                _saveConfigAndProceed(config, platform);
                return true;
              }
              return false;
            } catch (e, st) {
              LogService.error('Select disk key handler failed', e, st);
              return true;
            }
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AsciiBanner(),
                const SizedBox(height: 1),
                const ExperimentalWarning(),
                const SizedBox(height: 1),
                Text(
                  'Select Installation Disk',
                  style: const TextStyle(
                    color: Color.fromRGB(247, 147, 26),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'WARNING: The selected disk will be completely erased!',
                  style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
                ),
                const SizedBox(height: 1),
                ...List.generate(visibleDisks.length, (i) {
                  final disk = visibleDisks[i];
                  final prefix = i == clampedIndex ? '> ' : '  ';
                  final color = i == clampedIndex
                      ? const Color.fromRGB(247, 147, 26)
                      : disk.filterReason != null
                      ? const Color.fromRGB(150, 150, 180)
                      : const Color.fromRGB(200, 200, 200);
                  // Annotate filtered disks with their reason so
                  // the operator can see WHY they'd normally be
                  // hidden if they show-all'd to find them.
                  final tag = disk.filterReason == null
                      ? ''
                      : '   [${disk.filterReason!.label}]';
                  return Text(
                    '$prefix${disk.displayName}$tag',
                    style: TextStyle(color: color),
                  );
                }),
                const SizedBox(height: 1),
                _buildDiskPickerFooter(
                  showAll: showAll,
                  hiddenCount: info.disks.length - viableDisks.length,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Footer hint for the disk picker. Reflects whether the
  /// "Show all" toggle is currently on, and how many disks the
  /// filter is hiding (so the operator knows the toggle is
  /// useful even if every visible disk happens to be viable).
  Component _buildDiskPickerFooter({
    required bool showAll,
    required int hiddenCount,
  }) {
    final dim = const TextStyle(color: Color.fromRGB(150, 150, 180));
    if (showAll) {
      return Text(
        '[↑/↓ j/k] move   [Enter] select   [s] hide non-viable',
        style: dim,
      );
    }
    if (hiddenCount > 0) {
      return Text(
        '[↑/↓ j/k] move   [Enter] select   '
        '[s] show all ($hiddenCount hidden)',
        style: dim,
      );
    }
    return Text('[↑/↓ j/k] move   [Enter] select', style: dim);
  }

  void _saveConfigAndProceed(NixblitzConfig config, String platform) {
    if (_saving) return;
    _saving = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final configNotifier = context.read(configProvider.notifier);
      final configService = context.read(configServiceProvider);

      // Persist the disk path the operator picked alongside the
      // other config bits — disko-x86's `device` reads it on
      // every subsequent rebuild. Without this, post-install
      // rebuilds on bare metal try to install GRUB onto the
      // disko default (`/dev/vda`) instead of the actual install
      // target, which fails with `cannot find a GRUB drive`.
      final selectedDisk = context.read(selectedDiskProvider);
      final diskDevice = selectedDisk?.path ?? '';

      LogService.info(
        'Save config start: platform=$platform, disk=$diskDevice',
      );

      // Build updated config by setting platform and disk. Bitcoind
      // network and other app config are seeded by the wizard's
      // installBitcoindPlugin step on first boot — install-time has
      // no app config UI by design.
      var updatedConfig = config.copyWith(
        system: config.system.copyWith(
          platform: platform,
          diskDevice: diskDevice,
        ),
      );
      LogService.info('Save config: updated config prepared');

      final scaffold = ScaffoldService(targetDir: baseDirPath);

      LogService.info('Save config: removing previous $baseDirPath');
      scaffold.clearTargetSync();

      LogService.info('Save config: scaffolding templates to $baseDirPath');
      final written = scaffold.refreshTemplatesSync();
      LogService.info('Save config: scaffold complete ($written files)');

      configService.writeConfigSync(updatedConfig);
      LogService.info('Save config: config.json written');

      // Generate hardware-configuration.nix from the live system,
      // stripped of fileSystems/swapDevices since disko manages those.
      LogService.info('Save config: generating hardware-configuration.nix');
      if (scaffold.writeStrippedHardwareConfigSync()) {
        LogService.info('Save config: hardware-configuration.nix generated');
      } else {
        LogService.error('Save config: nixos-generate-config failed');
      }

      final git = context.read(gitServiceProvider);
      if (!git.initSync()) {
        throw StateError('git init failed in $baseDirPath');
      }
      if (!git.commitAllSync(
        'Initial configuration (schema v$currentConfigVersion)',
      )) {
        throw StateError('git commit failed in $baseDirPath');
      }
      LogService.info('Save config: git repository initialized and committed');

      configNotifier.updateConfig(updatedConfig);
      context.read(installStepProvider.notifier).state =
          InstallStep.confirmInstall;
      LogService.info('Save config: moved to confirm install step');
    } catch (e, st) {
      LogService.error('Failed to save config and scaffold', e, st);
    } finally {
      _saving = false;
    }
  }

  Component _buildConfirmInstall() {
    final disk = context.watch(selectedDiskProvider);
    final confirmIndex = context.watch(_confirmSelectionProvider);

    return ConfirmPrompt(
      title: 'Confirm Installation',
      warning: 'ALL DATA ON ${disk?.path ?? "?"} WILL BE DESTROYED!',
      details: ['Disk: ${disk?.displayName ?? "none"}'],
      confirmLabel: 'Yes, start installation',
      cancelLabel: 'No, go back',
      selectedIndex: confirmIndex,
      onHighlight: (index) {
        context.read(_confirmSelectionProvider.notifier).state = index;
      },
      onConfirm: () {
        context.read(_confirmProvider.notifier).state = true;
        _startInstall();
      },
      onCancel: () {
        context.read(installStepProvider.notifier).state =
            InstallStep.selectDisk;
      },
    );
  }

  Component _buildInstalling() {
    final progress = context.watch(installProgressProvider);
    final logLines = context.watch(installLogProvider);

    // Panel is the default view; [l] reveals the full scrollable log
    // (with its own header, since BuildProgressPanel's compact tail
    // isn't meant to replace it). Retry/failure routing lives in
    // `exitCode.then(...)` inside `_startInstall` and is untouched here.
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyL) {
            setState(() => _logOpen = !_logOpen);
            return true;
          }
          return false; // let ScrollableLog handle scroll keys when open
        } catch (e, st) {
          LogService.error('install progress key handler failed', e, st);
          return true;
        }
      },
      child: _logOpen
          ? Container(
              padding: const EdgeInsets.all(2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Spinner(label: 'Installing NixOS...'),
                      Text(
                        ' (${_formatElapsed(_totalSeconds)})',
                        style: const TextStyle(
                          color: Color.fromRGB(150, 150, 180),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Expanded(
                    child: ScrollableLog(lines: logLines, focused: true),
                  ),
                  const SizedBox(height: 1),
                  const Text(
                    '[l] back to progress',
                    style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                  ),
                ],
              ),
            )
          : BuildProgressPanel(
              progress: progress,
              elapsedSeconds: _totalSeconds,
              recentLines: logLines,
            ),
    );
  }

  String _formatElapsed(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  Component _buildComplete() {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            runCheckedSync('sudo', ['-n', 'reboot']);
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Complete step key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installation Complete!',
              style: const TextStyle(
                color: Color.fromRGB(110, 220, 110),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text('NixOS has been installed successfully.'),
            const Text(
              'After reboot, SSH in and run nixblitz to continue setup.',
            ),
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
        try {
          if (event.logicalKey == LogicalKey.escape) {
            context.read(installStepProvider.notifier).state =
                InstallStep.selectDisk;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Failed step key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installation Failed',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: logLines, focused: true)),
            const SizedBox(height: 1),
            const Text(
              '[Esc] back to disk picker',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}
