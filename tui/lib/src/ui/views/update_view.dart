import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../shutdown.dart';
import '../widgets/rebuild_outcome_widgets.dart';
import '../widgets/scrollable_log.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';

/// Update flow state machine:
///
/// - `selectMode` — user picks `TUI only` / `entire system` / `refresh templates`.
/// - `running` — preview-phase output streams: sudo auth, plugin refresh
///   (entire-system path), flake-update / template-rewrite, eval, nvd.
/// - `previewing` — show the nvd diff, await `[a]` (apply) / `[d]` (discard).
/// - `applying` — rebuild streams output.
/// - `done` — outcome classifier + embedded final diff.
enum _UpdateMode { selectMode, running, previewing, applying, done }

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

class UpdateView extends StatefulComponent {
  const UpdateView({super.key});

  @override
  State<UpdateView> createState() => _UpdateViewState();
}

class _UpdateViewState extends State<UpdateView> {
  StreamSubscription<String>? _outputSub;
  bool _started = false;

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
        if (nixblitzOnly) {
          _previewSystemUpdate(baseDirPath, nixblitzOnly: true);
        } else {
          _refreshPluginsThenPreview(baseDirPath);
        }
      });
    } catch (e, st) {
      LogService.error('Failed to start update', e, st);
      _failToDone(1);
    }
  }

  /// Refresh Nix template files from the embedded templates in this
  /// TUI, commit, then preview + (on confirm) rebuild.
  void _refreshTemplates() {
    if (_started) return;
    _started = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final sudo = context.read(sudoSessionProvider);

      _resetForRunning();
      _appendUpdateLine('> sudo -v (authorize)');

      sudo.ensureFresh().then((ok) {
        if (!ok) {
          _appendUpdateLine('Authorization cancelled — aborting refresh.');
          _failToDone(1);
          return;
        }
        _writeTemplatesAndPreview(baseDirPath);
      });
    } catch (e, st) {
      LogService.error('Failed to refresh templates', e, st);
      _failToDone(1);
    }
  }

  // ── Phase 1 helpers (running) ──────────────────────────────────

  void _refreshPluginsThenPreview(String baseDirPath) {
    final pluginService = context.read(pluginServiceProvider);

    _appendUpdateLine('> nixblitz plugin refresh (auto_update plugins)');
    pluginService.refreshAll(includePinned: false).then((result) {
      for (final p in result.refreshed) {
        final pin = p.pinnedRev.length >= 7
            ? p.pinnedRev.substring(0, 7)
            : p.pinnedRev;
        _appendUpdateLine('  refreshed ${p.id} → $pin');
      }
      for (final f in result.failures) {
        _appendUpdateLine('  ⚠ ${f.plugin.id}: ${f.error}');
      }
      for (final s in result.skipped) {
        _appendUpdateLine('  skipped (pinned): ${s.id}');
      }
      if (result.totalAttempted == 0 && result.skipped.isEmpty) {
        _appendUpdateLine('  (no installed plugins)');
      } else {
        _appendUpdateLine(
          '${result.refreshed.length} refreshed, '
          '${result.failures.length} failed, '
          '${result.skipped.length} skipped',
        );
      }
      _previewSystemUpdate(baseDirPath, nixblitzOnly: false);
    }).catchError((e, st) {
      LogService.error('plugin refresh during update threw', e, st);
      _appendUpdateLine('  ⚠ plugin refresh threw: $e (continuing)');
      _previewSystemUpdate(baseDirPath, nixblitzOnly: false);
    });
  }

  void _previewSystemUpdate(
    String baseDirPath, {
    required bool nixblitzOnly,
  }) {
    final systemService = context.read(systemServiceProvider);
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
    lockRun.result.then((res) async {
      await _outputSub?.cancel();
      _outputSub = null;
      if (!res.success) {
        _failToDone(res.exitCode);
        return;
      }
      if (!res.committed) {
        _appendUpdateLine('');
        _appendUpdateLine('Nothing to apply.');
        _completeWithSuccess();
        return;
      }
      _runPreviewDiff(baseDirPath);
    }).catchError((e, st) {
      LogService.error('updateLock failed', e, st);
      _failToDone(1);
    });
  }

  void _writeTemplatesAndPreview(String baseDirPath) {
    try {
      _appendUpdateLine('> Refreshing Nix templates from embedded sources');
      final written = ScaffoldService(targetDir: baseDirPath)
          .refreshTemplatesSync();
      _appendUpdateLine('Wrote $written template files');

      _appendUpdateLine('');
      _appendUpdateLine('> git add . && git commit -m "Refresh templates"');
      Process.runSync(
        'git', ['add', '.'],
        workingDirectory: baseDirPath,
      );
      final commit = Process.runSync(
        'git', ['commit', '-m', 'Refresh templates from TUI'],
        workingDirectory: baseDirPath,
      );
      // Exit 1 here usually means "nothing to commit" — same as
      // updateLock's `committed: false` branch.
      if (commit.exitCode != 0) {
        _appendUpdateLine('  (nothing to commit — templates unchanged)');
        _appendUpdateLine('');
        _appendUpdateLine('Nothing to apply.');
        _completeWithSuccess();
        return;
      }
      _runPreviewDiff(baseDirPath);
    } catch (e, st) {
      LogService.error('writeTemplatesAndPreview failed', e, st);
      _failToDone(1);
    }
  }

  void _runPreviewDiff(String baseDirPath) {
    final systemService = context.read(systemServiceProvider);
    _appendUpdateLine('');
    final preview = systemService.previewPackageDiff(flakePath: baseDirPath);
    _outputSub = preview.output.listen(_appendUpdateLine);
    preview.result.then((res) async {
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
    }).catchError((e, st) {
      LogService.error('previewPackageDiff failed', e, st);
      _failToDone(1);
    });
  }

  // ── Phase 2 (previewing → applying or selectMode) ──────────────

  void _applyPreview() {
    if (_started) return;
    _started = true;
    final baseDirPath = context.read(baseDirProvider);
    context.read(_updateModeProvider.notifier).state = _UpdateMode.applying;
    _appendUpdateLine('');
    _appendUpdateLine('> sudo nixos-rebuild switch --flake $baseDirPath');
    _appendUpdateLine('');
    _runRebuild(baseDirPath);
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
      context.read(_updateModeProvider.notifier).state =
          _UpdateMode.applying;
    }

    final (:output, :exitCode) = systemService.rebuild(baseDirPath);
    _outputSub = output.listen(
      _appendUpdateLine,
      onError: (e, st) {
        LogService.error('Rebuild output stream error', e, st);
      },
    );

    exitCode.then((code) async {
      LogService.info('rebuild exited with code $code');
      if (code == 0) {
        final startup = context.read(startupBinaryProvider);
        final updated = await systemService.hasNewerBinary(startup);
        context.read(_updateBinaryUpdatedProvider.notifier).state = updated;
      }
      context.read(_updateExitCodeProvider.notifier).state = code;
      context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
      _started = false;
    }).catchError((e, st) {
      LogService.error('Rebuild failed', e, st);
      _failToDone(1);
    });
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

  // ── Build ──────────────────────────────────────────────────────

  @override
  Component build(BuildContext context) {
    final mode = context.watch(_updateModeProvider);

    return switch (mode) {
      _UpdateMode.selectMode => _buildSelectMode(),
      _UpdateMode.running => _buildRunning(
          label: 'Computing update preview…',
          hint: 'Evaluating new system. First run after a flake bump '
              'can take 30-60s.',
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
    const options = [
      'Update NixBlitz TUI only',
      'Update entire system',
      'Refresh Nix templates (from current TUI)',
      'Cancel',
    ];

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (selection < options.length - 1) {
              context.read(_updateSelectionProvider.notifier).state =
                  selection + 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (selection > 0) {
              context.read(_updateSelectionProvider.notifier).state =
                  selection - 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            if (selection == 0) {
              _startUpdate(true);
            } else if (selection == 1) {
              _startUpdate(false);
            } else if (selection == 2) {
              _refreshTemplates();
            } else {
              context.read(currentViewProvider.notifier).state =
                  AppView.dashboard;
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
            ...List.generate(options.length, (i) {
              final prefix = i == selection ? '> ' : '  ';
              final color = i == selection
                  ? const Color.fromRGB(247, 147, 26)
                  : const Color.fromRGB(200, 200, 200);
              return Text(
                '$prefix${options[i]}',
                style: TextStyle(color: color),
              );
            }),
            const SizedBox(height: 1),
            Text(
              switch (selection) {
                0 => 'Updates only the NixBlitz TUI. Fast.',
                1 =>
                  'Updates NixBlitz, NixOS, and all services. May take a while.',
                2 =>
                  'Rewrites ~/nixblitz/ Nix files from the currently running TUI.\nUse this after a TUI upgrade to pick up new modules, or to recover\nfrom a broken config. Preserves config.json.',
                _ => '',
              },
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
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
          Expanded(child: ScrollableLog(lines: outputLines)),
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
            context.invalidate(pendingChangesProvider);
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
            Expanded(child: ScrollableLog(lines: outputLines)),
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
              ...diffText.split('\n').map(
                    (l) => Text(
                      l,
                      style: TextStyle(
                        color: _nvdLineColor(l) ??
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
