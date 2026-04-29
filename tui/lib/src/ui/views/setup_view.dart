import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/password_input.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';

enum SetupStep {
  setPassword,
  buildServices,
  waitBitcoind,
  initLightning,
  summary,
}

final _setupStepProvider = StateProvider<SetupStep>(
  (ref) => SetupStep.setPassword,
);

final _buildServicesLogProvider = StateProvider<List<String>>((ref) => []);
final _buildServicesExitCodeProvider = StateProvider<int?>((ref) => null);

class SetupView extends StatefulComponent {
  const SetupView({super.key});

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> {
  StreamSubscription<String>? _buildServicesSub;
  bool _buildServicesStarted = false;

  @override
  void dispose() {
    _buildServicesSub?.cancel();
    super.dispose();
  }

  void _startBuildServices() {
    if (_buildServicesStarted) return;
    _buildServicesStarted = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final configAsync = context.read(configProvider);
      final config = configAsync.value;
      if (config == null) {
        _appendBuildLog('Error: config not loaded');
        context.read(_buildServicesExitCodeProvider.notifier).state = 1;
        return;
      }

      _appendBuildLog('> Enabling services (initialized=true)');
      final updated = config.copyWith(initialized: true);
      final configService = context.read(configServiceProvider);
      configService.writeConfigSync(updated);
      LogService.info('BuildServices: wrote initialized=true');

      _appendBuildLog('> git add + commit');
      final gitAdd = Process.runSync(
        'git',
        ['add', 'config.json'],
        workingDirectory: baseDirPath,
      );
      if (gitAdd.exitCode != 0) {
        _appendBuildLog('git add failed: ${gitAdd.stderr}');
      }
      final gitCommit = Process.runSync(
        'git',
        ['commit', '-m', 'Enable services (first boot)'],
        workingDirectory: baseDirPath,
      );
      _appendBuildLog('git commit exit=${gitCommit.exitCode}');

      context.read(configProvider.notifier).updateConfig(updated);

      final attr = rebuildAttributeFor(updated.system.platform);
      _appendBuildLog('');
      _appendBuildLog(
        '> sudo nixos-rebuild switch --flake $baseDirPath#$attr',
      );
      _appendBuildLog('');

      final systemService = context.read(systemServiceProvider);
      final (:output, :exitCode) =
          systemService.rebuild(baseDirPath, attribute: attr);

      _buildServicesSub = output.listen(
        (line) {
          LogService.info('[build-services] $line');
          _appendBuildLog(line);
        },
        onError: (e, st) {
          LogService.error('BuildServices output stream error', e, st);
        },
      );

      exitCode
          .then((code) {
            LogService.info('BuildServices: rebuild exited with code $code');
            context.read(_buildServicesExitCodeProvider.notifier).state = code;
            if (code == 0) {
              context.read(_setupStepProvider.notifier).state =
                  SetupStep.waitBitcoind;
            }
          })
          .catchError((e, st) {
            LogService.error('BuildServices rebuild failed', e, st);
            context.read(_buildServicesExitCodeProvider.notifier).state = 1;
          });
    } catch (e, st) {
      LogService.error('BuildServices start failed', e, st);
      _appendBuildLog('Error: $e');
      context.read(_buildServicesExitCodeProvider.notifier).state = 1;
    }
  }

  void _appendBuildLog(String line) {
    final current = context.read(_buildServicesLogProvider);
    context.read(_buildServicesLogProvider.notifier).state = [...current, line];
  }

  void _retryBuildServices() {
    _buildServicesSub?.cancel();
    _buildServicesSub = null;
    _buildServicesStarted = false;
    context.read(_buildServicesLogProvider.notifier).state = [];
    context.read(_buildServicesExitCodeProvider.notifier).state = null;
  }

  @override
  Component build(BuildContext context) {
    final step = context.watch(_setupStepProvider);
    return switch (step) {
      SetupStep.setPassword => _buildSetPassword(),
      SetupStep.buildServices => _buildBuildServices(),
      SetupStep.waitBitcoind => _buildWaitBitcoind(),
      SetupStep.initLightning => _buildInitLightning(),
      SetupStep.summary => _buildSummary(),
    };
  }

  Component _buildSetPassword() {
    return PasswordInput(
      title: 'First Boot Setup',
      subtitle: 'Set a password for the admin user. Used for SSH access.',
      minLength: 8,
      requireConfirmation: true,
      onSubmit: (password) {
        // First boot: the SudoSession will prompt for the *current*
        // admin password ("nixblitz", the initialPassword baked into
        // installed.nix). After auth, chpasswd runs silently and sets
        // the new password.
        final session = context.read(sudoSessionProvider);
        session.ensureFresh().then((ok) async {
          if (!ok) {
            LogService.error(
              'First-boot chpasswd: sudo authorization cancelled or failed',
            );
            // Stay on the password step so the user can retry.
            return;
          }
          final stdin =
              Uint8List.fromList(utf8.encode('admin:$password\n'));
          final res =
              await session.runOneShot(['chpasswd'], stdinBytes: stdin);
          if (res.exitCode != 0) {
            LogService.error(
              'chpasswd failed: exit=${res.exitCode} '
              'stderr=${res.stderr}',
            );
            return;
          }
          LogService.info('Password set successfully');
          context.read(_setupStepProvider.notifier).state =
              SetupStep.buildServices;
        });
      },
    );
  }

  /// Bootstraps the service stack on first boot.
  ///
  /// The initial install ships a minimal NixOS (`initialized: false` gates all
  /// service features off) so the build fits in the live ISO's tmpfs. Here, on
  /// the real disk, we flip `initialized` to true and run `nixos-rebuild switch`
  /// to bring up bitcoind/LND/CLN/blitz-api/blitz-web.
  Component _buildBuildServices() {
    final configAsync = context.watch(configProvider);
    final logLines = context.watch(_buildServicesLogProvider);
    final exitCode = context.watch(_buildServicesExitCodeProvider);

    // Wait for the config to load before kicking off the rebuild. Without
    // this, the first render after the password step sees configAsync.value
    // still null (ProviderScope is still initializing it) and we'd bail out
    // into the failure state.
    if (!_buildServicesStarted && configAsync.value != null) {
      Future.microtask(_startBuildServices);
    }

    final isRunning = exitCode == null;

    if (isRunning) {
      return Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Spinner(label: 'Building services'),
              ],
            ),
            const Text(
              'Running nixos-rebuild. This may take several minutes.',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: logLines, focused: true)),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [/] search',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      );
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            _retryBuildServices();
            return true;
          }
          if (event.logicalKey == LogicalKey.escape) {
            context.read(currentViewProvider.notifier).state =
                AppView.dashboard;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('BuildServices failure key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Service build failed',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: logLines, focused: true)),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [/] search   '
              '[Enter] retry   [Esc] dashboard',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildWaitBitcoind() {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;

    if (config != null && !config.bitcoind.enabled) {
      Future.microtask(() {
        context.read(_setupStepProvider.notifier).state =
            SetupStep.initLightning;
      });
      return const Text('Skipping bitcoind (disabled)...');
    }

    final statusAsync = context.watch(serviceStatusProvider);
    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Waiting for Bitcoin daemon...',
            style: const TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          statusAsync.when(
            loading: () => const Text('Checking service status...'),
            error: (e, _) => Text('Error: $e'),
            data: (statuses) {
              final btcStatus = statuses.firstWhere(
                (s) => s.name == 'bitcoind',
                orElse: () => const ServiceStatus(
                  name: 'bitcoind',
                  state: ServiceState.unknown,
                ),
              );
              if (btcStatus.isRunning) {
                Future.microtask(() {
                  context.read(_setupStepProvider.notifier).state =
                      SetupStep.initLightning;
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

  Component _buildInitLightning() {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;
    final hasLightning =
        config != null && (config.lnd.enabled || config.cln.enabled);

    if (!hasLightning) {
      Future.microtask(() {
        context.read(_setupStepProvider.notifier).state = SetupStep.summary;
      });
      return const Text('Skipping Lightning setup (none enabled)...');
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            context.read(_setupStepProvider.notifier).state = SetupStep.summary;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Init lightning key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Lightning Wallet Setup',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            if (config.lnd.enabled)
              const Text('LND: A new wallet will be created on first start.'),
            if (config.cln.enabled)
              const Text('CLN: A new wallet will be created on first start.'),
            const SizedBox(height: 1),
            Text(
              'IMPORTANT: Back up your wallet seed after creation!',
              style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
            ),
            const SizedBox(height: 1),
            const Text('Press Enter to continue.'),
          ],
        ),
      ),
    );
  }

  Component _buildSummary() {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            context.read(currentViewProvider.notifier).state =
                AppView.dashboard;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Setup summary key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Setup Complete!',
              style: const TextStyle(
                color: Color.fromRGB(110, 220, 110),
                fontWeight: FontWeight.bold,
              ),
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
