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

enum _UpdateMode { selectMode, running, done }

final _updateModeProvider = StateProvider<_UpdateMode>((ref) => _UpdateMode.selectMode);
final _updateSelectionProvider = StateProvider<int>((ref) => 0);
final _updateOutputProvider = StateProvider<List<String>>((ref) => []);
final _updateExitCodeProvider = StateProvider<int?>((ref) => null);
final _updateBinaryUpdatedProvider = StateProvider<bool>((ref) => false);

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

  /// Refresh Nix template files from the embedded templates in this TUI.
  /// Writes every file under templates/ into baseDirPath, overwriting old
  /// versions. Preserves config.json. Commits changes and runs rebuild.
  void _refreshTemplates() {
    if (_started) return;
    _started = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final systemService = context.read(systemServiceProvider);
      final sudo = context.read(sudoSessionProvider);

      context.read(_updateModeProvider.notifier).state = _UpdateMode.running;
      context.read(_updateOutputProvider.notifier).state = [];
      context.read(_updateExitCodeProvider.notifier).state = null;

      void append(String line) {
        LogService.info('[refresh] $line');
        final current = context.read(_updateOutputProvider);
        context.read(_updateOutputProvider.notifier).state = [...current, line];
      }

      append('> sudo -v (authorize)');
      sudo.ensureFresh().then((ok) {
        if (!ok) {
          append('Authorization cancelled — aborting refresh.');
          context.read(_updateExitCodeProvider.notifier).state = 1;
          context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
          _started = false;
          return;
        }
        _continueRefreshTemplates(baseDirPath, systemService, append);
      });
    } catch (e, st) {
      LogService.error('Failed to refresh templates', e, st);
      context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
      context.read(_updateExitCodeProvider.notifier).state = 1;
      _started = false;
    }
  }

  void _continueRefreshTemplates(
    String baseDirPath,
    SystemService systemService,
    void Function(String) append,
  ) {
    try {
      append('> Refreshing Nix templates from embedded sources');
      final written = ScaffoldService(targetDir: baseDirPath)
          .refreshTemplatesSync();
      append('Wrote $written template files');

      // Commit via git so nix can see the changes
      append('');
      append('> git add + commit');
      final gitAdd = Process.runSync(
        'git',
        ['add', '.'],
        workingDirectory: baseDirPath,
      );
      if (gitAdd.exitCode != 0) {
        append('git add failed: ${gitAdd.stderr}');
      }
      final gitCommit = Process.runSync(
        'git',
        ['commit', '-m', 'Refresh templates from TUI'],
        workingDirectory: baseDirPath,
      );
      // Exit 1 is normal if there's nothing to commit
      append('git commit exit=${gitCommit.exitCode}');

      // Now rebuild
      append('');
      append('> sudo nixos-rebuild switch --flake $baseDirPath');
      append('');
      final (:output, :exitCode) = systemService.rebuild(baseDirPath);
      _outputSub = output.listen(
        (line) {
          LogService.info('[rebuild] $line');
          final current = context.read(_updateOutputProvider);
          context.read(_updateOutputProvider.notifier).state = [...current, line];
        },
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
        context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
        _started = false;
      });
    } catch (e, st) {
      LogService.error('continueRefreshTemplates failed', e, st);
      context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
      context.read(_updateExitCodeProvider.notifier).state = 1;
      _started = false;
    }
  }

  void _startUpdate(bool nixblitzOnly) {
    if (_started) return;
    _started = true;

    try {
      final baseDirPath = context.read(baseDirProvider);
      final sudo = context.read(sudoSessionProvider);
      context.read(_updateModeProvider.notifier).state = _UpdateMode.running;
      context.read(_updateOutputProvider.notifier).state = [];
      context.read(_updateExitCodeProvider.notifier).state = null;

      _appendUpdateLine('> sudo -v (authorize)');
      sudo.ensureFresh().then((ok) {
        if (!ok) {
          _appendUpdateLine('Authorization cancelled — aborting update.');
          context.read(_updateExitCodeProvider.notifier).state = 1;
          context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
          _started = false;
          return;
        }
        // Full system update: refresh auto_update plugins first per
        // plugins.md D11 ("Update entire system" is an implicit
        // plugin update for non-pinned plugins). NixBlitz-only stays
        // narrow — touches no plugins.
        if (nixblitzOnly) {
          _startSystemUpdate(baseDirPath, nixblitzOnly: true);
        } else {
          _refreshPluginsThenUpdate(baseDirPath);
        }
      });
    } catch (e, st) {
      LogService.error('Failed to start update', e, st);
      _started = false;
    }
  }

  void _appendUpdateLine(String line) {
    LogService.info('[update] $line');
    final current = context.read(_updateOutputProvider);
    context.read(_updateOutputProvider.notifier).state = [...current, line];
  }

  void _refreshPluginsThenUpdate(String baseDirPath) {
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
      _startSystemUpdate(baseDirPath, nixblitzOnly: false);
    }).catchError((e, st) {
      // refreshAll() captures per-plugin failures internally and
      // returns them as `failures`, so this catch only fires on a
      // truly unexpected error (e.g. main config corrupt). Don't
      // abort the system update on this — log + continue.
      LogService.error('plugin refresh during update threw', e, st);
      _appendUpdateLine('  ⚠ plugin refresh threw: $e (continuing)');
      _startSystemUpdate(baseDirPath, nixblitzOnly: false);
    });
  }

  void _startSystemUpdate(String baseDirPath, {required bool nixblitzOnly}) {
    final systemService = context.read(systemServiceProvider);

    _appendUpdateLine('');
    _appendUpdateLine(
      '> ${nixblitzOnly ? "nix flake update nixblitz" : "nix flake update"}'
      ' + nixos-rebuild switch',
    );
    _appendUpdateLine('');

    final (:output, :exitCode) = nixblitzOnly
        ? systemService.updateInput(baseDirPath, 'nixblitz')
        : systemService.updateAll(baseDirPath);

    _outputSub = output.listen(
      (line) {
        LogService.info('[update] $line');
        final current = context.read(_updateOutputProvider);
        context.read(_updateOutputProvider.notifier).state = [...current, line];
      },
      onError: (e, st) {
        LogService.error('Update output stream error', e, st);
      },
    );

    exitCode.then((code) async {
      LogService.info('update exited with code $code');
      if (code == 0) {
        final startup = context.read(startupBinaryProvider);
        final updated = await systemService.hasNewerBinary(startup);
        context.read(_updateBinaryUpdatedProvider.notifier).state = updated;
      }
      context.read(_updateExitCodeProvider.notifier).state = code;
      context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
      _started = false;
    }).catchError((e, st) {
      LogService.error('Update failed', e, st);
      context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
      _started = false;
    });
  }

  @override
  Component build(BuildContext context) {
    final mode = context.watch(_updateModeProvider);

    return switch (mode) {
      _UpdateMode.selectMode => _buildSelectMode(),
      _UpdateMode.running => _buildRunning(),
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
              context.read(_updateSelectionProvider.notifier).state = selection + 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (selection > 0) {
              context.read(_updateSelectionProvider.notifier).state = selection - 1;
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
              context.read(currentViewProvider.notifier).state = AppView.dashboard;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.escape) {
            context.read(currentViewProvider.notifier).state = AppView.dashboard;
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
              return Text('$prefix${options[i]}', style: TextStyle(color: color));
            }),
            const SizedBox(height: 1),
            Text(
              switch (selection) {
                0 => 'Updates only the NixBlitz TUI. Fast.',
                1 => 'Updates NixBlitz, NixOS, and all services. May take a while.',
                2 => 'Rewrites ~/nixblitz/ Nix files from the currently running TUI.\nUse this after a TUI upgrade to pick up new modules, or to recover\nfrom a broken config. Preserves config.json.',
                _ => '',
              },
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildRunning() {
    final outputLines = context.watch(_updateOutputProvider);

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Spinner(label: 'Updating...'),
          const SizedBox(height: 1),
          Expanded(child: ScrollableLog(lines: outputLines)),
        ],
      ),
    );
  }

  Component _buildDone() {
    final exitCode = context.watch(_updateExitCodeProvider);
    final outputLines = context.watch(_updateOutputProvider);
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
            // Reset state for next time
            context.read(_updateModeProvider.notifier).state = _UpdateMode.selectMode;
            context.read(_updateSelectionProvider.notifier).state = 0;
            context.read(_updateOutputProvider.notifier).state = [];
            context.read(_updateExitCodeProvider.notifier).state = null;
            context.read(_updateBinaryUpdatedProvider.notifier).state = false;
            // The update flow (flake update / template refresh) commits
            // and leaves the tree clean again. Force the banner to re-check.
            context.invalidate(pendingChangesProvider);
            context.read(currentViewProvider.notifier).state = AppView.dashboard;
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

