import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../providers/ui_state_provider.dart';

final _rebuildOutputProvider = StateProvider<List<String>>((ref) => []);
final _rebuildRunningProvider = StateProvider<bool>((ref) => false);

class ApplyView extends StatefulComponent {
  const ApplyView({super.key});

  @override
  State<ApplyView> createState() => _ApplyViewState();
}

class _ApplyViewState extends State<ApplyView> {
  StreamSubscription<String>? _outputSub;

  @override
  void initState() {
    super.initState();
    _startRebuild();
  }

  void _startRebuild() {
    try {
      final configAsync = context.read(configProvider);
      final config = configAsync.value;
      if (config == null) return;

      final baseDirPath = context.read(baseDirProvider);
      final systemService = context.read(systemServiceProvider);

      context.read(_rebuildRunningProvider.notifier).state = true;
      context.read(_rebuildOutputProvider.notifier).state = [
        '> sudo nixos-rebuild switch --flake $baseDirPath',
        '',
      ];

      final (:output, :exitCode) = systemService.rebuild(baseDirPath);

      _outputSub = output.listen((line) {
        final current = context.read(_rebuildOutputProvider);
        context.read(_rebuildOutputProvider.notifier).state = [
          ...current,
          line,
        ];
      });

      exitCode.then((code) {
        final current = context.read(_rebuildOutputProvider);
        final msg = code == 0
            ? '\nRebuild successful. Press Esc to return.'
            : '\nRebuild failed (exit code $code). Press Esc to return.';
        context.read(_rebuildOutputProvider.notifier).state = [...current, msg];
        context.read(_rebuildRunningProvider.notifier).state = false;
      });
    } catch (e, st) {
      LogService.error('Failed to start rebuild', e, st);
      context.read(_rebuildRunningProvider.notifier).state = false;
      final current = context.read(_rebuildOutputProvider);
      context.read(_rebuildOutputProvider.notifier).state = [
        ...current,
        '\nFailed to start rebuild. Check logs and try again.',
      ];
    }
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final outputLines = context.watch(_rebuildOutputProvider);
    final running = context.watch(_rebuildRunningProvider);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape && !running) {
            context.read(currentViewProvider.notifier).state =
                AppView.dashboard;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Apply view key handler failed', e, st);
          return true;
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              running ? 'Applying configuration...' : 'Rebuild complete',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 1),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ListView.builder(
                itemCount: outputLines.length,
                itemBuilder: (context, index) {
                  return Text(
                    outputLines[index],
                    style: const TextStyle(color: Color.fromRGB(180, 180, 200)),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
