import 'dart:async';
import 'dart:convert' show LineSplitter;
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
import 'update/action_gating.dart';

/// Update flow state machine:
///
/// - `selectMode` — user picks `TUI only` / `entire system` / `refresh templates`.
/// - `viewingCachedDiff` — full-screen scroll of the cached `nvd diff` from
///   the periodic heavy check. Reached from `selectMode` via `[v]` when a
///   cached diff is present; `[Esc]` returns to `selectMode`.
/// - `running` — preview-phase output streams: sudo auth, plugin refresh
///   (entire-system path), flake-update / template-rewrite, eval, nvd.
/// - `previewing` — show the nvd diff, await `[a]` (apply) / `[d]` (discard).
/// - `applying` — rebuild streams output.
/// - `done` — outcome classifier + embedded final diff.
enum _UpdateMode {
  selectMode,
  heavyConfirm, // yes/no prompt before running the heavy check
  runningCheck, // spinner + scrolling journal output for `[C]`
  viewingCachedDiff,
  running,
  previewing,
  applying,
  done,
}

final _updateModeProvider = StateProvider<_UpdateMode>(
  (ref) => _UpdateMode.selectMode,
);
final _updateSelectionProvider = StateProvider<int>((ref) => 0);
final _updateOutputProvider = StateProvider<List<String>>((ref) => []);
final _updateExitCodeProvider = StateProvider<int?>((ref) => null);
final _updateBinaryUpdatedProvider = StateProvider<bool>((ref) => false);

/// Captured `nvd diff` output. Set when the preview phase resolves;
/// rendered both in the `previewing` screen and on the `done` screen
/// after a successful rebuild.
final _packageDiffProvider = StateProvider<String?>((ref) => null);

/// Increments to force `_buildSelectMode` to repaint after a
/// manual `[c]` / `[C]` check completes. The Status panel reads
/// the file on every rebuild, so a tick is enough — no
/// re-fetching needed.
final _updateTickerProvider = StateProvider<int>((ref) => 0);

class UpdateView extends StatefulComponent {
  const UpdateView({super.key});

  @override
  State<UpdateView> createState() => _UpdateViewState();
}

class _UpdateViewState extends State<UpdateView> {
  StreamSubscription<String>? _outputSub;
  bool _started = false;

  /// Index of the action row whose "press Enter again to override"
  /// prompt is currently armed. Reset to null when the user changes
  /// selection or runs the action. Plain instance variable (NOT a
  /// StateProvider) per nocterm rules — see CLAUDE.md.
  int? _overrideArmedFor;

  /// True while a `[c]` lightweight check subprocess is in flight.
  /// Drives an inline spinner above the Status panel; the panel
  /// re-reads update-status.json on every rebuild after the
  /// subprocess exits.
  bool _lightCheckRunning = false;

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  // ── Entry points (selectMode → running) ────────────────────────

  void _startUpdate(bool nixblitzOnly) {
    if (_started) return;
    _started = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final sudo = context.read(sudoSessionProvider);

      _resetForRunning();
      _appendUpdateLine('> sudo -v (authorize)');

      sudo.ensureFresh().then((ok) {
        if (!ok) {
          _appendUpdateLine('Authorization cancelled — aborting update.');
          _failToDone(1);
          return;
        }
        _previewSystemUpdate(baseDirPath, nixblitzOnly: nixblitzOnly);
      });
    } catch (e, st) {
      LogService.error('Failed to start update', e, st);
      _failToDone(1);
    }
  }

  void _previewSystemUpdate(
    String baseDirPath, {
    required bool nixblitzOnly,
    String? initialHead,
  }) {
    final systemService = context.read(systemServiceProvider);
    final git = context.read(gitServiceProvider);
    final updateArgs = nixblitzOnly
        ? const ['flake', 'update', 'nixblitz']
        : const ['flake', 'update'];
    final commitMessage = nixblitzOnly
        ? 'Update nixblitz'
        : 'Update all flake inputs';

    _appendUpdateLine('');
    final lockRun = systemService.updateLock(
      flakePath: baseDirPath,
      updateArgs: updateArgs,
      commitMessage: commitMessage,
    );
    _outputSub = lockRun.output.listen(_appendUpdateLine);
    lockRun.result
        .then((res) async {
          await _outputSub?.cancel();
          _outputSub = null;
          if (!res.success) {
            _failToDone(res.exitCode);
            return;
          }
          // "Anything to apply?" — capture HEAD now and compare against
          // wherever the flow started. Covers plugin-refresh commits
          // upstream of us as well as updateLock's flake.lock commit.
          // initialHead is null when this method was called directly
          // from _startUpdate's nixblitzOnly path; treat that as "the
          // only commit point is updateLock" and use the lock's own
          // committed flag.
          final currentHead = await git.headRef();
          final headMoved = initialHead != null
              ? currentHead != initialHead
              : res.committed;
          if (!headMoved) {
            _appendUpdateLine('');
            _appendUpdateLine('Nothing to apply.');
            _completeWithSuccess();
            return;
          }
          _runPreviewDiff(baseDirPath);
        })
        .catchError((e, st) {
          LogService.error('updateLock failed', e, st);
          _failToDone(1);
        });
  }

  void _runPreviewDiff(String baseDirPath) {
    final systemService = context.read(systemServiceProvider);
    _appendUpdateLine('');
    final preview = systemService.previewPackageDiff(flakePath: baseDirPath);
    _outputSub = preview.output.listen(_appendUpdateLine);
    preview.result
        .then((res) async {
          await _outputSub?.cancel();
          _outputSub = null;

          if (!res.success) {
            _appendUpdateLine('');
            _appendUpdateLine(res.errorMessage ?? 'Preview failed.');
            // Eval failed — let the user discard the lock commit from
            // the preview screen so they can decide. Show the running
            // log as the "diff".
            context.read(_packageDiffProvider.notifier).state =
                res.errorMessage ?? 'Preview failed (no detail).';
            context.read(_updateModeProvider.notifier).state =
                _UpdateMode.previewing;
            _started = false;
            return;
          }

          if (res.noChanges) {
            _appendUpdateLine('');
            _appendUpdateLine('No package changes — proceeding to rebuild.');
            // Skip the preview screen; go straight to applying.
            _runRebuild(baseDirPath);
            return;
          }

          context.read(_packageDiffProvider.notifier).state = res.diffText;
          context.read(_updateModeProvider.notifier).state =
              _UpdateMode.previewing;
          _started = false;
        })
        .catchError((e, st) {
          LogService.error('previewPackageDiff failed', e, st);
          _failToDone(1);
        });
  }

  // ── Phase 2 (previewing → applying or selectMode) ──────────────

  void _applyPreview() {
    if (_started) return;
    _started = true;
    final baseDirPath = context.read(baseDirProvider);
    final sudo = context.read(sudoSessionProvider);

    // Re-ensure sudo freshness before kicking off `sudo -n`. The
    // operator may have sat on the preview screen long enough for
    // the cached timestamp to expire (default sudo grace is 5
    // min); without this, `sudo -n nixos-rebuild switch` exits 1
    // with "sudo: a password is required" in stderr and we
    // mis-classify that as a generic "Update Failed".
    context.read(_updateModeProvider.notifier).state = _UpdateMode.applying;
    _appendUpdateLine('');
    _appendUpdateLine('> sudo -v (re-authorize for apply)');
    sudo.ensureFresh().then((ok) {
      if (!ok) {
        _appendUpdateLine('Authorization cancelled — aborting apply.');
        _failToDone(1);
        return;
      }
      final platform =
          context.read(configProvider).value?.system.platform ?? 'x86';
      final attr = rebuildAttributeFor(platform);
      _appendUpdateLine(
        '> sudo nixos-rebuild switch --flake $baseDirPath#$attr',
      );
      _appendUpdateLine('');
      _runRebuild(baseDirPath);
    });
  }

  void _discardPreview() {
    if (_started) return;
    _started = true;
    final baseDirPath = context.read(baseDirProvider);
    final systemService = context.read(systemServiceProvider);

    _appendUpdateLine('');
    _appendUpdateLine('> git reset --hard HEAD~1 (discarding update)');
    systemService.revertLastFlakeCommit(baseDirPath).then((ok) {
      _appendUpdateLine(
        ok
            ? 'Update discarded. Working tree restored.'
            : 'Discard failed — see ~/nixblitz.log.',
      );
      // Reset back to selectMode so the user can pick again.
      _resetToSelect();
    });
  }

  // ── Phase 3 (applying → done) ──────────────────────────────────

  void _runRebuild(String baseDirPath) {
    final systemService = context.read(systemServiceProvider);
    if (context.read(_updateModeProvider) != _UpdateMode.applying) {
      context.read(_updateModeProvider.notifier).state = _UpdateMode.applying;
    }

    final platform =
        context.read(configProvider).value?.system.platform ?? 'x86';
    final attr = rebuildAttributeFor(platform);
    final (:output, :exitCode) = systemService.rebuild(
      baseDirPath,
      attribute: attr,
    );
    _outputSub = output.listen(
      _appendUpdateLine,
      onError: (e, st) {
        LogService.error('Rebuild output stream error', e, st);
      },
    );

    exitCode
        .then((code) async {
          LogService.info('rebuild exited with code $code');
          if (code == 0) {
            final startup = context.read(startupBinaryProvider);
            final updated = await systemService.hasNewerBinary(startup);
            context.read(_updateBinaryUpdatedProvider.notifier).state = updated;
            // Self-heal template drift introduced by a freshly-pulled
            // TUI binary. The dashboard banner is a fail-safe; in
            // steady state this hook prevents it from ever firing.
            // We're in a Process.exitCode.then continuation, not a
            // nocterm key handler, so `await` here is fine — the
            // Dart event loop pumps these futures normally.
            final autorewrote = await _maybeAutoRewriteTemplates();
            if (autorewrote) {
              _appendUpdateLine('Auto-rewrote drifted templates.');
            }
          }
          context.read(_updateExitCodeProvider.notifier).state = code;
          context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
          _started = false;
        })
        .catchError((e, st) {
          LogService.error('Rebuild failed', e, st);
          _failToDone(1);
        });
  }

  /// Rewrite the binary's embedded Nix template files over the
  /// operator's `~/nixblitz/`, then commit only the template paths.
  /// No-op when [templatesDriftProvider] reports no drift.
  ///
  /// Returns true when a rewrite + commit happened. Designed to be
  /// called from the end of an Update flow so drift introduced by a
  /// freshly-pulled TUI binary self-heals before the operator sees
  /// the dashboard again.
  ///
  /// Logs progress lines into the Update output stream so the
  /// operator sees what happened without having to dig in
  /// `~/nixblitz.log`.
  Future<bool> _maybeAutoRewriteTemplates() async {
    try {
      final drift = context.read(templatesDriftProvider);
      if (!drift.hasDrift) return false;

      final baseDirPath = context.read(baseDirProvider);
      final git = context.read(gitServiceProvider);

      // Snapshot the drifted paths BEFORE the rewrite — once we
      // overwrite the files the on-disk diff disappears, but those
      // are exactly the paths we want to scope the commit to.
      final driftedPaths = <String>[...drift.missing, ...drift.modified];
      final n = drift.totalChanged;

      _appendUpdateLine('');
      _appendUpdateLine(
        '> auto-rewrite drifted templates ($n file${n == 1 ? "" : "s"})',
      );

      // Scoped commit (commitPaths over driftedPaths) so we don't
      // sweep up unrelated working-tree edits the operator may
      // have. Everything in driftedPaths came from
      // EmbeddedTemplates.getAll() keys, so they're safe relative
      // paths under baseDirPath.
      final written = ScaffoldService(
        targetDir: baseDirPath,
      ).refreshTemplatesSync();
      _appendUpdateLine('  wrote $written template files');

      _appendUpdateLine(
        '  > git commit -m "Refresh templates from TUI" (scoped)',
      );
      final committed = await git.commitPaths(
        driftedPaths,
        'Refresh templates from TUI',
      );
      if (!committed) {
        _appendUpdateLine('  (nothing to commit — templates already in sync)');
      }

      // Resolve the dashboard banner — drift just got fixed.
      context.read(templatesDriftProvider.notifier).state =
          TemplatesDrift.inSync;

      return true;
    } catch (e, st) {
      LogService.error('auto-rewrite templates failed', e, st);
      _appendUpdateLine('  ⚠ auto-rewrite failed: $e');
      return false;
    }
  }

  // ── State helpers ──────────────────────────────────────────────

  void _resetForRunning() {
    context.read(_updateModeProvider.notifier).state = _UpdateMode.running;
    context.read(_updateOutputProvider.notifier).state = [];
    context.read(_updateExitCodeProvider.notifier).state = null;
    context.read(_packageDiffProvider.notifier).state = null;
    context.read(_updateBinaryUpdatedProvider.notifier).state = false;
  }

  void _resetToSelect() {
    context.read(_updateModeProvider.notifier).state = _UpdateMode.selectMode;
    context.read(_updateSelectionProvider.notifier).state = 0;
    context.read(_updateOutputProvider.notifier).state = [];
    context.read(_updateExitCodeProvider.notifier).state = null;
    context.read(_packageDiffProvider.notifier).state = null;
    context.read(_updateBinaryUpdatedProvider.notifier).state = false;
    _started = false;
  }

  void _completeWithSuccess() {
    context.read(_updateExitCodeProvider.notifier).state = 0;
    context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
    _started = false;
  }

  void _failToDone(int code) {
    context.read(_updateExitCodeProvider.notifier).state = code;
    context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
    _started = false;
  }

  void _appendUpdateLine(String line) {
    LogService.info('[update] $line');
    final current = context.read(_updateOutputProvider);
    context.read(_updateOutputProvider.notifier).state = [...current, line];
  }

  /// Fires off a fresh `nixblitz check light` subprocess. Same code
  /// path the `nixblitz-check-light.timer` systemd unit runs daily;
  /// this is the manual `[c]` shortcut so an operator who just
  /// pushed a flake-input fix doesn't have to drop to a shell.
  ///
  /// The shape is constrained by nocterm pitfall #3: `await` inside
  /// a key handler chain stalls because the Dart event loop doesn't
  /// pump while nocterm renders. `Process.start` returns a Future
  /// whose `.then` callbacks ARE pumped, which is why we structure
  /// the work as a chain of `.then` callbacks rather than `await`s.
  void _onLightCheckRequested() {
    if (_lightCheckRunning) return; // re-entrancy guard
    _lightCheckRunning = true;

    Process.start('nixblitz', const ['check', 'light'], runInShell: false)
        .then((proc) {
          // Drain stdout/stderr so the child doesn't block on a full
          // pipe. `[c]` is fast (~3-5s) and we don't surface its output;
          // the Status panel reads the JSON file the subprocess wrote.
          proc.stdout.drain<void>();
          proc.stderr.drain<void>();
          proc.exitCode.then((code) {
            if (code != 0) {
              LogService.warn('manual light check exited $code');
            }
            _lightCheckRunning = false;
            // Bump the ticker so the panel re-reads the now-fresh status.
            try {
              final notifier = context.read(_updateTickerProvider.notifier);
              notifier.state = notifier.state + 1;
            } catch (_) {
              // context may be unmounted; ignore.
            }
          });
        })
        .catchError((Object e, StackTrace st) {
          LogService.error('failed to start nixblitz check light', e, st);
          _lightCheckRunning = false;
          try {
            final notifier = context.read(_updateTickerProvider.notifier);
            notifier.state = notifier.state + 1;
          } catch (_) {}
        });

    // Bump now so the spinner appears immediately. NOTE: setting a
    // StateProvider triggers an immediate rebuild and discards the
    // rest of the handler — that's why we kicked off Process.start
    // BEFORE this line. The Future returned by Process.start lives
    // independently of the current call stack, so the .then chain
    // above still runs.
    final notifier = context.read(_updateTickerProvider.notifier);
    notifier.state = notifier.state + 1;
  }

  /// Kicks off the heavy update check by shelling out to
  /// `nixblitz check heavy` directly. Same code path the scheduled
  /// `nixblitz-check-heavy.service` runs through `nixblitz check
  /// heavy` — and the TUI runs as `admin` per the standard install,
  /// so user/env match. We tried `systemctl start --wait
  /// nixblitz-check-heavy.service` originally but non-root users
  /// can't start system units without a polkit rule, so it
  /// returned "Access denied" exit 4. Direct invocation sidesteps
  /// that since the work itself (cp tree to /tmp, nix flake update,
  /// nvd diff) only needs admin's own privileges.
  ///
  /// Same Process.start-then-chain shape as `_onLightCheckRequested`
  /// (see nocterm pitfall #3). State writes happen BEFORE the
  /// Process.start call so the rebuild from setting `runningCheck`
  /// doesn't discard the kick-off.
  void _startHeavyCheck() {
    context.read(_updateOutputProvider.notifier).state = [];
    context.read(_updateModeProvider.notifier).state = _UpdateMode.runningCheck;

    final p = Process.start('nixblitz', const [
      'check',
      'heavy',
    ], runInShell: false);

    p
        .then((proc) {
          final stdoutSub = proc.stdout
              .transform(systemEncoding.decoder)
              .transform(const LineSplitter())
              .listen(_appendUpdateLine);
          final stderrSub = proc.stderr
              .transform(systemEncoding.decoder)
              .transform(const LineSplitter())
              .listen(_appendUpdateLine);
          proc.exitCode.then((code) async {
            await stdoutSub.cancel();
            await stderrSub.cancel();
            _appendUpdateLine('');
            _appendUpdateLine('— heavy check finished (exit $code) —');
            // Bump the ticker so the Status panel re-reads the file
            // once the operator returns to selectMode.
            try {
              final notifier = context.read(_updateTickerProvider.notifier);
              notifier.state = notifier.state + 1;
            } catch (_) {
              // context may be unmounted; ignore.
            }
            // Don't auto-leave runningCheck — let the operator read
            // the tail. They press Esc to return.
          });
        })
        .catchError((Object e, StackTrace st) {
          LogService.error('failed to start nixblitz-check-heavy', e, st);
          _appendUpdateLine('error: $e');
        });
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Component build(BuildContext context) {
    final mode = context.watch(_updateModeProvider);

    return switch (mode) {
      _UpdateMode.selectMode => _buildSelectMode(),
      _UpdateMode.heavyConfirm => _buildHeavyConfirm(),
      _UpdateMode.runningCheck => _buildRunningCheck(),
      _UpdateMode.viewingCachedDiff => _buildViewCachedDiff(),
      _UpdateMode.running => _buildRunning(
        label: 'Computing update preview…',
        hint:
            'Building new system from binary cache. First run '
            'after a flake bump can take a few minutes; the '
            'subsequent rebuild on Apply will be near-instant '
            'since everything is already in /nix/store.',
      ),
      _UpdateMode.previewing => _buildPreview(),
      _UpdateMode.applying => _buildRunning(
        label: 'Applying changes…',
        hint: null,
      ),
      _UpdateMode.done => _buildDone(),
    };
  }

  Component _buildSelectMode() {
    final selection = context.watch(_updateSelectionProvider);
    // Forces a rebuild after a manual `[c]` check completes. Value
    // is intentionally unused — the Status panel re-reads
    // update-status.json on every rebuild, so a bump is enough.
    context.watch(_updateTickerProvider);

    final status = readUpdateStatus();
    // Filter cached `inputsAhead` against the live `flake.lock` so
    // we don't surface phantom updates that already landed. Same
    // signal we use for the dashboard banner; reused here to gate
    // both the Status panel rows and the action subtitles.
    final liveInputsAhead =
        (status.lightweight != null && status.lightweight!.ok)
        ? UpdateCheckService.filterStillAhead(
            status.lightweight!.inputsAhead,
            flakePath: context.read(baseDirProvider),
          )
        : <InputAhead>[];
    final hasCachedDiff = _hasCachedDiff(status, liveInputsAhead);

    // Compute gating from cache (pure function from action_gating.dart).
    final actionStates = computeUpdateActionStates(
      status,
      tuiInputName: 'nixblitz',
      liveInputsAhead: liveInputsAhead,
    );

    // Action option metadata, paired with its computed state.
    final options = <_Option>[
      _Option(
        label: 'Update NixBlitz TUI only',
        state: actionStates.tuiOnly,
        runAction: () => _startUpdate(true),
      ),
      _Option(
        label: 'Update entire system',
        state: actionStates.entireSystem,
        runAction: () => _startUpdate(false),
      ),
      _Option(
        label: 'Cancel',
        state: const ActionState(enabled: true, subtitle: ''),
        runAction: () {
          context.read(currentViewProvider.notifier).state = AppView.dashboard;
        },
      ),
    ];

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (selection < options.length - 1) {
              _overrideArmedFor = null;
              context.read(_updateSelectionProvider.notifier).state =
                  selection + 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (selection > 0) {
              _overrideArmedFor = null;
              context.read(_updateSelectionProvider.notifier).state =
                  selection - 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyV && hasCachedDiff) {
            context.read(_updateModeProvider.notifier).state =
                _UpdateMode.viewingCachedDiff;
            return true;
          }
          if (event.logicalKey == LogicalKey.keyC && event.modifiers.shift) {
            context.read(_updateModeProvider.notifier).state =
                _UpdateMode.heavyConfirm;
            return true;
          }
          if (event.logicalKey == LogicalKey.keyC && !event.modifiers.shift) {
            _onLightCheckRequested();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyP) {
            // Deep-link to the configure view with the plugins
            // service pre-selected. There is no standalone
            // AppView.plugins; plugins live inside configure_view's
            // service list at index 6 (see configure_view.dart's
            // `services` array). Setting the index BEFORE the view
            // mutation ensures the configure view's first build
            // already reads the right index.
            context.read(selectedServiceIndexProvider.notifier).state = 6;
            context.read(currentViewProvider.notifier).state =
                AppView.configure;
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            final opt = options[selection];
            if (opt.state.enabled || _overrideArmedFor == selection) {
              _overrideArmedFor = null;
              opt.runAction();
            } else {
              // Soft-disabled — first Enter arms, second runs.
              _overrideArmedFor = selection;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.escape) {
            context.read(currentViewProvider.notifier).state =
                AppView.dashboard;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Update select key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'System Update',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            ..._buildStatusPanel(context, liveInputsAhead),
            const SizedBox(height: 1),
            // Actions header — distinguishes the interactive list
            // below from the info-only Status panel above. Generic
            // navigation hints (arrows / Enter / Esc) live in the
            // global footer; we don't repeat them here.
            const Text(
              'Actions',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            ...List.generate(options.length, (i) {
              final opt = options[i];
              final selected = i == selection;
              final isOverrideArmed = _overrideArmedFor == i;
              final prefix = selected ? '> ' : '  ';
              final mainColor = !opt.state.enabled
                  ? const Color.fromRGB(120, 120, 120)
                  : selected
                  ? const Color.fromRGB(247, 147, 26)
                  : const Color.fromRGB(235, 235, 235);
              // Bold the unselected enabled rows too — keeps the
              // action labels visually heavier than Status row text
              // (which is plain weight at a similar grey).
              final fontWeight = !opt.state.enabled
                  ? FontWeight.normal
                  : FontWeight.bold;
              final subtitle = isOverrideArmed
                  ? 'no changes — press Enter again to rebuild anyway'
                  : opt.state.subtitle;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$prefix${opt.label}',
                    style: TextStyle(color: mainColor, fontWeight: fontWeight),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      '    — $subtitle',
                      style: TextStyle(
                        color: isOverrideArmed
                            ? const Color.fromRGB(220, 180, 100)
                            : const Color.fromRGB(150, 150, 180),
                      ),
                    ),
                ],
              );
            }),
            if (hasCachedDiff) ...[
              const SizedBox(height: 1),
              const Text(
                '[v] view full package diff',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Yes/no prompt before kicking off the heavy check. Heavy is
  /// expensive enough (1-10 min, ~125 MB to /tmp) that we don't want
  /// a stray `[C]` keystroke to start it. `[y]` runs, `[n]` / `[Esc]`
  /// returns to selectMode.
  Component _buildHeavyConfirm() {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyY) {
            _startHeavyCheck();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyN ||
              event.logicalKey == LogicalKey.escape) {
            context.read(_updateModeProvider.notifier).state =
                _UpdateMode.selectMode;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Heavy confirm key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Run full check?',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 1),
            Text(
              'Takes 1–10 minutes. Downloads ~125 MB to /tmp.',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            SizedBox(height: 1),
            Text(
              '[y] Yes   [n / Esc] No',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  /// Spinner + scrolling log for the heavy check. Output streams in
  /// from the `nixblitz check heavy` subprocess via stdout/stderr.
  /// `[Esc]` returns to selectMode at any time — the subprocess keeps
  /// running in the background, and the Status panel will reflect
  /// its result whenever it lands.
  Component _buildRunningCheck() {
    final outputLines = context.watch(_updateOutputProvider);
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            context.read(_updateModeProvider.notifier).state =
                _UpdateMode.selectMode;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('runningCheck key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Spinner(label: 'Running full update check…'),
            const SizedBox(height: 1),
            const Text(
              'Heavy check evaluates a full system rebuild in /tmp '
              'and runs `nvd diff` against /run/current-system. Takes '
              '1–10 minutes; can be left running while you do other '
              'things.',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: outputLines, focused: true)),
            const SizedBox(height: 1),
            const Text(
              '[Esc] back to menu',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  /// Renders the Status panel — top of the System Update menu.
  /// Reads `readUpdateStatus()` synchronously each rebuild (cheap
  /// file read; same pattern the dashboard banner uses).
  ///
  /// Three rows: `flake inputs`, `TUI binary` (split out from the
  /// flake inputs because it has its own apply path — pull + restart
  /// rather than rebuild), and `system closure` from the heavy check.
  /// An optional plugin-pointer row appears when `pluginsAhead` is
  /// non-empty, directing the operator to the plugins menu where
  /// per-plugin updates live.
  List<Component> _buildStatusPanel(
    BuildContext context,
    List<InputAhead> liveInputsAhead,
  ) {
    const tuiInputName = 'nixblitz';
    final status = readUpdateStatus();
    final children = <Component>[
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: const [
          Text('Status', style: TextStyle(color: Color.fromRGB(150, 150, 180))),
          Text(
            '[c] check now   [C] full check',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ],
      ),
      const SizedBox(height: 1),
    ];

    if (_lightCheckRunning) {
      children.add(Spinner(label: 'Checking for updates…'));
      children.add(const SizedBox(height: 1));
    }

    final hasLight = status.lightweight != null && status.lightweight!.ok;
    final hasHeavy = status.heavy != null && status.heavy!.ok;

    if (!hasLight && !hasHeavy) {
      children.add(
        const Text(
          '  no cached check yet — runs daily',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      );
      return children;
    }

    if (hasLight) {
      final light = status.lightweight!;
      // `liveInputsAhead` is the caller-side filterStillAhead — no
      // recomputation here.
      final stillAhead = liveInputsAhead;

      // flake inputs row — exclude the TUI input.
      final nonTui = stillAhead.where((e) => e.name != tuiInputName).toList();
      final lightAge = humanizeAge(light.checkedAt);
      final lightStale =
          DateTime.now().toUtc().difference(light.checkedAt) >
          const Duration(days: 2);
      final flakeValue = nonTui.isEmpty
          ? 'up to date'
          : nonTui.map((e) => e.name).take(3).join(', ') +
                (nonTui.length > 3 ? ' (+${nonTui.length - 3} more)' : '');
      children.add(
        _statusRow(
          label: 'flake inputs',
          value: flakeValue,
          age: lightAge,
          stale: lightStale,
        ),
      );

      // TUI binary row — only the TUI input.
      final tuiAhead = stillAhead.where((e) => e.name == tuiInputName).toList();
      final tuiValue = tuiAhead.isEmpty
          ? 'up to date'
          : 'ahead — pull and rebuild';
      children.add(
        _statusRow(
          label: 'TUI binary',
          value: tuiValue,
          age: lightAge,
          stale: lightStale,
        ),
      );

      // Plugin pointer row — only when pluginsAhead non-empty.
      if (light.pluginsAhead.isNotEmpty) {
        final n = light.pluginsAhead.length;
        children.add(const SizedBox(height: 1));
        children.add(
          Text(
            '  ! $n plugin update${n == 1 ? "" : "s"} available — '
            'open [p] plugins menu',
            style: const TextStyle(color: Color.fromRGB(247, 147, 26)),
          ),
        );
      }
    }

    if (hasHeavy) {
      final heavy = status.heavy!;
      final heavyAge = humanizeAge(heavy.checkedAt);
      final heavyStale =
          DateTime.now().toUtc().difference(heavy.checkedAt) >
          const Duration(days: 14);
      // If a fresher light check found the live lock at upstream,
      // the cached diff has been overtaken by an Update that already
      // landed — treat as no changes regardless of what the cached
      // diff reports.
      final diffOvertaken = isHeavyDiffStale(
        status,
        liveInputsAhead: liveInputsAhead,
      );
      final String heavyValue;
      if (heavy.noChanges || heavy.diffText.trim().isEmpty || diffOvertaken) {
        heavyValue = 'no system changes';
      } else {
        heavyValue = '${_countDiffChanges(heavy.diffText)} changes pending';
      }
      children.add(
        _statusRow(
          label: 'system closure',
          value: heavyValue,
          age: heavyAge,
          stale: heavyStale,
        ),
      );
    } else {
      children.add(
        _statusRow(
          label: 'system closure',
          value: 'no full check yet',
          age: '—',
          stale: false,
        ),
      );
    }

    return children;
  }

  Component _statusRow({
    required String label,
    required String value,
    required String age,
    required bool stale,
  }) {
    // 16-char label column keeps values lined up across rows AND
    // guarantees ≥2 spaces of breathing room after the longest current
    // label ("system closure" = 14 chars). Earlier 14-char padding
    // produced "system closureN changes pending" with no separator.
    final padded = label.padRight(16);
    final prefix = stale ? '! ' : '  ';
    final color = stale
        ? const Color.fromRGB(220, 180, 100) // warn yellow
        : const Color.fromRGB(200, 200, 200);
    return Text('$prefix$padded$value  ($age)', style: TextStyle(color: color));
  }

  /// True when the cached heavy diff is non-empty AND still relevant
  /// (the lock hasn't already advanced past it). Drives whether we
  /// show the `[v] view full package diff` keybind hint — there's
  /// no point offering to view a diff the operator has already
  /// applied.
  bool _hasCachedDiff(UpdateStatus status, List<InputAhead> liveInputsAhead) {
    final h = status.heavy;
    if (h == null || !h.ok || h.noChanges || h.diffText.trim().isEmpty) {
      return false;
    }
    return !isHeavyDiffStale(status, liveInputsAhead: liveInputsAhead);
  }

  /// Counts `[U.]` / `[A.]` / `[R.]` lines in the cached diff —
  /// i.e. the actual change count, ignoring the "Closure size"
  /// summary and any blank lines. nvd's bracket prefix is the
  /// stable signal across versions.
  int _countDiffChanges(String diffText) {
    var n = 0;
    for (final line in diffText.split('\n')) {
      if (line.startsWith('[U.') ||
          line.startsWith('[U]') ||
          line.startsWith('[A.') ||
          line.startsWith('[A]') ||
          line.startsWith('[R.') ||
          line.startsWith('[R]')) {
        n++;
      }
    }
    return n;
  }

  Component _buildViewCachedDiff() {
    final status = readUpdateStatus();
    final heavy = status.heavy;
    final diffText = heavy?.diffText ?? '';
    final lines = diffText.split('\n');
    final ago = heavy != null ? humanizeAge(heavy.checkedAt) : 'unknown';

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape ||
              event.logicalKey == LogicalKey.keyQ) {
            context.read(_updateModeProvider.notifier).state =
                _UpdateMode.selectMode;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('View cached diff key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cached package diff — checked $ago',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: ScrollableLog(
                lines: lines,
                lineColor: _nvdLineColor,
                focused: true,
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              '[Esc] back to menu   [↑/↓ j/k] scroll   [PgUp/PgDn] page',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildRunning({required String label, String? hint}) {
    final outputLines = context.watch(_updateOutputProvider);

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Spinner(label: label),
          if (hint != null) ...[
            const SizedBox(height: 1),
            Text(
              hint,
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
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

  Component _buildPreview() {
    final diffText = context.watch(_packageDiffProvider) ?? '';
    final lines = diffText.split('\n');

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyA) {
            _applyPreview();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyD ||
              event.logicalKey == LogicalKey.escape) {
            _discardPreview();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Preview key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Package update preview',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: ScrollableLog(
                lines: lines,
                lineColor: _nvdLineColor,
                focused: true,
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              '[a] Apply   [d] Discard   [Esc] Discard',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildDone() {
    final exitCode = context.watch(_updateExitCodeProvider);
    final outputLines = context.watch(_updateOutputProvider);
    final diffText = context.watch(_packageDiffProvider);
    final binaryUpdated = context.watch(_updateBinaryUpdatedProvider);
    final result = RebuildResult.classify(outputLines, exitCode ?? 1);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (binaryUpdated && event.logicalKey == LogicalKey.keyR) {
            shutdownWithTerminalRestore(restartExitCode);
            return true;
          }
          if (event.logicalKey == LogicalKey.escape ||
              event.logicalKey == LogicalKey.enter) {
            _resetToSelect();
            // File-level banner + per-key pending state both
            // refresh — see apply_view._leave for context.
            context.invalidate(pendingChangesProvider);
            context.invalidate(committedConfigProvider);
            context.read(currentViewProvider.notifier).state =
                AppView.dashboard;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Update done key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            rebuildHeadline(result, 'Update'),
            const SizedBox(height: 1),
            if (result.outcome == RebuildOutcome.partial)
              rebuildFailedUnitsBanner(result.failedUnits),
            Expanded(child: ScrollableLog(lines: outputLines, focused: true)),
            if (diffText != null && diffText.trim().isNotEmpty) ...[
              const SizedBox(height: 1),
              const Text(
                'Package changes',
                style: TextStyle(
                  color: Color.fromRGB(247, 147, 26),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 1),
              ...diffText
                  .split('\n')
                  .map(
                    (l) => Text(
                      l,
                      style: TextStyle(
                        color:
                            _nvdLineColor(l) ??
                            const Color.fromRGB(200, 200, 200),
                      ),
                    ),
                  ),
            ],
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

/// Action option metadata for `_buildSelectMode`. Pairs a label with
/// its computed [ActionState] (enabled flag + subtitle) and the
/// callback to run when the row is activated.
class _Option {
  const _Option({
    required this.label,
    required this.state,
    required this.runAction,
  });
  final String label;
  final ActionState state;
  final void Function() runAction;
}

/// Per-line colour for `nvd diff` output. Keeps the diff readable
/// at a glance: orange for version changes, green for additions,
/// red for removals, cyan for the closure-size summary.
Color? _nvdLineColor(String line) {
  if (line.startsWith('[U.') || line.startsWith('[U]')) {
    return const Color.fromRGB(247, 147, 26); // orange — updated
  }
  if (line.startsWith('[A.') || line.startsWith('[A]')) {
    return const Color.fromRGB(110, 220, 110); // green — added
  }
  if (line.startsWith('[R.') || line.startsWith('[R]')) {
    return const Color.fromRGB(255, 120, 120); // red — removed
  }
  if (line.startsWith('Closure size')) {
    return const Color.fromRGB(120, 200, 220); // cyan — summary
  }
  return null;
}
