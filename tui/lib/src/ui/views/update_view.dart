import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';
import '_log_height.dart';

enum _UpdateMode { selectMode, running, done }

final _updateModeProvider = StateProvider<_UpdateMode>((ref) => _UpdateMode.selectMode);
final _updateSelectionProvider = StateProvider<int>((ref) => 0);
final _updateOutputProvider = StateProvider<List<String>>((ref) => []);
final _updateExitCodeProvider = StateProvider<int?>((ref) => null);

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

      context.read(_updateModeProvider.notifier).state = _UpdateMode.running;
      context.read(_updateOutputProvider.notifier).state = [];
      context.read(_updateExitCodeProvider.notifier).state = null;

      void append(String line) {
        LogService.info('[refresh] $line');
        final current = context.read(_updateOutputProvider);
        context.read(_updateOutputProvider.notifier).state = [...current, line];
      }

      append('> Refreshing Nix templates from embedded sources');
      final templates = EmbeddedTemplates.getAll();
      for (final entry in templates.entries) {
        final file = File('$baseDirPath/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
      append('Wrote ${templates.length} template files');

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

      exitCode.then((code) {
        LogService.info('rebuild exited with code $code');
        context.read(_updateExitCodeProvider.notifier).state = code;
        context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
        _started = false;
      }).catchError((e, st) {
        LogService.error('Rebuild failed', e, st);
        context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
        _started = false;
      });
    } catch (e, st) {
      LogService.error('Failed to refresh templates', e, st);
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
      final systemService = context.read(systemServiceProvider);

      context.read(_updateModeProvider.notifier).state = _UpdateMode.running;
      context.read(_updateOutputProvider.notifier).state = [];
      context.read(_updateExitCodeProvider.notifier).state = null;

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

      exitCode.then((code) {
        LogService.info('update exited with code $code');
        context.read(_updateExitCodeProvider.notifier).state = code;
        context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
        _started = false;
      }).catchError((e, st) {
        LogService.error('Update failed', e, st);
        context.read(_updateModeProvider.notifier).state = _UpdateMode.done;
        _started = false;
      });
    } catch (e, st) {
      LogService.error('Failed to start update', e, st);
      _started = false;
    }
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

    // Reserved: spinner + spacing = ~2 lines
    final maxVisibleLines = maxVisibleLogLines(viewHeaderLines: 2);
    final visibleLines = outputLines.length > maxVisibleLines
        ? outputLines.sublist(outputLines.length - maxVisibleLines)
        : outputLines;

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Spinner(label: 'Updating...'),
          const SizedBox(height: 1),
          ...visibleLines.map(
            (line) => Text(
              line,
              style: const TextStyle(color: Color.fromRGB(180, 180, 200)),
            ),
          ),
        ],
      ),
    );
  }

  Component _buildDone() {
    final exitCode = context.watch(_updateExitCodeProvider);
    final outputLines = context.watch(_updateOutputProvider);
    final success = exitCode == 0;

    // Reserved: title + spacing + "Press Enter..." = ~4 lines
    final maxVisibleLines = maxVisibleLogLines(viewHeaderLines: 4);
    final visibleLines = outputLines.length > maxVisibleLines
        ? outputLines.sublist(outputLines.length - maxVisibleLines)
        : outputLines;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape ||
              event.logicalKey == LogicalKey.enter) {
            // Reset state for next time
            context.read(_updateModeProvider.notifier).state = _UpdateMode.selectMode;
            context.read(_updateSelectionProvider.notifier).state = 0;
            context.read(_updateOutputProvider.notifier).state = [];
            context.read(_updateExitCodeProvider.notifier).state = null;
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
            Text(
              success ? 'Update Complete!' : 'Update Failed',
              style: TextStyle(
                color: success
                    ? const Color.fromRGB(110, 220, 110)
                    : const Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            ...visibleLines.map(
              (line) => Text(
                line,
                style: const TextStyle(color: Color.fromRGB(180, 180, 200)),
              ),
            ),
            const SizedBox(height: 1),
            const Text('Press Enter or Esc to return to dashboard.'),
          ],
        ),
      ),
    );
  }
}
