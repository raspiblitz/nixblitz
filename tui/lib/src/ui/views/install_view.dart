// tui/lib/src/ui/views/install_view.dart
import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/confirm_prompt.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/select_popup.dart';
import '../widgets/spinner.dart';

final _diskSelectionIndexProvider = StateProvider<int>((ref) => 0);
final _confirmProvider = StateProvider<bool>((ref) => false);
final _confirmSelectionProvider = StateProvider<int>((ref) => 1); // 0=install, 1=go back (default safe)
final _configOptionIndexProvider = StateProvider<int>((ref) => 0);
// Initial config choices
const _networks = ['mainnet', 'testnet', 'signet'];

enum _LightningChoice { none, lnd, cln }

final _networkIndexProvider = StateProvider<int>((ref) => 0); // mainnet
final _lightningChoiceProvider = StateProvider<_LightningChoice>(
  (ref) => _LightningChoice.none,
);

// Which popup is open (null = none)
enum _PopupType { network, lightning }

final _activePopupProvider = StateProvider<_PopupType?>((ref) => null);
final _popupSelectionIndexProvider = StateProvider<int>((ref) => 0);

class InstallView extends StatefulComponent {
  const InstallView({super.key});

  @override
  State<InstallView> createState() => _InstallViewState();
}

class _InstallViewState extends State<InstallView> {
  StreamSubscription<String>? _outputSub;
  bool _saving = false;
  Timer? _elapsedTimer;
  int _elapsedSeconds = 0;
  @override
  void dispose() {
    _outputSub?.cancel();
    _elapsedTimer?.cancel();
    super.dispose();
  }

  void _startElapsedTimer() {
    _elapsedSeconds = 0;
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSeconds++;
      // Force a rebuild by updating the step label with elapsed time
      final stepLabel = context.read(installCurrentStepLabelProvider);
      final base = stepLabel.replaceAll(RegExp(r' \(\d+s\)$'), '');
      context.read(installCurrentStepLabelProvider.notifier).state =
          '$base (${_elapsedSeconds}s)';
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  void _startInstall() {
    try {
      final baseDirPath = context.read(baseDirProvider);
      final disk = context.read(selectedDiskProvider);
      if (disk == null) {
        LogService.error('_startInstall called with no disk selected');
        return;
      }

      LogService.info(
        'Starting install: disk=${disk.path}, flake=$baseDirPath',
      );
      final installService = context.read(installServiceProvider);
      context.read(installStepProvider.notifier).state = InstallStep.installing;
      context.read(installCurrentStepLabelProvider.notifier).state = 'Starting...';
      context.read(installLogProvider.notifier).state = [
        '> disko-install --flake $baseDirPath#nixblitz --disk main ${disk.path}',
        '',
      ];

      _startElapsedTimer();

      final (:output, :exitCode) = installService.diskoInstall(
        flakePath: baseDirPath,
        diskPath: disk.path,
      );

      _outputSub = output.listen(
        (line) {
          LogService.info('[disko] $line');
          final current = context.read(installLogProvider);
          context.read(installLogProvider.notifier).state = [...current, line];
          final stepLabel = InstallService.parseDiskoStep(line);
          if (stepLabel != null) {
            _elapsedSeconds = 0; // reset timer on new step
            context.read(installCurrentStepLabelProvider.notifier).state =
                stepLabel;
          }
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
                final log = context.read(installLogProvider);
                context.read(installLogProvider.notifier).state = [
                  ...log,
                  '\nFailed to copy config to target.',
                ];
                context.read(installStepProvider.notifier).state =
                    InstallStep.failed;
              }
            } else {
              LogService.error('Installation failed with exit code $code');
              final log = context.read(installLogProvider);
              context.read(installLogProvider.notifier).state = [
                ...log,
                '\nInstallation failed (exit code $code).',
              ];
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
            try {
              if (event.logicalKey == LogicalKey.keyJ ||
                  event.logicalKey == LogicalKey.arrowDown) {
                if (selectedIndex < info.disks.length - 1) {
                  context.read(_diskSelectionIndexProvider.notifier).state =
                      selectedIndex + 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyK ||
                  event.logicalKey == LogicalKey.arrowUp) {
                if (selectedIndex > 0) {
                  context.read(_diskSelectionIndexProvider.notifier).state =
                      selectedIndex - 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.enter) {
                context.read(selectedDiskProvider.notifier).state =
                    info.disks[selectedIndex];
                context.read(installStepProvider.notifier).state =
                    InstallStep.configureServices;
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
                ...List.generate(info.disks.length, (i) {
                  final disk = info.disks[i];
                  final prefix = i == selectedIndex ? '> ' : '  ';
                  final color = i == selectedIndex
                      ? const Color.fromRGB(247, 147, 26)
                      : const Color.fromRGB(200, 200, 200);
                  return Text(
                    '$prefix${disk.displayName}',
                    style: TextStyle(color: color),
                  );
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
    final selectedOption = context.watch(_configOptionIndexProvider);
    final networkIndex = context.watch(_networkIndexProvider);
    final lightningChoice = context.watch(_lightningChoiceProvider);
    final activePopup = context.watch(_activePopupProvider);
    final popupIndex = context.watch(_popupSelectionIndexProvider);

    return configAsync.when(
      loading: () => const Text('Loading...'),
      error: (e, _) => Text('Error: $e'),
      data: (config) {
        final platform = systemInfoAsync.value?.platform ?? 'x86';
        const optionCount = 3; // 0=network, 1=lightning, 2=continue

        // If a popup is open, show it as an overlay
        if (activePopup != null) {
          return _buildPopup(
            activePopup,
            popupIndex,
            networkIndex,
            lightningChoice,
          );
        }

        return Focusable(
          focused: true,
          onKeyEvent: (event) {
            try {
              if (event.logicalKey == LogicalKey.keyJ ||
                  event.logicalKey == LogicalKey.arrowDown) {
                if (selectedOption < optionCount - 1) {
                  context.read(_configOptionIndexProvider.notifier).state =
                      selectedOption + 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.keyK ||
                  event.logicalKey == LogicalKey.arrowUp) {
                if (selectedOption > 0) {
                  context.read(_configOptionIndexProvider.notifier).state =
                      selectedOption - 1;
                }
                return true;
              }
              if (event.logicalKey == LogicalKey.enter ||
                  event.logicalKey == LogicalKey.space) {
                if (selectedOption == 0) {
                  context.read(_popupSelectionIndexProvider.notifier).state =
                      networkIndex;
                  context.read(_activePopupProvider.notifier).state =
                      _PopupType.network;
                  return true;
                }
                if (selectedOption == 1) {
                  context.read(_popupSelectionIndexProvider.notifier).state =
                      lightningChoice.index;
                  context.read(_activePopupProvider.notifier).state =
                      _PopupType.lightning;
                  return true;
                }
                if (selectedOption == 2) {
                  _saveConfigAndProceed(
                    config,
                    platform,
                    networkIndex,
                    lightningChoice,
                  );
                  return true;
                }
              }
              if (event.logicalKey == LogicalKey.escape) {
                context.read(installStepProvider.notifier).state =
                    InstallStep.selectDisk;
                return true;
              }
              return false;
            } catch (e, st) {
              LogService.error('Configure services key handler failed', e, st);
              return true;
            }
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Initial Configuration',
                  style: const TextStyle(
                    color: Color.fromRGB(247, 147, 26),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Platform: $platform (auto-detected)',
                  style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
                const SizedBox(height: 1),
                _configLine(
                  label: 'Network',
                  value: _networks[networkIndex],
                  focused: selectedOption == 0,
                ),
                _configLine(
                  label: 'Lightning',
                  value: _lightningLabel(lightningChoice),
                  focused: selectedOption == 1,
                ),
                const SizedBox(height: 1),
                Text(
                  selectedOption == 2
                      ? '> [ Continue with installation ]'
                      : '  [ Continue with installation ]',
                  style: TextStyle(
                    color: selectedOption == 2
                        ? const Color.fromRGB(247, 147, 26)
                        : const Color.fromRGB(200, 200, 200),
                    fontWeight: selectedOption == 2
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '↑/↓ navigate  Enter select  Esc back',
                  style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Component _buildPopup(
    _PopupType type,
    int popupIndex,
    int networkIndex,
    _LightningChoice lightningChoice,
  ) {
    final String title;
    final List<String> options;
    final int currentIndex;

    switch (type) {
      case _PopupType.network:
        title = 'Select Network';
        options = _networks;
        currentIndex = popupIndex;
      case _PopupType.lightning:
        title = 'Select Lightning';
        options = ['None', 'LND', 'CLN'];
        currentIndex = popupIndex;
    }

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Initial Configuration',
            style: const TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          SelectPopup(
            title: title,
            options: options,
            selectedIndex: currentIndex,
            onHighlight: (index) {
              context.read(_popupSelectionIndexProvider.notifier).state = index;
            },
            onConfirm: (index) {
              switch (type) {
                case _PopupType.network:
                  context.read(_networkIndexProvider.notifier).state = index;
                case _PopupType.lightning:
                  context.read(_lightningChoiceProvider.notifier).state =
                      _LightningChoice.values[index];
              }
              context.read(_activePopupProvider.notifier).state = null;
            },
            onCancel: () {
              context.read(_activePopupProvider.notifier).state = null;
            },
          ),
        ],
      ),
    );
  }

  Component _configLine({
    required String label,
    required String value,
    required bool focused,
  }) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    return Text('$prefix$label: $value', style: TextStyle(color: color));
  }

  String _lightningLabel(_LightningChoice choice) {
    return switch (choice) {
      _LightningChoice.none => 'None',
      _LightningChoice.lnd => 'LND',
      _LightningChoice.cln => 'CLN',
    };
  }

  void _saveConfigAndProceed(
    NixblitzConfig config,
    String platform,
    int networkIndex,
    _LightningChoice lightningChoice,
  ) {
    if (_saving) return;
    _saving = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final configNotifier = context.read(configProvider.notifier);
      final configService = context.read(configServiceProvider);

      LogService.info(
        'Save config start: network=${_networks[networkIndex]}, lightning=${_lightningLabel(lightningChoice)}, platform=$platform',
      );

      final updatedConfig = config.copyWith(
        system: config.system.copyWith(platform: platform),
        bitcoind: config.bitcoind.copyWith(network: _networks[networkIndex]),
        lnd: config.lnd.copyWith(
          enabled: lightningChoice == _LightningChoice.lnd,
        ),
        cln: config.cln.copyWith(
          enabled: lightningChoice == _LightningChoice.cln,
        ),
      );
      LogService.info('Save config: updated config prepared');

      final targetDir = Directory(baseDirPath);
      if (targetDir.existsSync()) {
        LogService.info('Save config: removing previous $baseDirPath');
        // Use rm -rf via sudo in case previous files are read-only (e.g. from nix store)
        final rmResult = Process.runSync('rm', ['-rf', baseDirPath]);
        if (rmResult.exitCode != 0) {
          LogService.warn('rm -rf failed, trying with sudo');
          Process.runSync('sudo', ['rm', '-rf', baseDirPath]);
        }
      }

      LogService.info('Save config: scaffolding templates to $baseDirPath');
      final templates = EmbeddedTemplates.getAll();
      for (final entry in templates.entries) {
        final file = File('$baseDirPath/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
      LogService.info(
        'Save config: scaffold complete (${templates.length} files)',
      );

      configService.writeConfigSync(updatedConfig);
      LogService.info('Save config: config.json written');

      // Generate hardware-configuration.nix from the live system
      // We strip fileSystems and swapDevices since disko manages those.
      LogService.info('Save config: generating hardware-configuration.nix');
      final genResult = Process.runSync('nixos-generate-config', [
        '--show-hardware-config',
      ]);
      if (genResult.exitCode == 0) {
        final hwConfig = _stripFileSystems(genResult.stdout as String);
        final hwConfigPath = '$baseDirPath/hardware-configuration.nix';
        File(hwConfigPath).writeAsStringSync(hwConfig);
        LogService.info('Save config: hardware-configuration.nix generated');
      } else {
        LogService.error('nixos-generate-config failed: ${genResult.stderr}');
      }

      ProcessResult runGit(List<String> args) {
        final result = Process.runSync(
          'git',
          args,
          workingDirectory: baseDirPath,
        );
        LogService.info(
          'Save config: git ${args.join(" ")} exit=${result.exitCode}',
        );
        if (result.exitCode != 0) {
          final stderr = result.stderr.toString().trim();
          final stdout = result.stdout.toString().trim();
          final details = [
            if (stderr.isNotEmpty) 'stderr=$stderr',
            if (stdout.isNotEmpty) 'stdout=$stdout',
          ].join(' | ');
          throw ProcessException(
            'git',
            args,
            details.isEmpty ? 'git command failed' : details,
            result.exitCode,
          );
        }
        return result;
      }

      runGit(['init']);
      runGit(['config', 'user.email', 'nixblitz@localhost']);
      runGit(['config', 'user.name', 'NixBlitz']);
      runGit(['add', '.']);
      runGit([
        'commit',
        '-m',
        'Initial configuration (schema v$currentConfigVersion)',
      ]);
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
            InstallStep.configureServices;
      },
    );
  }

  Component _buildInstalling() {
    final logLines = context.watch(installLogProvider);
    final stepLabel = context.watch(installCurrentStepLabelProvider);

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Spinner(label: 'Installing NixOS...'),
              Text(
                ' (${_formatElapsed(_elapsedSeconds)})',
                style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            ],
          ),
          if (stepLabel.isNotEmpty)
            Text(
              stepLabel,
              style: const TextStyle(color: Color.fromRGB(110, 220, 110)),
            ),
          const SizedBox(height: 1),
          Expanded(child: ScrollableLog(lines: logLines)),
        ],
      ),
    );
  }

  String _formatElapsed(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  /// Strip fileSystems and swapDevices blocks from generated hardware-configuration.nix.
  /// Disko manages these, so they conflict if left in.
  ///
  /// Handles the nixos-generate-config format where blocks look like:
  ///   fileSystems."/" =
  ///     { device = "tmpfs";
  ///       fsType = "tmpfs";
  ///     };
  ///   swapDevices = [ ];
  static String _stripFileSystems(String hwConfig) {
    final lines = hwConfig.split('\n');
    final result = <String>[];
    var skipping = false;
    var braceDepth = 0;

    for (final line in lines) {
      final trimmed = line.trimLeft();

      if (!skipping) {
        // Detect start of blocks to skip
        if (trimmed.startsWith('fileSystems.') ||
            trimmed.startsWith('fileSystems ') ||
            trimmed.startsWith('swapDevices')) {
          skipping = true;
          braceDepth = 0;

          // Track braces/brackets on this line
          for (final c in line.codeUnits) {
            if (c == 123 || c == 91) braceDepth++; // { or [
            if (c == 125 || c == 93) braceDepth--; // } or ]
          }

          // Check if the statement ends with ;
          if (trimmed.endsWith(';')) {
            skipping = false;
          }
          continue;
        }
        result.add(line);
      } else {
        // We're inside a block — track depth
        for (final c in line.codeUnits) {
          if (c == 123 || c == 91) braceDepth++;
          if (c == 125 || c == 93) braceDepth--;
        }

        // Block ends when we hit the closing ; at depth 0
        if (trimmed.endsWith(';') && braceDepth <= 0) {
          skipping = false;
        }
      }
    }

    return result.join('\n');
  }

  Component _buildComplete() {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            Process.run('sudo', ['reboot']);
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
            Expanded(child: ScrollableLog(lines: logLines)),
            const SizedBox(height: 1),
            const Text('Press Esc to go back and try again.'),
          ],
        ),
      ),
    );
  }
}
