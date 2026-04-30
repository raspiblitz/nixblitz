import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/lnd_seed_panel.dart';
import '../widgets/password_input.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';

/// On-disk path of LND's aezeed mnemonic. nix-bitcoin's lnd
/// module writes the file to `${cfg.dataDir}/lnd-seed-mnemonic`
/// on first start, mode 0400 owned by the lnd user, and never
/// removes it after wallet creation. We read it via SudoSession
/// so the operator sees the words once during the setup flow.
const _kLndSeedPath = '/mnt/data/lnd/lnd-seed-mnemonic';

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

/// Seconds since the first-boot service-build step started.
/// Drives the elapsed counter next to the "Building services"
/// spinner — same shape as the install_view header so the two
/// progress views feel symmetric. Lives in a provider rather
/// than a plain instance variable so the per-second tick
/// triggers a UI rebuild via context.watch.
final _buildServicesElapsedProvider = StateProvider<int>((ref) => 0);

class SetupView extends StatefulComponent {
  const SetupView({super.key});

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> {
  StreamSubscription<String>? _buildServicesSub;
  bool _buildServicesStarted = false;
  Timer? _elapsedTimer;

  /// Held in plain instance state (NOT a Riverpod provider) so
  /// the seed never lands in long-lived app state where a
  /// debug-overlay scrape or a developer's accidental log call
  /// could surface it. Goes out of scope when the setup view
  /// disposes.
  List<String>? _lndSeedWords;

  /// Polls the on-disk seed file every 2s until it appears (LND
  /// preStart can take 5-30s after `nixos-rebuild switch`
  /// returns), then reads the file and populates [_lndSeedWords].
  Timer? _lndSeedPollTimer;

  /// Set when the seed-load pipeline tripped on something the
  /// operator needs to act on (sudo cancelled, file unreadable,
  /// truncated content, etc.). Surfaced in the UI so the user
  /// can retry without restarting the whole flow.
  String? _lndSeedError;

  /// Defensive guard against re-entering the load path while a
  /// previous attempt is still mid-flight (the timer ticks every
  /// 2s but a sudo round-trip can briefly outlast that).
  bool _lndSeedLoading = false;

  /// True once the operator has explicitly chosen to show the
  /// seed on screen (option A on the choice prompt). Until then,
  /// the seed words live in memory but are NOT rendered — public
  /// or recorded environments can pick option B and skip the
  /// reveal entirely. We keep `_lndSeedWords` populated so a
  /// post-choice retry doesn't need another sudo round-trip.
  bool _lndSeedShowConfirmed = false;

  @override
  void dispose() {
    _buildServicesSub?.cancel();
    _elapsedTimer?.cancel();
    _lndSeedPollTimer?.cancel();
    super.dispose();
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    context.read(_buildServicesElapsedProvider.notifier).state = 0;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = context.read(_buildServicesElapsedProvider);
      context.read(_buildServicesElapsedProvider.notifier).state = current + 1;
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  String _formatElapsed(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
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
      final gitAdd = Process.runSync('git', [
        'add',
        'config.json',
      ], workingDirectory: baseDirPath);
      if (gitAdd.exitCode != 0) {
        _appendBuildLog('git add failed: ${gitAdd.stderr}');
      }
      final gitCommit = Process.runSync('git', [
        'commit',
        '-m',
        'Enable services (first boot)',
      ], workingDirectory: baseDirPath);
      _appendBuildLog('git commit exit=${gitCommit.exitCode}');

      context.read(configProvider.notifier).updateConfig(updated);

      final attr = rebuildAttributeFor(updated.system.platform);
      _appendBuildLog('');
      _appendBuildLog('> sudo nixos-rebuild switch --flake $baseDirPath#$attr');
      _appendBuildLog('');

      final systemService = context.read(systemServiceProvider);
      _startElapsedTimer();
      final (:output, :exitCode) = systemService.rebuild(
        baseDirPath,
        attribute: attr,
      );

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
            _stopElapsedTimer();
            context.read(_buildServicesExitCodeProvider.notifier).state = code;
            if (code == 0) {
              context.read(_setupStepProvider.notifier).state =
                  SetupStep.waitBitcoind;
            }
          })
          .catchError((e, st) {
            LogService.error('BuildServices rebuild failed', e, st);
            _stopElapsedTimer();
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
    _stopElapsedTimer();
    context.read(_buildServicesLogProvider.notifier).state = [];
    context.read(_buildServicesExitCodeProvider.notifier).state = null;
    context.read(_buildServicesElapsedProvider.notifier).state = 0;
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
          final stdin = Uint8List.fromList(utf8.encode('admin:$password\n'));
          final res = await session.runOneShot(['chpasswd'], stdinBytes: stdin);
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
      final elapsed = context.watch(_buildServicesElapsedProvider);
      return Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Spinner(label: 'Building services'),
                Text(
                  ' (${_formatElapsed(elapsed)})',
                  style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
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
              '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [g/G] top/bottom   [/] search',
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
              '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [g/G] top/bottom   [/] search   '
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

  /// Kicks off the seed-file polling loop. Idempotent — safe to
  /// call from a build() microtask without guarding the call
  /// site, because the timer slot itself is the single source
  /// of truth.
  void _startLndSeedPoll() {
    if (_lndSeedPollTimer != null) return;
    if (_lndSeedWords != null || _lndSeedError != null) return;
    _tryLoadLndSeed();
    _lndSeedPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _tryLoadLndSeed(),
    );
  }

  void _stopLndSeedPoll() {
    _lndSeedPollTimer?.cancel();
    _lndSeedPollTimer = null;
  }

  Future<void> _tryLoadLndSeed() async {
    if (_lndSeedLoading) return;
    if (_lndSeedWords != null || _lndSeedError != null) return;
    _lndSeedLoading = true;
    try {
      final session = context.read(sudoSessionProvider);
      final ok = await session.ensureFresh();
      if (!ok) {
        setState(() {
          _lndSeedError = 'Sudo authorization cancelled.';
        });
        _stopLndSeedPoll();
        return;
      }
      // Probe existence first — nix-bitcoin's lnd preStart can
      // take 5-30s to drop the file, and we'd rather show a
      // spinner than a confusing "cat: No such file" error
      // during that window.
      final probe = await session.runOneShot(['test', '-f', _kLndSeedPath]);
      if (probe.exitCode != 0) {
        return;
      }
      final res = await session.runOneShot(['cat', _kLndSeedPath]);
      if (res.exitCode != 0) {
        setState(() {
          _lndSeedError =
              'Could not read seed file (exit ${res.exitCode}): '
              '${res.stderr.trim()}';
        });
        _stopLndSeedPoll();
        return;
      }
      final words = res.stdout
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .split(' ')
          .where((w) => w.isNotEmpty)
          .toList(growable: false);
      if (words.length != 24) {
        setState(() {
          _lndSeedError =
              'Seed file has ${words.length} words; expected 24. '
              'Aborting display.';
        });
        _stopLndSeedPoll();
        return;
      }
      setState(() {
        _lndSeedWords = words;
      });
      _stopLndSeedPoll();
    } catch (e, st) {
      LogService.error('LND seed load failed', e, st);
      setState(() {
        _lndSeedError = 'Error reading seed: $e';
      });
      _stopLndSeedPoll();
    } finally {
      _lndSeedLoading = false;
    }
  }

  Component _buildInitLightning() {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;
    final lndEnabled = config != null && config.lnd.enabled;
    final clnEnabled = config != null && config.cln.enabled;

    if (config == null) {
      return const Text('Loading config...');
    }
    if (!lndEnabled && !clnEnabled) {
      Future.microtask(() {
        context.read(_setupStepProvider.notifier).state = SetupStep.summary;
      });
      return const Text('Skipping Lightning setup (none enabled)...');
    }

    if (lndEnabled) {
      // Kick off (or resume) the loader. Multiple microtask
      // schedulings are safe — _startLndSeedPoll is idempotent.
      if (_lndSeedWords == null && _lndSeedError == null) {
        Future.microtask(_startLndSeedPoll);
        return _buildLndSeedWaiting();
      }
      if (_lndSeedError != null) {
        return _buildLndSeedError();
      }
      // Words are loaded. Gate the actual reveal on an explicit
      // operator choice — public / recorded environments need
      // an opt-out that doesn't flash the seed on the screen
      // even briefly.
      if (!_lndSeedShowConfirmed) {
        return _buildLndSeedChoice(alsoCln: clnEnabled);
      }
      return _buildLndSeedDisplay(words: _lndSeedWords!, alsoCln: clnEnabled);
    }

    // CLN-only path: keep the original static message until the
    // CLN seed-display follow-up lands.
    return _buildClnOnlyMessage();
  }

  Component _buildLndSeedChoice({required bool alsoCln}) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          final c = event.character?.toLowerCase();
          if (c == 'a') {
            setState(() {
              _lndSeedShowConfirmed = true;
            });
            return true;
          }
          if (c == 'b') {
            // Skip the reveal. Wipe the in-memory copy now so
            // even a Riverpod-inspector dump can't surface the
            // words after the choice; the on-disk file stays
            // for later recovery.
            setState(() {
              _lndSeedWords = null;
            });
            context.read(_setupStepProvider.notifier).state = SetupStep.summary;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('LND seed choice handler failed', e, st);
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
            Text(
              'IMPORTANT: This 24-word seed restores ONLY the',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'on-chain wallet. Lightning channels need a separate',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'channel.backup that LND updates automatically.',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Without BOTH, funds are lost if this disk fails.',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text('Choose:'),
            const SizedBox(height: 1),
            const Text('  [A] Show the seed on screen now'),
            const Text(
              '      Have pen and paper ready. Best in private —',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const Text(
              '      no cameras, recordings, or shoulder-surfers.',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            const Text('  [B] Continue without showing'),
            const Text(
              '      Safer in public / livestreamed / recorded',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const Text(
              '      environments. Read the seed later with:',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            Text(
              '        sudo cat $_kLndSeedPath',
              style: const TextStyle(color: Color.fromRGB(200, 200, 100)),
            ),
            const SizedBox(height: 1),
            Text(
              'Either choice: copy the words to durable offline',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'storage (paper or steel) as soon as practical. The',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'on-disk file is NOT a substitute for an offline backup.',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            if (alsoCln) ...[
              const SizedBox(height: 1),
              const Text(
                'CLN: a separate seed-display flow lands in a',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
              const Text(
                'follow-up release; it is not affected by this choice.',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            ],
            const SizedBox(height: 1),
            const Text('Press [A] to show, [B] to continue.'),
          ],
        ),
      ),
    );
  }

  Component _buildLndSeedWaiting() {
    return Container(
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
          Spinner(label: 'Waiting for LND to create wallet seed'),
          const SizedBox(height: 1),
          const Text(
            'LND generates the 24-word seed during its first start;',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
          const Text(
            'this usually takes a few seconds.',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ],
      ),
    );
  }

  Component _buildLndSeedDisplay({
    required List<String> words,
    required bool alsoCln,
  }) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          // Y advances. Anything else stays put — operator must
          // consciously confirm they've copied the words before
          // the seed leaves the screen.
          final c = event.character?.toLowerCase();
          if (c == 'y') {
            // Wipe the in-memory copy now that the operator has
            // acknowledged it. Defense-in-depth: shrinks the
            // window an accidental log scrape or screen capture
            // could grab. (The on-disk file is still there for
            // wallet restore; we're only clearing live state.)
            setState(() {
              _lndSeedWords = null;
            });
            context.read(_setupStepProvider.notifier).state = SetupStep.summary;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('LND seed confirmation handler failed', e, st);
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
            LndSeedPanel(words: words),
            const SizedBox(height: 1),
            if (alsoCln) ...[
              const Text(
                'CLN: a separate wallet seed display will be added',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
              const Text(
                'in a follow-up release.',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
              const SizedBox(height: 1),
            ],
            const Text('Press Y when you have written the seed down.'),
          ],
        ),
      ),
    );
  }

  Component _buildLndSeedError() {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          final c = event.character?.toLowerCase();
          if (c == 'r') {
            setState(() {
              _lndSeedError = null;
            });
            Future.microtask(_startLndSeedPoll);
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            // Operator chose to skip the seed display. The file
            // is still on disk; they can recover with `sudo cat
            // /mnt/data/lnd/lnd-seed-mnemonic` later.
            context.read(_setupStepProvider.notifier).state = SetupStep.summary;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('LND seed error handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Could not read LND seed',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(_lndSeedError ?? 'Unknown error'),
            const SizedBox(height: 1),
            const Text('You can recover the seed later with:'),
            Text(
              '  sudo cat $_kLndSeedPath',
              style: const TextStyle(color: Color.fromRGB(200, 200, 100)),
            ),
            const SizedBox(height: 1),
            const Text('[R] retry   [Enter] continue without showing'),
          ],
        ),
      ),
    );
  }

  Component _buildClnOnlyMessage() {
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
          LogService.error('CLN-only fallback handler failed', e, st);
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
