import 'dart:async';
import 'dart:io';
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

class SetupView extends StatelessComponent {
  const SetupView({super.key});

  @override
  Component build(BuildContext context) {
    final step = context.watch(_setupStepProvider);
    return switch (step) {
      SetupStep.setPassword => _SetPasswordStep(),
      SetupStep.buildServices => const _BuildServicesStep(),
      SetupStep.waitBitcoind => _WaitBitcoindStep(),
      SetupStep.initLightning => _InitLightningStep(),
      SetupStep.summary => _SummaryStep(),
    };
  }
}

class _SetPasswordStep extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    return PasswordInput(
      title: 'First Boot Setup',
      subtitle: 'Set a password for the admin user. Used for SSH access.',
      minLength: 8,
      requireConfirmation: true,
      onSubmit: (password) {
        final chpasswd = Process.runSync(
          'bash',
          ['-c', 'echo "admin:$password" | sudo -n chpasswd'],
        );
        if (chpasswd.exitCode != 0) {
          LogService.error(
            'chpasswd failed: exit=${chpasswd.exitCode} stderr=${chpasswd.stderr}',
          );
        } else {
          LogService.info('Password set successfully');
        }
        context.read(_setupStepProvider.notifier).state =
            SetupStep.buildServices;
      },
    );
  }
}

/// Bootstraps the service stack on first boot.
///
/// The initial install ships a minimal NixOS (`initialized: false` gates all
/// service features off) so the build fits in the live ISO's tmpfs. Here, on
/// the real disk, we flip `initialized` to true and run `nixos-rebuild switch`
/// to bring up bitcoind/LND/CLN/blitz-api/blitz-web.
class _BuildServicesStep extends StatefulComponent {
  const _BuildServicesStep();

  @override
  State<_BuildServicesStep> createState() => _BuildServicesStepState();
}

class _BuildServicesStepState extends State<_BuildServicesStep> {
  StreamSubscription<String>? _outputSub;
  final List<String> _output = [];
  bool _started = false;
  int? _exitCode;

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  void _append(String line) {
    setState(() {
      _output.add(line);
    });
  }

  void _start() {
    if (_started) return;
    _started = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final configAsync = context.read(configProvider);
      final config = configAsync.value;
      if (config == null) {
        _append('Error: config not loaded');
        setState(() {
          _exitCode = 1;
        });
        return;
      }

      _append('> Enabling services (initialized=true)');
      final updated = config.copyWith(initialized: true);
      final configService = context.read(configServiceProvider);
      configService.writeConfigSync(updated);
      LogService.info('BuildServices: wrote initialized=true');

      _append('> git add + commit');
      final gitAdd = Process.runSync(
        'git',
        ['add', 'config.json'],
        workingDirectory: baseDirPath,
      );
      if (gitAdd.exitCode != 0) {
        _append('git add failed: ${gitAdd.stderr}');
      }
      final gitCommit = Process.runSync(
        'git',
        ['commit', '-m', 'Enable services (first boot)'],
        workingDirectory: baseDirPath,
      );
      _append('git commit exit=${gitCommit.exitCode}');

      context.read(configProvider.notifier).updateConfig(updated);

      _append('');
      _append('> sudo nixos-rebuild switch --flake $baseDirPath');
      _append('');

      final systemService = context.read(systemServiceProvider);
      final (:output, :exitCode) = systemService.rebuild(baseDirPath);

      _outputSub = output.listen(
        (line) {
          LogService.info('[build-services] $line');
          setState(() {
            _output.add(line);
          });
        },
        onError: (e, st) {
          LogService.error('BuildServices output stream error', e, st);
        },
      );

      exitCode
          .then((code) {
            LogService.info('BuildServices: rebuild exited with code $code');
            setState(() {
              _exitCode = code;
            });
            if (code == 0) {
              Future.microtask(() {
                context.read(_setupStepProvider.notifier).state =
                    SetupStep.waitBitcoind;
              });
            }
          })
          .catchError((e, st) {
            LogService.error('BuildServices rebuild failed', e, st);
            setState(() {
              _exitCode = 1;
            });
          });
    } catch (e, st) {
      LogService.error('BuildServices start failed', e, st);
      _append('Error: $e');
      setState(() {
        _exitCode = 1;
      });
    }
  }

  @override
  Component build(BuildContext context) {
    if (!_started) {
      Future.microtask(_start);
    }

    final isRunning = _exitCode == null;

    if (isRunning) {
      return Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Building services',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Spinner(label: 'Running nixos-rebuild. This may take several minutes.'),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: _output)),
          ],
        ),
      );
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            _outputSub?.cancel();
            _outputSub = null;
            setState(() {
              _output.clear();
              _exitCode = null;
              _started = false;
            });
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
            Expanded(child: ScrollableLog(lines: _output)),
            const SizedBox(height: 1),
            const Text('Press Enter to retry, Esc to go to dashboard.'),
          ],
        ),
      ),
    );
  }
}

class _WaitBitcoindStep extends StatelessComponent {
  @override
  Component build(BuildContext context) {
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
}

class _InitLightningStep extends StatelessComponent {
  @override
  Component build(BuildContext context) {
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
}

class _SummaryStep extends StatelessComponent {
  @override
  Component build(BuildContext context) {
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
