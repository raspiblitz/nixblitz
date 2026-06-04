import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../format.dart';
import '../shutdown.dart';
import '../widgets/rebuild_outcome_widgets.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';
import '../../services/check_runner.dart';

/// Review everything queued for the next generation — local config
/// edits in the working tree, candidate flake.lock + plugin pins
/// staged by the periodic check, the cached nvd diff — then commit
/// + rebuild as one atomic step, or discard the lot. The only path
/// that touches the running system. Reachable from System → Apply
/// (and the `[a]` / `[u]` dashboard hotkeys, both of which land on
/// the System tab).
enum _ApplyMode { review, running, done }

final _applyModeProvider = StateProvider<_ApplyMode>(
  (ref) => _ApplyMode.review,
);
final _applyDiffProvider = StateProvider<String?>((ref) => null);
final _applyStagedProvider = StateProvider<StagedChanges?>((ref) => null);
final _applyOutputProvider = StateProvider<List<String>>((ref) => []);
final _applyExitCodeProvider = StateProvider<int?>((ref) => null);
final _applyBinaryUpdatedProvider = StateProvider<bool>((ref) => false);

/// Color a single line in the review pane. Section headers (lines
/// starting with `▸`) come out orange so they pop above the per-row
/// content; git diff lines retain the standard green / red / cyan
/// palette so the working-tree section still reads like a familiar
/// `git diff`.
Color? _reviewLineColor(String line) {
  if (line.startsWith('▸')) return const Color.fromRGB(247, 147, 26);
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
  final StagingService _staging = StagingService();

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  void _loadReviewState() {
    if (_diffLoading) return;
    _diffLoading = true;
    final git = context.read(gitServiceProvider);
    // Staging read is sync — kick it off immediately so the review
    // screen has lock/plugin sections rendered before the async git
    // diff resolves.
    try {
      context.read(_applyStagedProvider.notifier).state = _staging.read();
    } catch (e, st) {
      LogService.error('Failed to read staging', e, st);
      context.read(_applyStagedProvider.notifier).state = StagedChanges.empty();
    }
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
    context.read(_applyStagedProvider.notifier).state = null;
    context.read(_applyOutputProvider.notifier).state = [];
    context.read(_applyExitCodeProvider.notifier).state = null;
    context.read(_applyBinaryUpdatedProvider.notifier).state = false;
    context.read(viewBusyProvider.notifier).state = false;
  }

  void _leave() {
    _reset();
    // Refresh the dashboard banner + per-key pending state on
    // return. pendingChangesProvider drives the file-level
    // banner; committedConfigProvider drives the per-row
    // markers + header status (pendingChangeKeysProvider
    // re-evaluates automatically when committed changes).
    context.invalidate(pendingChangesProvider);
    context.invalidate(committedConfigProvider);
    // Apply is reached only from the System tab now — return there
    // so the operator can pick a follow-up action without bouncing
    // back to the dashboard first.
    context.read(currentViewProvider.notifier).state = AppView.system;
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
      context.read(viewBusyProvider.notifier).state = true;
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
          context.read(viewBusyProvider.notifier).state = false;
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
      context.read(viewBusyProvider.notifier).state = false;
      _started = false;
    }
  }

  /// Rewrite the binary's embedded Nix template files over the
  /// operator's `~/nixblitz/`, then scoped-commit only the drifted
  /// paths. No-op when [templatesDriftProvider] reports no drift.
  ///
  /// Returns true when a rewrite + commit happened. Designed to be
  /// called as a preflight inside [_continueApply] so drift
  /// introduced by a TUI upgrade (e.g. a schema-shape change like
  /// v17→v18) is repaired before the main `git commitAll` + rebuild
  /// runs. Failure is logged and swallowed — the downstream Nix
  /// build will surface a clear error if templates are still wrong.
  Future<bool> _maybeAutoRewriteTemplates(
    String baseDirPath,
    GitService git,
  ) async {
    try {
      final drift = context.read(templatesDriftProvider);
      if (!drift.hasDrift) return false;

      final driftedPaths = <String>[...drift.missing, ...drift.modified];
      final n = drift.totalChanged;

      _append('');
      _append('> auto-rewrite drifted templates ($n file${n == 1 ? "" : "s"})');

      final manifest = context.read(nixblitzBranchManifestProvider);
      final config = context.read(configProvider).value;
      final written = ScaffoldService(targetDir: baseDirPath)
          .refreshTemplatesSync(
            manifest: manifest,
            nixblitzBranchField: config?.system.nixblitzBranch,
          );
      _append('  wrote $written template files');

      _append('  > git commit -m "Refresh templates from TUI" (scoped)');
      final committed = await git.commitPaths(
        driftedPaths,
        'Refresh templates from TUI',
      );
      if (!committed) {
        _append('  (nothing to commit — templates already in sync)');
      }

      // Drift resolved — clear the dashboard banner.
      context.read(templatesDriftProvider.notifier).state =
          TemplatesDrift.inSync;

      return true;
    } catch (e, st) {
      LogService.error('apply: auto-rewrite templates failed', e, st);
      _append('  ! auto-rewrite failed: $e — continuing with build');
      return false;
    }
  }

  /// Copy any staged `flake.lock` from `/var/lib/nixblitz-tui/staging/`
  /// into the operator's `~/nixblitz/`. Plugin marker promotion is
  /// done separately via [_promoteStagedPlugins] — refreshing plugins
  /// is an async per-id git clone, while the lock copy is a single
  /// byte-for-byte file move.
  void _promoteStagedLock(String baseDirPath) {
    final lockSrc = File(_staging.lockPath);
    if (!lockSrc.existsSync()) return;
    try {
      lockSrc.copySync('$baseDirPath/flake.lock');
      _append('  promoted staged flake.lock');
    } catch (e, st) {
      LogService.error('apply: lock promotion failed', e, st);
      _append('  ! lock promotion failed: $e — continuing with build');
    }
  }

  /// Refresh each plugin whose pin moved between checks. Failures are
  /// non-fatal — one bad upstream doesn't sink the whole Apply.
  Future<void> _promoteStagedPlugins(StagedChanges staged) async {
    if (staged.pluginPins.isEmpty) return;
    final pluginService = context.read(pluginServiceProvider);
    for (final pin in staged.pluginPins) {
      _append('  refreshing plugin ${pin.pluginId}');
      try {
        final updated = await pluginService.refresh(pin.pluginId);
        _append(
          '    ${updated.id}: ${pin.currentRev.substring(0, 7)} → '
          '${updated.rev.substring(0, 7)}',
        );
      } catch (e, st) {
        LogService.error('apply: plugin refresh ${pin.pluginId} failed', e, st);
        _append('    ! ${pin.pluginId} refresh failed: $e — skipped');
      }
    }
  }

  void _continueApply(
    String baseDirPath,
    GitService git,
    SystemService systemService,
  ) {
    try {
      // Preflight: if templates on disk differ from what this binary
      // expects (e.g. a TUI upgrade changed the template shape without
      // a config schema bump), rewrite them now and commit the drifted
      // paths before the main commit. Failure is non-fatal — the build
      // will error loudly if templates are still wrong.
      _maybeAutoRewriteTemplates(baseDirPath, git)
          .then((_) async {
            final staged =
                context.read(_applyStagedProvider) ?? _staging.read();
            if (staged.lockBumpAvailable || staged.pluginPins.isNotEmpty) {
              _append('');
              _append('> promoting staged updates');
              _promoteStagedLock(baseDirPath);
              await _promoteStagedPlugins(staged);
            }
            _append('');
            _append('> git add -A && git commit -m "Apply pending changes"');
            git
                .commitAll('Apply pending changes')
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
                      context.read(configProvider).value?.system.platform ??
                      'x86';
                  final attr = rebuildAttributeFor(platform);

                  // Refresh the `nixblitz` flake input before the
                  // rebuild. Changing SystemConfig.nixblitzBranch
                  // rewrites flake.nix's URL but doesn't touch
                  // flake.lock; without this step nixos-rebuild
                  // resolves to the LOCKED rev and the branch switch
                  // is silently ignored. Runs as the operator (no
                  // sudo) — flake.lock lives under ~/nixblitz/ and is
                  // owned by the admin user. Non-fatal on failure: the
                  // rebuild will either succeed (lock already current)
                  // or fail with a clearer error.
                  _append('');
                  _append('> nix flake lock --update-input nixblitz');
                  try {
                    final lockResult = Process.runSync('nix', [
                      'flake',
                      'lock',
                      '--update-input',
                      'nixblitz',
                    ], workingDirectory: baseDirPath);
                    if (lockResult.exitCode != 0) {
                      final stderr = (lockResult.stderr as String).trim();
                      LogService.warn(
                        'apply: nix flake lock --update-input returned '
                        '${lockResult.exitCode}: $stderr',
                      );
                      _append(
                        '  ! update-input exited ${lockResult.exitCode} — '
                        'continuing with build',
                      );
                    }
                  } catch (e, st) {
                    LogService.error('apply: flake lock update failed', e, st);
                    _append(
                      '  ! update-input failed: $e — continuing with build',
                    );
                  }

                  _append('');
                  _append(
                    '> sudo nixos-rebuild switch --flake $baseDirPath#$attr',
                  );
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
                        LogService.info(
                          'apply: rebuild exited with code $code',
                        );
                        if (code == 0) {
                          final startup = context.read(startupBinaryProvider);
                          final updated = await systemService.hasNewerBinary(
                            startup,
                          );
                          context
                                  .read(_applyBinaryUpdatedProvider.notifier)
                                  .state =
                              updated;
                          await _recordApplied(git, attr);
                          // Staging artifacts were promoted into the
                          // working tree before the commit; wipe the
                          // staging dir so the next check repopulates
                          // from scratch. Failure to clear is logged
                          // but doesn't fail Apply — the next check
                          // overwrites stale entries.
                          try {
                            _staging.clearAll();
                          } catch (e, st) {
                            LogService.warn('apply: clear staging failed: $e');
                            LogService.error('apply: clearAll trace', e, st);
                          }
                          // The cached CheckResult described a delta
                          // we just consumed — inputsAhead, diffText,
                          // wouldBuild all reflect pre-apply state.
                          // Without wiping it the dashboard banner +
                          // Check panel keep claiming "N need compile"
                          // hours after the apply landed; bump the
                          // refresh tick so any watching view re-reads.
                          // The daily timer or a manual [c] repopulates.
                          try {
                            final statusFile = File(updateStatusPath);
                            if (statusFile.existsSync()) {
                              statusFile.deleteSync();
                            }
                            context
                                .read(checkRefreshTickProvider.notifier)
                                .state++;
                          } catch (e, st) {
                            LogService.warn(
                              'apply: clear update-status failed: $e',
                            );
                            LogService.error(
                              'apply: status delete trace',
                              e,
                              st,
                            );
                          }
                        }
                        context.read(_applyExitCodeProvider.notifier).state =
                            code;
                        context.read(_applyModeProvider.notifier).state =
                            _ApplyMode.done;
                        context.read(viewBusyProvider.notifier).state = false;
                        _started = false;
                      })
                      .catchError((e, st) {
                        LogService.error('Apply rebuild failed', e, st);
                        context.read(_applyExitCodeProvider.notifier).state = 1;
                        context.read(_applyModeProvider.notifier).state =
                            _ApplyMode.done;
                        context.read(viewBusyProvider.notifier).state = false;
                        _started = false;
                      });
                })
                .catchError((e, st) {
                  LogService.error('Apply commit failed', e, st);
                  _append('Commit failed: $e');
                  context.read(_applyExitCodeProvider.notifier).state = 1;
                  context.read(_applyModeProvider.notifier).state =
                      _ApplyMode.done;
                  context.read(viewBusyProvider.notifier).state = false;
                  _started = false;
                });
          })
          .catchError((e, st) {
            LogService.error('Apply preflight failed', e, st);
            _append('Error: $e');
            context.read(_applyExitCodeProvider.notifier).state = 1;
            context.read(_applyModeProvider.notifier).state = _ApplyMode.done;
            context.read(viewBusyProvider.notifier).state = false;
            _started = false;
          });
    } catch (e, st) {
      LogService.error('Apply continueApply failed', e, st);
      _append('Error: $e');
      context.read(_applyExitCodeProvider.notifier).state = 1;
      context.read(_applyModeProvider.notifier).state = _ApplyMode.done;
      context.read(viewBusyProvider.notifier).state = false;
      _started = false;
    }
  }

  /// After a successful rebuild, snapshot HEAD + the new
  /// `/run/current-system` to `last-applied.json`. The dashboard
  /// compares HEAD against this on subsequent launches to surface
  /// the "committed but never applied" case (operator quits between
  /// `git commit` and `nixos-rebuild` exit-0).
  Future<void> _recordApplied(GitService git, String attr) async {
    try {
      final rev = await git.headRef();
      if (rev == null) return;
      final readlink = Process.runSync('readlink', [
        '-f',
        '/run/current-system',
      ]);
      final toplevel = readlink.exitCode == 0
          ? (readlink.stdout as String).trim()
          : '';
      context
          .read(appliedStateServiceProvider)
          .write(rev: rev, toplevel: toplevel, flakeAttr: attr);
    } catch (e, st) {
      LogService.warn('apply: recording applied state failed: $e');
      LogService.error('apply: _recordApplied trace', e, st);
    }
  }

  void _discard() {
    try {
      final git = context.read(gitServiceProvider);
      // Wipe staging too — discarding "all pending changes" means
      // the lock bump + plugin pin candidates as well as the dirty
      // working tree. Operator can re-run a check to repopulate.
      try {
        _staging.clearAll();
      } catch (e, st) {
        LogService.warn('Discard: clearing staging failed: $e');
        LogService.error('Discard: clearAll trace', e, st);
      }
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

  /// Trigger a fresh `nixblitz check` subprocess. The subprocess
  /// writes into `update-status.json` + staging; once it exits the
  /// `checkRefreshTickProvider` bumps, which Apply watches in
  /// [_buildReview] to re-read the staging state.
  void _onCheckRequested() {
    if (context.read(runningCheckProvider)) return;
    runCheckSubprocess(context);
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
      if (event.logicalKey == LogicalKey.keyC) {
        _onCheckRequested();
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

  /// Build the prefix lines that describe staged + working-tree
  /// changes, prepended to the git diff in the scrollable area. Each
  /// section is gated on the corresponding state being non-empty.
  List<String> _buildReviewPrefix({
    required String diff,
    required StagedChanges staged,
  }) {
    final out = <String>[];
    final hasConfigEdits = diff.trim().isNotEmpty;

    if (hasConfigEdits) {
      out.add('▸ Local config edits (uncommitted)');
      out.add('');
    }

    if (staged.lockBumpAvailable) {
      final age = staged.checkedAt == null
          ? ''
          : ' (checked ${humanizeAge(staged.checkedAt!)})';
      out.add('▸ Upstream pin updates$age');
      // The candidate flake.lock lives in staging; for the diff
      // summary we mirror inputsAhead from the cached CheckResult so
      // the operator sees the named inputs rather than just "a lock
      // bump exists". Read from update-status.json directly.
      final status = readUpdateStatus();
      final inputs = status.checkResult?.inputsAhead ?? const [];
      if (inputs.isEmpty) {
        out.add('  (candidate flake.lock differs from current)');
      } else {
        for (final i in inputs) {
          final curr = i.currentRev.length >= 7
              ? i.currentRev.substring(0, 7)
              : i.currentRev;
          final next = i.upstreamRev.length >= 7
              ? i.upstreamRev.substring(0, 7)
              : i.upstreamRev;
          out.add('  ${i.name}: $curr → $next');
        }
      }
      out.add('');
    }

    if (staged.pluginPins.isNotEmpty) {
      out.add('▸ Plugin updates');
      for (final p in staged.pluginPins) {
        final fromV = p.currentVersion;
        final toV = p.upstreamVersion;
        final versionPart = (fromV != null && toV != null && fromV != toV)
            ? '$fromV → $toV'
            : '${p.currentRev.substring(0, 7)} → ${p.upstreamRev.substring(0, 7)}';
        final tags = <String>[
          if (p.isDowngrade) 'DOWNGRADE',
          if (p.forcePushDetected) 'force-pushed',
        ];
        out.add(
          '  ${p.pluginId}: $versionPart'
          '${tags.isEmpty ? "" : "  [${tags.join(", ")}]"}',
        );
      }
      out.add('');
    }

    if (staged.nvdDiff != null && staged.nvdDiff!.trim().isNotEmpty) {
      out.add('▸ Package diff (nvd)');
      for (final line in staged.nvdDiff!.split('\n')) {
        if (line.trim().isEmpty) continue;
        out.add('  $line');
      }
      out.add('');
    }

    if (hasConfigEdits) {
      out.add('▸ Working tree diff');
    }
    return out;
  }

  Component _buildReview() {
    // Re-read staging when a background check finishes.
    context.watch(checkRefreshTickProvider);
    final diff = context.watch(_applyDiffProvider);
    final staged = context.watch(_applyStagedProvider);
    final running = context.watch(runningCheckProvider);

    if (diff == null || staged == null) {
      Future.microtask(_loadReviewState);
    }

    final stagedSafe = staged ?? StagedChanges.empty();
    final diffSafe = diff ?? '';
    final prefix = _buildReviewPrefix(diff: diffSafe, staged: stagedSafe);
    final diffLines = diffSafe.trim().isEmpty
        ? const <String>[]
        : diffSafe.split('\n');
    final allLines = [...prefix, ...diffLines];
    final hasChanges =
        diff != null && (allLines.isNotEmpty || stagedSafe.isNotEmpty);

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
          if (running) ...[
            const Spinner(label: 'Running check…'),
            const SizedBox(height: 1),
          ],
          if (diff == null || staged == null)
            const Text('Loading…')
          else if (!hasChanges) ...[
            const Text('No pending changes — press [Esc] to return.'),
            ..._noPendingHint(context),
            const SizedBox(height: 1),
            const Text(
              '[c] Check for updates   [Esc] Back',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ] else
            Expanded(
              child: ScrollableLog(
                lines: allLines,
                lineColor: _reviewLineColor,
                focused: true,
                onKeyEvent: _handleReviewNonScrollKey,
              ),
            ),
          if (hasChanges) ...[
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [a] Apply   [c] Check   '
              '[d] Discard all   [Esc] Back',
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
      focused: !context.watch(modalActiveProvider),
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
            '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [gg/G] top/bottom   [/] search',
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
    final modalActive = context.watch(modalActiveProvider);

    return Focusable(
      focused: !modalActive,
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

  /// Hint rendered under "No pending changes" when a check has
  /// flagged upstream movement but no working-tree edit is queued.
  /// Phase 4 of the redesign will replace this with the multi-
  /// section review screen that surfaces staged lock bumps + plugin
  /// pins directly; this hint stays as a stopgap until then.
  List<Component> _noPendingHint(BuildContext context) {
    final status = readUpdateStatus();
    final r = status.checkResult;
    if (r == null || !r.ok) return const [];
    final stillAhead = UpdateCheckService.filterStillAhead(
      r.inputsAhead,
      flakePath: context.read(baseDirProvider),
    );
    if (stillAhead.isEmpty && r.pluginsAhead.isEmpty) return const [];

    return [
      const SizedBox(height: 1),
      const Text(
        'Upstream commits available — run System → Check first to '
        'stage them, then return here.',
        style: TextStyle(color: Color.fromRGB(220, 180, 100)),
      ),
    ];
  }
}
