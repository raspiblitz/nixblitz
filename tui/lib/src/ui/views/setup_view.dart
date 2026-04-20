import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../providers/ui_state_provider.dart';

enum SetupStep { setPassword, waitBitcoind, initLightning, summary }

final _setupStepProvider = StateProvider<SetupStep>(
  (ref) => SetupStep.setPassword,
);
final _passwordInputProvider = StateProvider<String>((ref) => '');

class SetupView extends StatelessComponent {
  const SetupView({super.key});

  @override
  Component build(BuildContext context) {
    final step = context.watch(_setupStepProvider);
    return switch (step) {
      SetupStep.setPassword => _SetPasswordStep(),
      SetupStep.waitBitcoind => _WaitBitcoindStep(),
      SetupStep.initLightning => _InitLightningStep(),
      SetupStep.summary => _SummaryStep(),
    };
  }
}

class _SetPasswordStep extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    final password = context.watch(_passwordInputProvider);
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            if (password.length >= 8) {
              final chpasswd = Process.runSync(
                'bash',
                ['-c', 'echo "admin:$password" | sudo chpasswd'],
              );
              if (chpasswd.exitCode != 0) {
                LogService.error(
                  'chpasswd failed: exit=${chpasswd.exitCode} stderr=${chpasswd.stderr}',
                );
              } else {
                LogService.info('Password set successfully');
              }
              context.read(_setupStepProvider.notifier).state =
                  SetupStep.waitBitcoind;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            final current = context.read(_passwordInputProvider);
            if (current.isNotEmpty) {
              context.read(_passwordInputProvider.notifier).state = current
                  .substring(0, current.length - 1);
            }
            return true;
          }
          final char = event.character;
          if (char != null && char.isNotEmpty) {
            context.read(_passwordInputProvider.notifier).state =
                context.read(_passwordInputProvider) + char;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Set password key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'First Boot Setup',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text('Set a password for the admin user.'),
            const Text('This password is used for SSH access.'),
            const SizedBox(height: 1),
            Text('Password: ${'*' * password.length}'),
            const SizedBox(height: 1),
            Text(
              password.length < 8
                  ? 'Minimum 8 characters'
                  : 'Press Enter to continue',
              style: TextStyle(
                color: password.length < 8
                    ? const Color.fromRGB(255, 80, 80)
                    : const Color.fromRGB(110, 220, 110),
              ),
            ),
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
            final configAsync = context.read(configProvider);
            final config = configAsync.value;
            if (config != null) {
              final updated = config.copyWith(initialized: true);
              final baseDirPath = context.read(baseDirProvider);

              // Write config synchronously
              final configService = context.read(configServiceProvider);
              configService.writeConfigSync(updated);
              LogService.info('Setup: marked initialized');

              // Git commit synchronously
              final gitResult = Process.runSync(
                'git',
                ['add', 'config.json'],
                workingDirectory: baseDirPath,
              );
              if (gitResult.exitCode == 0) {
                Process.runSync(
                  'git',
                  ['commit', '-m', 'Setup complete: mark initialized'],
                  workingDirectory: baseDirPath,
                );
              }
              LogService.info('Setup: config committed');

              context.read(configProvider.notifier).updateConfig(updated);
            }
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
