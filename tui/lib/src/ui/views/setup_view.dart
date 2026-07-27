import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/ascii_banner.dart';
import '../widgets/experimental_warning.dart';
import '../widgets/lnd_journal_popup.dart';
import '../widgets/lnd_seed_panel.dart';
import '../widgets/password_input.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/seed_wait_checklist.dart';
import '../widgets/select_popup.dart';
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
  selectBitcoinNetwork,
  installBitcoindPlugin,
  selectLightningBackend,
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

/// Holds the state of the in-flight plugin install during the
/// installBitcoindPlugin / selectLightningBackend wizard steps.
final _pluginInstallStatusProvider =
    StateProvider<({String? message, bool error})>(
      (ref) => (message: null, error: false),
    );

/// Selected index in the Lightning backend picker. Held in a
/// StateProvider so the SelectPopup's `onHighlight` callback can
/// drive a rebuild without making the surrounding view stateful.
final _lightningBackendIdxProvider = StateProvider<int>((ref) => 0);

/// Backend the operator confirmed (after Enter on the SelectPopup).
/// null while the picker is still showing; set to "lnd"/"cln"/"none"
/// once the operator picks. Drives the install-status overlay.
final _lightningBackendChoiceProvider = StateProvider<String?>((ref) => null);

/// Selected index in the Bitcoin network picker. 0 = mainnet
/// (default), 1 = regtest. Kept narrow on purpose — testnet /
/// signet aren't useful for a self-hosted node and would just
/// muddy the picker.
final _bitcoinNetworkIdxProvider = StateProvider<int>((ref) => 0);

class SetupView extends StatefulComponent {
  const SetupView({super.key});

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> {
  StreamSubscription<String>? _buildServicesSub;
  bool _buildServicesStarted = false;
  Timer? _elapsedTimer;

  /// Drives the waitBitcoind step's refresh loop. Two stale one-shot
  /// providers have to be re-read for the step to advance: bitcoind is a
  /// *plugin*, so it only appears in the service registry once
  /// `installedPluginsProvider` is re-read after setup installs it, and
  /// its status only flips to running a few seconds after Apply. The timer
  /// re-checks both every 2s. See `_startBitcoindPoll`. Mirrors
  /// `_lndSeedPollTimer`.
  Timer? _bitcoindPollTimer;

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

  /// Latest poll status for the checklist. Never outlives the step:
  /// on `done` the words move to [_lndSeedWords] and this is reset to
  /// a plain non-terminal value so a Riverpod-triggered rebuild can't
  /// re-read stale seed words from it.
  SeedWaitStatus _seedWaitStatus = const SeedWaitStatus(
    phase: SeedWaitPhase.startingService,
  );

  /// Poll service. Created lazily on first use so `context.read` of the
  /// sudo session happens inside a build/microtask, not at field-init.
  LndSeedWaitService? _seedWaitService;

  /// Journal popup visibility. Plain bool (nocterm pitfall #1: no
  /// provider writes mid-handler).
  bool _lndJournalVisible = false;

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
    _bitcoindPollTimer?.cancel();
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

  bool _selectLightningStarted = false;

  void _startInstallLightningBackend(String backend) {
    if (_selectLightningStarted) return;
    _selectLightningStarted = true;

    // Clear any leftover status from the previous wizard step
    // (installBitcoindPlugin shares the same provider) so a stale
    // success/error message doesn't flash before this step's own
    // status takes over.
    context.read(_pluginInstallStatusProvider.notifier).state = (
      message: null,
      error: false,
    );

    if (backend == 'none') {
      LogService.info('selectLightningBackend: operator chose none');
      _markStepCompleted(SetupStep.selectLightningBackend);
      context.read(_setupStepProvider.notifier).state = SetupStep.buildServices;
      return;
    }

    final url = backend == 'lnd'
        ? 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/lnd'
        : 'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/cln';

    context.read(_pluginInstallStatusProvider.notifier).state = (
      message: 'Fetching $backend plugin from forge…',
      error: false,
    );

    final pluginService = context.read(pluginServiceProvider);
    pluginService
        .install(url)
        .then((marker) {
          if (!mounted) return;
          LogService.info(
            'selectLightningBackend: installed $backend (rev=${marker.rev})',
          );

          // Seed app_configs.<backend>.enabled = true. Existing keys
          // win (resumability — operator may re-enter the wizard with
          // values they already typed).
          final configService = context.read(configServiceProvider);
          final cfg = context.read(configProvider).value;
          if (cfg != null) {
            final apps = Map<String, Map<String, dynamic>>.from(cfg.appConfigs);
            apps[backend] = {'enabled': true, ...?apps[backend]};
            final updated = cfg.copyWith(appConfigs: apps);
            configService.writeConfigSync(updated);
            context.read(configProvider.notifier).updateConfig(updated);
          }

          _markStepCompleted(SetupStep.selectLightningBackend);
          // lnd needs the alias prompt; cln has no alias config so skip.
          context.read(_setupStepProvider.notifier).state = backend == 'lnd'
              ? SetupStep.setLightningAlias
              : SetupStep.buildServices;
        })
        .catchError((e, st) {
          LogService.error('selectLightningBackend failed for $backend', e, st);
          if (!mounted) return;
          context.read(_pluginInstallStatusProvider.notifier).state = (
            message: 'Install failed: $e',
            error: true,
          );
          _selectLightningStarted = false; // allow retry
        });
  }

  /// Auto-fires when entering the [SetupStep.installBitcoindPlugin]
  /// step. Installs the bitcoind plugin via the standard
  /// PluginService.install flow. On success advances to
  /// selectLightningBackend; on failure leaves the operator on this
  /// step with an error + retry affordance.
  bool _installBitcoindPluginStarted = false;

  void _startInstallBitcoindPlugin() {
    if (_installBitcoindPluginStarted) return;
    _installBitcoindPluginStarted = true;

    context.read(_pluginInstallStatusProvider.notifier).state = (
      message: 'Fetching bitcoind plugin from forge…',
      error: false,
    );

    final pluginService = context.read(pluginServiceProvider);
    pluginService
        .install('forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/bitcoind')
        .then((marker) {
          if (!mounted) return;
          LogService.info('installBitcoindPlugin: success (rev=${marker.rev})');

          // Seed app_configs.bitcoind. The prior selectBitcoinNetwork
          // step already wrote `network` to the config; the spread
          // below preserves it (and any other operator-set keys) and
          // only fills in the rest of the schema defaults.
          final configService = context.read(configServiceProvider);
          final cfg = context.read(configProvider).value;
          if (cfg != null) {
            final apps = Map<String, Map<String, dynamic>>.from(cfg.appConfigs);
            apps['bitcoind'] = {
              'enabled': true,
              'pruned': true,
              'prune_size_gb': 550,
              ...?apps['bitcoind'],
            };
            final updated = cfg.copyWith(appConfigs: apps);
            configService.writeConfigSync(updated);
            context.read(configProvider.notifier).updateConfig(updated);
          }

          _markStepCompleted(SetupStep.installBitcoindPlugin);
          context.read(_setupStepProvider.notifier).state =
              SetupStep.selectLightningBackend;
        })
        .catchError((e, st) {
          LogService.error('installBitcoindPlugin failed', e, st);
          if (!mounted) return;
          context.read(_pluginInstallStatusProvider.notifier).state = (
            message: 'Install failed: $e',
            error: true,
          );
          _installBitcoindPluginStarted = false; // allow retry
        });
  }

  Component _buildInstallBitcoindPlugin() {
    // Auto-fire on first render. The handler guards against re-entry
    // via _installBitcoindPluginStarted.
    Future.microtask(_startInstallBitcoindPlugin);

    final status = context.watch(_pluginInstallStatusProvider);
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (status.error && event.logicalKey == LogicalKey.keyR) {
            _startInstallBitcoindPlugin();
            return true;
          }
          if (event.matches(LogicalKey.keyC, ctrl: true)) {
            shutdownApp(0);
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('installBitcoindPlugin key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Installing bitcoind plugin',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              status.message ?? 'starting…',
              style: TextStyle(
                color: status.error
                    ? const Color.fromRGB(255, 80, 80)
                    : const Color.fromRGB(220, 220, 220),
              ),
            ),
            if (status.error) ...[
              const SizedBox(height: 1),
              const Text(
                '[r] retry   [Ctrl+C] quit',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Persist the operator's network choice into
  /// `app_configs.bitcoind.network` and advance to the bitcoind
  /// install step. installBitcoindPlugin's seed uses
  /// spread-existing-wins, so writing the network first means the
  /// install preserves the choice.
  void _persistBitcoinNetworkAndAdvance(String network) {
    final configService = context.read(configServiceProvider);
    final cfg = context.read(configProvider).value;
    if (cfg != null) {
      final apps = Map<String, Map<String, dynamic>>.from(cfg.appConfigs);
      apps['bitcoind'] = {...?apps['bitcoind'], 'network': network};
      final updated = cfg.copyWith(appConfigs: apps);
      configService.writeConfigSync(updated);
      context.read(configProvider.notifier).updateConfig(updated);
    }
    LogService.info('selectBitcoinNetwork: operator chose $network');
    _markStepCompleted(SetupStep.selectBitcoinNetwork);
    context.read(_setupStepProvider.notifier).state =
        SetupStep.installBitcoindPlugin;
  }

  Component _buildSelectBitcoinNetwork() {
    final idx = context.watch(_bitcoinNetworkIdxProvider);

    // Parallel arrays: index 0 → 'mainnet', 1 → 'regtest'.
    const networkValues = ['mainnet', 'regtest'];
    const networkLabels = [
      'Mainnet — production Bitcoin network',
      'Regtest — local-only test network for development',
    ];

    return SelectPopup(
      title: 'Choose Bitcoin network',
      options: networkLabels,
      selectedIndex: idx,
      onHighlight: (i) =>
          context.read(_bitcoinNetworkIdxProvider.notifier).state = i,
      onConfirm: (i) => _persistBitcoinNetworkAndAdvance(networkValues[i]),
      onCancel: () {
        // Operator can't really cancel out of the wizard mid-flow;
        // treat Esc as "fall back to mainnet" (the production default)
        // so they always have a way to proceed.
        _persistBitcoinNetworkAndAdvance('mainnet');
      },
    );
  }

  Component _buildSelectLightningBackend() {
    final status = context.watch(_pluginInstallStatusProvider);
    final choice = context.watch(_lightningBackendChoiceProvider);
    final idx = context.watch(_lightningBackendIdxProvider);

    // If a choice has been confirmed and an install is in flight or
    // errored, show the install status. Otherwise show the picker.
    if (choice != null && status.message != null) {
      return Focusable(
        focused: true,
        onKeyEvent: (event) {
          try {
            if (status.error && event.logicalKey == LogicalKey.keyR) {
              _startInstallLightningBackend(choice);
              return true;
            }
            return false;
          } catch (e, st) {
            LogService.error('selectLightningBackend retry failed', e, st);
            return true;
          }
        },
        child: Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Installing $choice plugin',
                style: const TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                status.message ?? '',
                style: TextStyle(
                  color: status.error
                      ? const Color.fromRGB(255, 80, 80)
                      : const Color.fromRGB(220, 220, 220),
                ),
              ),
              if (status.error) ...[
                const SizedBox(height: 1),
                const Text(
                  '[r] retry',
                  style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // Picker. SelectPopup is controlled — parent owns the index.
    // Parallel arrays: index 0 → 'lnd', 1 → 'cln', 2 → 'none'.
    const backendValues = ['lnd', 'cln', 'none'];
    const backendLabels = [
      'LND (Lightning Network Daemon)',
      'Core Lightning (CLN)',
      'None — bitcoin-only node',
    ];

    return SelectPopup(
      title: 'Choose Lightning backend',
      options: backendLabels,
      selectedIndex: idx,
      onHighlight: (i) =>
          context.read(_lightningBackendIdxProvider.notifier).state = i,
      onConfirm: (i) {
        final value = backendValues[i];
        context.read(_lightningBackendChoiceProvider.notifier).state = value;
        _startInstallLightningBackend(value);
      },
      onCancel: () {
        // Operator can't really cancel out of the wizard mid-flow; treat
        // Esc as "fall back to none" so they always have a way out.
        context.read(_lightningBackendChoiceProvider.notifier).state = 'none';
        _startInstallLightningBackend('none');
      },
    );
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
      // Stage everything (commitAllSync does `git add -A`): nixos-rebuild
      // evaluates the flake from git's tracked tree, so any wizard-installed
      // plugin files (plugins/<id>/…) and the regenerated plugins.list have
      // to be committed before the rebuild runs. Staging only config.json +
      // flake.lock used to leave freshly-installed plugins untracked, so the
      // rebuilt system shipped with zero plugin modules and the
      // bitcoind-wait step polled forever.
      final committed = context.read(gitServiceProvider).commitAllSync(message);
      LogService.info('git commit "$message" committed=$committed');
      // HEAD just moved; invalidate the cached HEAD-config so
      // pendingChangeKeysProvider diffs against the new HEAD instead
      // of the stale pre-wizard cache. Without this, every section
      // the wizard touched shows up as pending on the post-wizard
      // dashboard until the operator restarts the TUI. Apply / Update
      // already do this at their own commit sites.
      if (committed) {
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
      SetupStep.selectBitcoinNetwork => _buildSelectBitcoinNetwork(),
      SetupStep.installBitcoindPlugin => _buildInstallBitcoindPlugin(),
      SetupStep.selectLightningBackend => _buildSelectLightningBackend(),
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
              SetupStep.selectBitcoinNetwork;
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
              '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [gg/G] top/bottom   [/] search',
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
                  : '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [gg/G] top/bottom   [/] search   '
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
      _stopBitcoindPoll();
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
          const Spinner(label: 'Waiting for Bitcoin daemon...'),
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
                _stopBitcoindPoll();
                Future.microtask(() {
                  _markStepCompleted(SetupStep.waitBitcoind);
                  context.read(_setupStepProvider.notifier).state =
                      SetupStep.initLightning;
                });
              } else {
                // "unknown" here usually means bitcoind isn't in the
                // registry yet — its plugin was installed after the TUI
                // auto-launched, and installedPluginsProvider cached an
                // empty list. Keep polling: _startBitcoindPoll re-reads the
                // plugin registry AND the service status until bitcoind is
                // active (it starts a few seconds after Apply).
                Future.microtask(_startBitcoindPoll);
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

  /// Kicks off the bitcoind status poll. Idempotent — safe to call from a
  /// build() microtask (the timer slot is the single source of truth).
  ///
  /// On a fresh install the TUI auto-launches before any plugin exists, so
  /// `installedPluginsProvider` (a one-shot disk read) caches an empty
  /// list — and bitcoind, a *plugin*, never appears in
  /// `AppManifestRegistry.serviceIds()`, so the wait step has no
  /// `bitcoind` entry to probe and shows "unknown" even though the daemon
  /// is running. Setup installs the bitcoind plugin but nothing refreshes
  /// that provider. So every 2s we invalidate `installedPluginsProvider`
  /// (re-reads the plugins dir → registry now includes bitcoind), which
  /// cascades to `serviceStatusProvider`; we invalidate the latter too so
  /// the fresh `systemctl show` runs. The step advances once bitcoind is
  /// active.
  void _startBitcoindPoll() {
    if (_bitcoindPollTimer != null) return;
    _bitcoindPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      context.invalidate(installedPluginsProvider);
      context.invalidate(serviceStatusProvider);
    });
  }

  void _stopBitcoindPoll() {
    _bitcoindPollTimer?.cancel();
    _bitcoindPollTimer = null;
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
      _seedWaitService ??= LndSeedWaitService(
        ensureSudoFresh: session.ensureFresh,
        runSudo: (args) => session.runOneShot(args),
        seedPath: _kLndSeedPath,
      );
      final status = await _seedWaitService!.poll();
      if (status.phase == SeedWaitPhase.done && status.seedWords != null) {
        setState(() {
          _lndSeedWords = status.seedWords;
          // Wipe the words from checklist state immediately — the
          // reveal gate reads _lndSeedWords only.
          _seedWaitStatus = const SeedWaitStatus(phase: SeedWaitPhase.done);
          // The waiting screen (and its journal popup) unmounts once
          // we leave this branch; don't let a stale true survive into
          // whatever step renders next.
          _lndJournalVisible = false;
        });
        _stopLndSeedPoll();
        return;
      }
      if (status.error != null) {
        setState(() {
          _seedWaitStatus = status;
          _lndSeedError = status.error;
        });
        _stopLndSeedPoll();
        return;
      }
      setState(() {
        _seedWaitStatus = status;
      });
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
    return Stack(
      children: [
        Focusable(
          // Yield to the popup while it's up (same dispatch rule as the
          // app-level modals: the popup's Focusable must be reached by
          // the Stack iteration). Also yield while an app-wide modal
          // (e.g. the sudo password overlay) is up — nocterm dispatches
          // depth-first view-first, so without this an 'o' typed into a
          // password would mount the journal popup underneath the
          // overlay instead of reaching it.
          focused: !_lndJournalVisible && !context.watch(modalActiveProvider),
          onKeyEvent: (event) {
            try {
              if (event.character?.toLowerCase() == 'o') {
                setState(() {
                  _lndJournalVisible = true;
                });
                return true;
              }
              return false;
            } catch (e, st) {
              LogService.error('seed-wait key handler failed', e, st);
              return true;
            }
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: SeedWaitChecklist(status: _seedWaitStatus),
          ),
        ),
        if (_lndJournalVisible)
          LndJournalPopup(
            fetchJournal: _fetchLndJournal,
            onClose: () {
              setState(() {
                _lndJournalVisible = false;
              });
            },
          ),
      ],
    );
  }

  /// Journal fetch for the popup. Uses the sudo session's one-shot
  /// runner; by the time anyone opens the log the session is normally
  /// fresh, but ensureFresh here makes an explicit open work even
  /// before the poll's first sudo call (the user asked for the log —
  /// a prompt is expected then, not a surprise).
  Future<String> _fetchLndJournal() async {
    final session = context.read(sudoSessionProvider);
    final ok = await session.ensureFresh();
    if (!ok) return 'Sudo authorization cancelled — cannot read journal.';
    final res = await session.runOneShot([
      'journalctl',
      '-u',
      'lnd',
      '-n',
      '150',
      '--no-pager',
    ]);
    if (res.exitCode != 0) {
      return 'journalctl failed (exit ${res.exitCode}): ${res.stderr}';
    }
    return res.stdout;
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
    return Stack(
      children: [
        Focusable(
          focused: !_lndJournalVisible && !context.watch(modalActiveProvider),
          onKeyEvent: (event) {
            try {
              final c = event.character?.toLowerCase();
              if (c == 'o') {
                setState(() {
                  _lndJournalVisible = true;
                });
                return true;
              }
              if (c == 'r') {
                setState(() {
                  _lndSeedError = null;
                  _seedWaitStatus = const SeedWaitStatus(
                    phase: SeedWaitPhase.startingService,
                  );
                  _seedWaitService = null; // fresh announce tick on retry
                });
                Future.microtask(_startLndSeedPoll);
                return true;
              }
              if (event.logicalKey == LogicalKey.enter) {
                // Operator chose to skip the seed display. The file
                // is still on disk; they can recover with `sudo cat
                // /mnt/data/lnd/lnd-seed-mnemonic` later.
                _markStepCompleted(SetupStep.initLightning);
                context.read(_setupStepProvider.notifier).state =
                    SetupStep.summary;
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
                const Text(
                  '[R] retry   [O] LND log   [Enter] continue without showing',
                ),
              ],
            ),
          ),
        ),
        if (_lndJournalVisible)
          LndJournalPopup(
            fetchJournal: _fetchLndJournal,
            onClose: () {
              setState(() {
                _lndJournalVisible = false;
              });
            },
          ),
      ],
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
            ..._summaryRunningLines(),
            const SizedBox(height: 1),
            const Text('Remember to:'),
            const Text('  - Back up your Lightning wallet seed'),
            const Text('  - Keep your SSH password safe'),
            const SizedBox(height: 1),
            const Text('From the dashboard: [c] configure services,'),
            const Text('[a] apply changes, [D] debug tools, [?] help.'),
            const SizedBox(height: 1),
            const Text('Press Enter to go to the dashboard.'),
          ],
        ),
      ),
    );
  }

  /// "Running:" lines for the summary screen, derived from the config
  /// the wizard just wrote. Best-effort — an unreadable config just
  /// omits the section rather than blocking the operator's exit.
  List<Component> _summaryRunningLines() {
    try {
      final config = context.read(configProvider).value;
      if (config == null) return const [];
      const dim = TextStyle(color: Color.fromRGB(150, 150, 180));
      final lines = <Component>[const SizedBox(height: 1)];
      if (config.isAppEnabled('bitcoind')) {
        final network =
            config.appOption<String>('bitcoind', 'network') ?? 'mainnet';
        lines.add(Text('  Running: bitcoind ($network)', style: dim));
      }
      if (config.isAppEnabled('lnd')) {
        final alias = config.appOption<String>('lnd', 'alias') ?? '';
        lines.add(
          Text(
            alias.isEmpty ? '  Running: lnd' : '  Running: lnd (alias: $alias)',
            style: dim,
          ),
        );
      } else if (config.isAppEnabled('cln')) {
        lines.add(const Text('  Running: cln', style: dim));
      }
      return lines.length > 1 ? lines : const [];
    } catch (e) {
      LogService.warn('summary running-lines failed: $e');
      return const [];
    }
  }
}
