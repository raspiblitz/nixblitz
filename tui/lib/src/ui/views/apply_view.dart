import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../shutdown.dart';
import '../widgets/rebuild_outcome_widgets.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';

/// Review pending config/template changes, then commit + rebuild as one step,
/// or discard them. Reachable from the dashboard via `[a]`. The git working
/// tree is the staging area — `ConfigureView` writes straight to `config.json`
/// without committing, and this view is where those dirty files turn into a
/// commit + a live system change.
enum _ApplyMode { review, running, done }

final _applyModeProvider = StateProvider<_ApplyMode>(
  (ref) => _ApplyMode.review,
);
final _applyDiffProvider = StateProvider<String?>((ref) => null);
final _applyOutputProvider = StateProvider<List<String>>((ref) => []);
final _applyExitCodeProvider = StateProvider<int?>((ref) => null);
final _applyBinaryUpdatedProvider = StateProvider<bool>((ref) => false);

/// Color a single line of unified `git diff --no-color` output.
/// - '+' lines (additions) → green, but leave the '+++ b/foo' file header alone
/// - '-' lines (deletions) → red, same carve-out for '--- a/foo'
/// - '@@ …' hunk headers   → cyan
/// - 'diff --git', 'index '  → dim grey
/// - anything else → null (fall back to the widget's default)
Color? _diffLineColor(String line) {
  if (line.startsWith('+++') || line.startsWith('---')) {
    return const Color.fromRGB(140, 140, 170);
  }
  if (line.startsWith('+')) return const Color.fromRGB(110, 220, 110);
  if (line.startsWith('-')) return const Color.fromRGB(255, 120, 120);
  if (line.startsWith('@@')) return const Color.fromRGB(120, 200, 220);
  if (line.startsWith('diff ') || line.startsWith('index ')) {
    return const Color.fromRGB(140, 140, 170);
  }
  return null;
}

class ApplyView extends StatefulComponent {
  const ApplyView({super.key});

  @override
  State<ApplyView> createState() => _ApplyViewState();
}

class _ApplyViewState extends State<ApplyView> {
  StreamSubscription<String>? _outputSub;
  bool _diffLoading = false;
  bool _started = false;

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  void _loadDiff() {
    if (_diffLoading) return;
    _diffLoading = true;
    final git = context.read(gitServiceProvider);
    git
        .diff()
        .then((text) {
          context.read(_applyDiffProvider.notifier).state = text;
        })
        .catchError((e, st) {
          LogService.error('Failed to load diff', e, st);
          context.read(_applyDiffProvider.notifier).state =
              'Failed to load diff: $e';
        });
  }

  void _reset() {
    _outputSub?.cancel();
    _outputSub = null;
    _started = false;
    _diffLoading = false;
    context.read(_applyModeProvider.notifier).state = _ApplyMode.review;
    context.read(_applyDiffProvider.notifier).state = null;
    context.read(_applyOutputProvider.notifier).state = [];
    context.read(_applyExitCodeProvider.notifier).state = null;
    context.read(_applyBinaryUpdatedProvider.notifier).state = false;
  }

  void _leave() {
    _reset();
    // Refresh the dashboard banner on return.
    context.invalidate(pendingChangesProvider);
    context.read(currentViewProvider.notifier).state = AppView.dashboard;
  }

  void _append(String line) {
    final current = context.read(_applyOutputProvider);
    context.read(_applyOutputProvider.notifier).state = [...current, line];
  }

  void _startApply() {
    if (_started) return;
    _started = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final git = context.read(gitServiceProvider);
      final systemService = context.read(systemServiceProvider);
      final sudo = context.read(sudoSessionProvider);

      context.read(_applyModeProvider.notifier).state = _ApplyMode.running;
      context.read(_applyOutputProvider.notifier).state = [];
      context.read(_applyExitCodeProvider.notifier).state = null;

      // Authenticate sudo BEFORE we touch git, so the password modal
      // appears before the user has waited for the rebuild to run and
      // hit the sudo wall halfway through.
      _append('> sudo -v (authorize)');
      sudo.ensureFresh().then((ok) {
        if (!ok) {
          _append('Authorization cancelled — aborting Apply.');
          context.read(_applyExitCodeProvider.notifier).state = 1;
          context.read(_applyModeProvider.notifier).state = _ApplyMode.done;
          _started = false;
          return;
        }
        _continueApply(baseDirPath, git, systemService);
      });
    } catch (e, st) {
      LogService.error('Apply start failed', e, st);
      _append('Error: $e');
      context.read(_applyExitCodeProvider.notifier).state = 1;
      context.read(_applyModeProvider.notifier).state = _ApplyMode.done;
      _started = false;
    }
  }

  void _continueApply(
    String baseDirPath,
    GitService git,
    SystemService systemService,
  ) {
    try {
      _append('> git add -A && git commit -m "Apply settings"');
      git
          .commitAll('Apply settings')
          .then((committed) {
            _append(
              committed
                  ? 'Committed.'
                  : 'Nothing staged (no changes to commit).',
            );
            // Pick the rebuild attribute from the just-applied
            // platform; the config notifier holds the up-to-date
            // copy because the Configure view updated it before we
            // got here.
            final platform =
                context.read(configProvider).value?.system.platform ?? 'x86';
            final attr = rebuildAttributeFor(platform);
            _append('');
            _append('> sudo nixos-rebuild switch --flake $baseDirPath#$attr');
            _append('');

            final (:output, :exitCode) = systemService.rebuild(
              baseDirPath,
              attribute: attr,
            );
            _outputSub = output.listen(
              (line) {
                LogService.info('[apply] $line');
                _append(line);
              },
              onError: (e, st) {
                LogService.error('Apply output stream error', e, st);
              },
            );
            exitCode
                .then((code) async {
                  LogService.info('apply: rebuild exited with code $code');
                  if (code == 0) {
                    final startup = context.read(startupBinaryProvider);
                    final updated = await systemService.hasNewerBinary(startup);
                    context.read(_applyBinaryUpdatedProvider.notifier).state =
                        updated;
                  }
                  context.read(_applyExitCodeProvider.notifier).state = code;
                  context.read(_applyModeProvider.notifier).state =
                      _ApplyMode.done;
                  _started = false;
                })
                .catchError((e, st) {
                  LogService.error('Apply rebuild failed', e, st);
                  context.read(_applyExitCodeProvider.notifier).state = 1;
                  context.read(_applyModeProvider.notifier).state =
                      _ApplyMode.done;
                  _started = false;
                });
          })
          .catchError((e, st) {
            LogService.error('Apply commit failed', e, st);
            _append('Commit failed: $e');
            context.read(_applyExitCodeProvider.notifier).state = 1;
            context.read(_applyModeProvider.notifier).state = _ApplyMode.done;
            _started = false;
          });
    } catch (e, st) {
      LogService.error('Apply continueApply failed', e, st);
      _append('Error: $e');
      context.read(_applyExitCodeProvider.notifier).state = 1;
      context.read(_applyModeProvider.notifier).state = _ApplyMode.done;
      _started = false;
    }
  }

  void _discard() {
    try {
      final git = context.read(gitServiceProvider);
      git
          .discardAll()
          .then((ok) {
            if (!ok) {
              LogService.warn('git checkout -- . failed during discard');
            }
            // Reload config from disk so the in-memory notifier matches.
            context.read(configProvider.notifier).reload();
            _leave();
          })
          .catchError((e, st) {
            LogService.error('Discard failed', e, st);
            _leave();
          });
    } catch (e, st) {
      LogService.error('Discard threw', e, st);
      _leave();
    }
  }

  @override
  Component build(BuildContext context) {
    final mode = context.watch(_applyModeProvider);
    return switch (mode) {
      _ApplyMode.review => _buildReview(),
      _ApplyMode.running => _buildRunning(),
      _ApplyMode.done => _buildDone(),
    };
  }

  bool _handleReviewNonScrollKey(KeyboardEvent event) {
    try {
      if (event.logicalKey == LogicalKey.escape) {
        _leave();
        return true;
      }
      if (event.logicalKey == LogicalKey.keyA) {
        _startApply();
        return true;
      }
      if (event.logicalKey == LogicalKey.keyD) {
        _discard();
        return true;
      }
      return false;
    } catch (e, st) {
      LogService.error('Apply review key handler failed', e, st);
      return true;
    }
  }

  Component _buildReview() {
    final diff = context.watch(_applyDiffProvider);

    if (diff == null) {
      Future.microtask(_loadDiff);
    }

    final lines = (diff ?? '').split('\n');
    final hasChanges = diff != null && diff.trim().isNotEmpty;

    final body = Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pending Changes',
            style: const TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          if (diff == null)
            const Text('Loading diff...')
          else if (!hasChanges)
            const Text('No pending changes — press [Esc] to return.')
          else
            Expanded(
              child: ScrollableLog(
                lines: lines,
                lineColor: _diffLineColor,
                focused: true,
                onKeyEvent: _handleReviewNonScrollKey,
              ),
            ),
          if (hasChanges) ...[
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [PgUp/PgDn] page   '
              '[a] Apply   [d] Discard   [Esc] Back',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ],
      ),
    );

    // When there's a diff to show, ScrollableLog itself is the focused
    // widget and handles keys (including delegation via onKeyEvent). In
    // the loading / no-changes branches there's no ScrollableLog, so
    // wrap in a plain Focusable just to catch Esc.
    if (hasChanges) return body;
    return Focusable(
      focused: true,
      onKeyEvent: _handleReviewNonScrollKey,
      child: body,
    );
  }

  Component _buildRunning() {
    final outputLines = context.watch(_applyOutputProvider);

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Spinner(label: 'Applying changes'),
          const Text(
            'Committing and rebuilding. This may take several minutes.',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
          const SizedBox(height: 1),
          Expanded(child: ScrollableLog(lines: outputLines, focused: true)),
          const SizedBox(height: 1),
          const Text(
            '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [g/G] top/bottom   [/] search',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ],
      ),
    );
  }

  Component _buildDone() {
    final outputLines = context.watch(_applyOutputProvider);
    final exitCode = context.watch(_applyExitCodeProvider);
    final binaryUpdated = context.watch(_applyBinaryUpdatedProvider);
    final result = RebuildResult.classify(outputLines, exitCode ?? 1);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (binaryUpdated && event.logicalKey == LogicalKey.keyR) {
            shutdownWithTerminalRestore(restartExitCode);
            return true;
          }
          if (event.logicalKey == LogicalKey.enter ||
              event.logicalKey == LogicalKey.escape) {
            _leave();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Apply done key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            rebuildHeadline(result, 'Apply'),
            const SizedBox(height: 1),
            if (result.outcome == RebuildOutcome.partial)
              rebuildFailedUnitsBanner(result.failedUnits),
            Expanded(child: ScrollableLog(lines: outputLines, focused: true)),
            const SizedBox(height: 1),
            if (binaryUpdated)
              const Text(
                'A new nixblitz binary is available.',
                style: TextStyle(color: Color.fromRGB(220, 180, 100)),
              ),
            Text(
              binaryUpdated
                  ? '[r] Restart with new binary   [Enter/Esc] Dashboard'
                  : 'Press Enter or Esc to return to dashboard.',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}
