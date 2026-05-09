import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/ascii_banner.dart';
import '../widgets/experimental_warning.dart';
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
  setLightningAlias,
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

  /// Working buffer for the setLightningAlias step. Operator
  /// types into it; Enter persists to config and advances. We
  /// hold it in instance state (not a Riverpod provider) so a
  /// rebuild triggered elsewhere doesn't lose the in-progress
  /// edit.
  ///
  /// LND's BOLT-spec alias limit is 32 bytes. We cap typed
  /// input at 32 ASCII characters — the right answer for
  /// non-ASCII codepoints is "byte length" but most operators
  /// pick ASCII names anyway. Future: a full UTF-8 byte
  /// counter if anyone hits the edge.
  String? _aliasBuffer;
  static const int _kAliasMaxBytes = 32;

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
      _commitWizardFiles('Enable services (first boot)');

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
              _markStepCompleted(SetupStep.buildServices);
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

  /// Persist `setup_step_completed = step.name` to config.json
  /// + commit. Lets the wizard resume at the right place if the
  /// operator quits mid-flow on the next launch, and gates the
  /// dashboard once the terminal step is recorded (see the
  /// routing in `app.dart`).
  ///
  /// Tracking by step *name* (rather than a bool) means the
  /// wizard can grow new steps over time without breaking
  /// resume: an inserted step between A and B will be picked up
  /// automatically by `_stepAfter` for any operator whose
  /// `setup_step_completed` is still A.
  ///
  /// Idempotent — no-op if the recorded step is already this
  /// one or later. Failures are logged but don't block the UI
  /// advance; worst case the operator re-enters the wizard on
  /// next launch.
  void _markStepCompleted(SetupStep step) {
    try {
      final configAsync = context.read(configProvider);
      final config = configAsync.value;
      if (config == null) {
        LogService.warn('markStepCompleted: config not loaded; skipping');
        return;
      }
      // Don't downgrade the recorded step. If the operator
      // somehow lands on an earlier-step's mark-complete after
      // a later step already finished (race conditions, retries,
      // etc.), keep the latest.
      final currentIdx = _setupStepIndex(config.setupStepCompleted);
      final newIdx = SetupStep.values.indexOf(step);
      if (currentIdx >= newIdx) return;

      final updated = config.copyWith(setupStepCompleted: () => step.name);

      // Order matters here: when called from inside a nocterm
      // onKeyEvent handler (the seed-flow Y/B confirm or the
      // summary's Enter), updating a StateProvider triggers an
      // immediate widget rebuild that aborts the rest of the
      // handler — see "Nocterm Pitfalls" in CLAUDE.md. So all
      // I/O (file write, git stage, git commit, logging) must
      // run BEFORE we touch `configProvider.notifier.updateConfig`,
      // otherwise the disk gets the new step but git's HEAD
      // doesn't and the operator sees `M config.json` dirty
      // post-summary.
      final configService = context.read(configServiceProvider);
      configService.writeConfigSync(updated);
      LogService.info(
        'markStepCompleted: wrote setup_step_completed=${step.name}',
      );

      _commitWizardFiles('Setup wizard: completed ${step.name}');

      // Done with I/O — safe to update the provider now. If the
      // tree rebuild aborts further handler code at this point,
      // it doesn't matter: the on-disk state and git HEAD are
      // already consistent.
      context.read(configProvider.notifier).updateConfig(updated);
    } catch (e, st) {
      LogService.error('markStepCompleted failed', e, st);
    }
  }

  /// Stage the wizard-managed files and create a commit. Stages
  /// `config.json` (the source of truth) AND `flake.lock` —
  /// `nixos-rebuild switch --flake` writes the lock file the
  /// first time it runs, so without including it here it stays
  /// untracked forever and the operator sees `A flake.lock`
  /// dirty after the wizard finishes. Exit 1 from `git commit`
  /// here typically means "nothing to commit" (the wizard
  /// re-running over already-committed state); not treated as
  /// an error.
  void _commitWizardFiles(String message) {
    try {
      final baseDirPath = context.read(baseDirProvider);
      final filesToStage = <String>['config.json'];
      if (File('$baseDirPath/flake.lock').existsSync()) {
        filesToStage.add('flake.lock');
      }
      final gitAdd = Process.runSync('git', [
        'add',
        ...filesToStage,
      ], workingDirectory: baseDirPath);
      if (gitAdd.exitCode != 0) {
        LogService.warn('git add failed: ${gitAdd.stderr}');
      }
      final gitCommit = Process.runSync('git', [
        'commit',
        '-m',
        message,
      ], workingDirectory: baseDirPath);
      LogService.info('git commit "$message" exit=${gitCommit.exitCode}');
      // HEAD just moved; invalidate the cached HEAD-config so
      // pendingChangeKeysProvider diffs against the new HEAD instead
      // of the stale pre-wizard cache. Without this, every section
      // the wizard touched shows up as pending on the post-wizard
      // dashboard until the operator restarts the TUI. Apply / Update
      // already do this at their own commit sites.
      if (gitCommit.exitCode == 0) {
        context.invalidate(committedConfigProvider);
      }
    } catch (e, st) {
      LogService.error('commitWizardFiles failed', e, st);
    }
  }

  /// Returns the next step the wizard should run given the most
  /// recently completed step name (as recorded in config). Null
  /// or unknown names → start from the first step (covers fresh
  /// configs and any future rename / removal of a step the
  /// operator was mid-way through). If the recorded step is the
  /// terminal one, returns the terminal step itself — callers
  /// should normally have routed to the dashboard before getting
  /// this far, but the fallback is safe.
  SetupStep _resumeStep(String? lastCompleted) {
    if (lastCompleted == null || lastCompleted.isEmpty) {
      return SetupStep.values.first;
    }
    final idx = SetupStep.values.indexWhere((s) => s.name == lastCompleted);
    if (idx < 0) {
      LogService.warn(
        'Resume: unknown setup_step_completed=$lastCompleted; '
        'restarting wizard from the first step',
      );
      return SetupStep.values.first;
    }
    if (idx >= SetupStep.values.length - 1) {
      return SetupStep.values.last;
    }
    return SetupStep.values[idx + 1];
  }

  /// Resolve the index of a recorded step name. -1 for "no step
  /// recorded yet" (so any step's index is greater) and for
  /// names the wizard no longer recognises.
  int _setupStepIndex(String? name) {
    if (name == null || name.isEmpty) return -1;
    return SetupStep.values.indexWhere((s) => s.name == name);
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
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;

    // Resume from where the wizard last left off if the operator
    // bailed mid-flow (Ctrl+C at the seed reveal, etc.). The
    // _setupStepProvider defaults to the first step; if the
    // config records a more advanced last-completed step, jump
    // to whatever comes after it. This auto-handles future
    // wizard growth: insert a step between two existing ones
    // and operators whose recorded step is the prior one will
    // see the new step on next launch.
    if (step == SetupStep.values.first && config != null) {
      final resume = _resumeStep(config.setupStepCompleted);
      if (resume != SetupStep.values.first) {
        Future.microtask(() {
          context.read(_setupStepProvider.notifier).state = resume;
        });
        return const Text('Resuming setup...');
      }
    }

    return switch (step) {
      SetupStep.setPassword => _buildSetPassword(),
      SetupStep.setLightningAlias => _buildSetLightningAlias(),
      SetupStep.buildServices => _buildBuildServices(),
      SetupStep.waitBitcoind => _buildWaitBitcoind(),
      SetupStep.initLightning => _buildInitLightning(),
      SetupStep.summary => _buildSummary(),
    };
  }

  Component _buildSetPassword() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              AsciiBanner(),
              SizedBox(height: 1),
              ExperimentalWarning(),
            ],
          ),
        ),
        Expanded(child: _buildSetPasswordInput()),
      ],
    );
  }

  Component _buildSetPasswordInput() {
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
          _markStepCompleted(SetupStep.setPassword);
          context.read(_setupStepProvider.notifier).state =
              SetupStep.setLightningAlias;
        });
      },
    );
  }

  /// Asks the operator to pick a Lightning node name (LND alias).
  /// Skipped automatically when LND isn't enabled — CLN doesn't
  /// have an alias field today, and a "node name" question with
  /// no LN backend would be a misleading prompt.
  ///
  /// Empty value is allowed: LND falls back to a pubkey-derived
  /// default like `0274…b8e3`. The operator can also change the
  /// alias post-setup via Configure → lnd → alias.
  Component _buildSetLightningAlias() {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;

    // Skip when there's no LN backend that uses an alias.
    // CLN-only operators bypass this step entirely.
    if (config != null && !config.isAppEnabled('lnd')) {
      Future.microtask(() {
        _markStepCompleted(SetupStep.setLightningAlias);
        context.read(_setupStepProvider.notifier).state =
            SetupStep.buildServices;
      });
      return const Text('Skipping LN alias (LND disabled)…');
    }
    if (config == null) {
      return const Text('Loading config…');
    }

    // Lazy-init the buffer from the existing alias so a re-run
    // (operator backed out, came back) sees what they typed last
    // time. Fresh installs get an empty string.
    _aliasBuffer ??= config.appOption<String>('lnd', 'alias') ?? '';
    final buffer = _aliasBuffer!;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            // Esc bails to the previous step (setPassword).
            // Useful if the operator wants to redo the password
            // before the rebuild fires.
            context.read(_setupStepProvider.notifier).state =
                SetupStep.setPassword;
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            // Persist whatever the buffer holds (including
            // empty — that's "let LND default") and advance.
            final updated = config.setAppOption('lnd', 'alias', buffer);
            final configService = context.read(configServiceProvider);
            configService.writeConfigSync(updated);
            context.read(configProvider.notifier).updateConfig(updated);
            LogService.info(
              'setLightningAlias: persisted alias="$buffer" '
              '(${buffer.length} chars)',
            );
            // Reset the buffer so a future re-entry (after a
            // _markStepCompleted-aware resume) re-reads from
            // config rather than holding onto stale state.
            _aliasBuffer = null;
            _markStepCompleted(SetupStep.setLightningAlias);
            context.read(_setupStepProvider.notifier).state =
                SetupStep.buildServices;
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            if (buffer.isEmpty) return true;
            setState(() {
              _aliasBuffer = buffer.substring(0, buffer.length - 1);
            });
            return true;
          }
          // Append printable characters. nocterm's `event.character`
          // is non-null for typeable keys; filter to the
          // ASCII-printable range. Spaces are explicitly allowed
          // (operators picking "My Node Name" should be able to
          // include them). Cap at 32 chars — BOLT spec.
          final ch = event.character;
          if (ch != null && ch.length == 1) {
            final code = ch.codeUnitAt(0);
            final printable = code >= 0x20 && code <= 0x7E;
            if (printable && buffer.length < _kAliasMaxBytes) {
              setState(() {
                _aliasBuffer = '$buffer$ch';
              });
              return true;
            }
          }
          return false;
        } catch (e, st) {
          LogService.error('setLightningAlias key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Lightning Node Name',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text('This is the public alias your LND node advertises on'),
            const Text(
              'the Lightning Network. Visible to everyone you connect',
            ),
            const Text(
              'to. ASCII printable characters, max 32. Leave blank to',
            ),
            const Text('let LND derive one from your pubkey.'),
            const SizedBox(height: 1),
            Text('  Alias: [${buffer}_]'),
            const SizedBox(height: 1),
            Text(
              '  ${buffer.length}/$_kAliasMaxBytes chars',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            const Text(
              '[type] edit   [⌫] delete   [Enter] continue   [Esc] back',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
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

    // `nixos-rebuild switch` exit codes:
    //   0  full success
    //   4  the new system WAS activated, but at least one unit
    //      failed during start. Typical NixOS first-activation
    //      quirk: `logrotate-checkconf.service` runs the upstream
    //      nginx logrotate config in --debug, which switches euid
    //      to nginx (uid 60) and tries to stat /var/log/nginx/*
    //      — but the dir is still 0700 root:root because nginx's
    //      own preStart hasn't run yet. Real-world impact is
    //      zero; the actual logrotate timer runs fine on the
    //      next boot.
    //   anything else  real failure, retry needed.
    //
    // Treat 4 as a user-confirmable warning rather than a hard
    // failure so the operator isn't stuck on a screen for a
    // unit failure that doesn't matter.
    final isWarning = exitCode == 4;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.enter) {
            if (isWarning) {
              _markStepCompleted(SetupStep.buildServices);
              context.read(_setupStepProvider.notifier).state =
                  SetupStep.waitBitcoind;
            } else {
              _retryBuildServices();
            }
            return true;
          }
          if (isWarning && (event.character?.toLowerCase() == 'r')) {
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
          LogService.error('BuildServices post-run key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isWarning) ...[
              Text(
                'Service build completed with warnings (exit $exitCode)',
                style: const TextStyle(
                  color: Color.fromRGB(255, 200, 80),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              const Text(
                'The new system was activated, but at least one unit failed',
                style: TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
              const Text(
                'to start. A common cause is the NixOS logrotate-checkconf',
                style: TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
              const Text(
                'first-activation quirk against /var/log/nginx — harmless;',
                style: TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
              const Text(
                'review the failed-unit names in the log to be sure.',
                style: TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
              const SizedBox(height: 1),
            ] else ...[
              Text(
                'Service build failed (exit $exitCode)',
                style: const TextStyle(
                  color: Color.fromRGB(255, 80, 80),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
            ],
            Expanded(child: ScrollableLog(lines: logLines, focused: true)),
            const SizedBox(height: 1),
            Text(
              isWarning
                  ? '[↑/↓ j/k] scroll   [/] search   '
                        '[Enter] continue   [R] retry   [Esc] dashboard'
                  : '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [g/G] top/bottom   [/] search   '
                        '[Enter] retry   [Esc] dashboard',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildWaitBitcoind() {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;

    if (config != null && !config.isAppEnabled('bitcoind')) {
      Future.microtask(() {
        _markStepCompleted(SetupStep.waitBitcoind);
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
                  _markStepCompleted(SetupStep.waitBitcoind);
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
    final lndEnabled = config != null && config.isAppEnabled('lnd');
    final clnEnabled = config != null && config.isAppEnabled('cln');

    if (config == null) {
      return const Text('Loading config...');
    }
    if (!lndEnabled && !clnEnabled) {
      Future.microtask(() {
        _markStepCompleted(SetupStep.initLightning);
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
            _markStepCompleted(SetupStep.initLightning);
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
            _markStepCompleted(SetupStep.initLightning);
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
            _markStepCompleted(SetupStep.initLightning);
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
            _markStepCompleted(SetupStep.initLightning);
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
            // Final step — recording it as completed gates the
            // dashboard from app.dart's startup routing on every
            // future launch.
            _markStepCompleted(SetupStep.summary);
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
