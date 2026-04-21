import 'dart:convert';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import 'views/dashboard_view.dart';
import 'views/apply_view.dart';
import 'views/configure_view.dart';
import 'views/install_view.dart';
import 'views/setup_view.dart';
import 'views/update_view.dart';
import 'widgets/help_popup.dart';
import '../providers/ui_state_provider.dart';

final _helpVisibleProvider = StateProvider<bool>((ref) => false);

/// Detect if running on a live NixOS ISO by checking if root is tmpfs.
bool _isLiveIso() {
  try {
    final result = Process.runSync('stat', ['-f', '-c', '%T', '/']);
    return (result.stdout as String).trim() == 'tmpfs';
  } catch (e) {
    LogService.warn('Could not detect live ISO: $e');
    return false;
  }
}

void _shutdownWithTerminalRestore([int exitCode = 0]) {
  try {
    if (stdin.hasTerminal) {
      stdin.lineMode = true;
      stdin.echoMode = true;
    }
  } catch (e) {
    LogService.warn('Failed to restore terminal mode before shutdown: $e');
  }
  shutdownApp(exitCode);
}

class NixBlitzApp extends StatelessComponent {
  final String baseDir;

  const NixBlitzApp({super.key, required this.baseDir});

  @override
  Component build(BuildContext context) {
    // Detect if we're on a live ISO (root filesystem is tmpfs).
    // On a live ISO, always start in install mode regardless of existing config,
    // so a failed install attempt can be retried.
    final isLiveIso = _isLiveIso();

    AppView initialView;
    if (isLiveIso) {
      initialView = AppView.install;
    } else {
      final configPath = '$baseDir/config.json';
      final configExists = File(configPath).existsSync();

      if (!configExists) {
        initialView = AppView.install;
      } else {
        try {
          final content = File(configPath).readAsStringSync();
          final json = jsonDecode(content) as Map<String, dynamic>;
          initialView = json['initialized'] == true
              ? AppView.dashboard
              : AppView.setup;
        } catch (e, st) {
          LogService.error(
            'Failed to read config.json for mode detection',
            e,
            st,
          );
          initialView = AppView.dashboard;
        }
      }
    }

    return ProviderScope(
      overrides: [
        baseDirProvider.overrideWithValue(baseDir),
        currentViewProvider.overrideWith((ref) => initialView),
      ],
      child: NoctermApp(
        title: 'NixBlitz',
        theme: TuiThemeData.dark.copyWith(
          primary: const Color.fromRGB(247, 147, 26),
          background: const Color.fromRGB(24, 24, 36),
          surface: const Color.fromRGB(36, 36, 54),
          onBackground: const Color.fromRGB(220, 220, 220),
          onSurface: const Color.fromRGB(200, 200, 200),
          onPrimary: const Color.fromRGB(0, 0, 0),
          outline: const Color.fromRGB(80, 80, 100),
          outlineVariant: const Color.fromRGB(60, 60, 80),
          selectionColor: const Color.fromRGB(80, 80, 120),
        ),
        home: const _Shell(),
      ),
    );
  }
}

class _Shell extends StatelessComponent {
  const _Shell();

  @override
  Component build(BuildContext context) {
    final helpVisible = context.watch(_helpVisibleProvider);

    return Stack(
      children: [
        Focusable(
          focused: !helpVisible,
          onKeyEvent: (event) {
            try {
              if (event.matches(LogicalKey.keyC, ctrl: true)) {
                _shutdownWithTerminalRestore();
                return true;
              }
              if (event.logicalKey == LogicalKey.question) {
                context.read(_helpVisibleProvider.notifier).state = true;
                return true;
              }
              final currentView = context.read(currentViewProvider);
              if (currentView == AppView.dashboard) {
                if (event.logicalKey == LogicalKey.keyC) {
                  context.read(currentViewProvider.notifier).state =
                      AppView.configure;
                  return true;
                }
                if (event.logicalKey == LogicalKey.keyU) {
                  context.read(currentViewProvider.notifier).state =
                      AppView.update;
                  return true;
                }
                if (event.logicalKey == LogicalKey.keyQ) {
                  _shutdownWithTerminalRestore();
                  return true;
                }
              }
              return false;
            } catch (e, st) {
              LogService.error('Global shell key handler failed', e, st);
              return true;
            }
          },
          child: Container(
            padding: const EdgeInsets.all(1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 1,
                  ),
                  decoration: const BoxDecoration(
                    border: BoxBorder(
                      bottom: BorderSide(color: Color.fromRGB(80, 80, 100)),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'NIXBLITZ',
                        style: TextStyle(
                          color: Color.fromRGB(247, 147, 26),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'v0.1.0',
                        style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 1),
                Expanded(
                  child: switch (context.watch(currentViewProvider)) {
                    AppView.install => const InstallView(),
                    AppView.setup => const SetupView(),
                    AppView.dashboard => const DashboardView(),
                    AppView.configure => const ConfigureView(),
                    AppView.apply => const ApplyView(),
                AppView.update => const UpdateView(),
                  },
                ),
                const Divider(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    switch (context.watch(currentViewProvider)) {
                      AppView.install =>
                        '[↑/↓]: Navigate  [Enter]: Select  [?]: Help',
                      AppView.setup => 'Setting up...  [?]: Help',
                      AppView.dashboard =>
                        '[c]: Configure  [u]: Update  [?]: Help  [q]: Quit',
                      AppView.configure =>
                        '[↑/↓]: Navigate  [Enter]: Edit  [Esc]: Back  [?]: Help',
                      AppView.apply => '[Esc]: Back (when done)  [?]: Help',
                    AppView.update => '[↑/↓]: Navigate  [Enter]: Select  [Esc]: Back  [?]: Help',
                    },
                    style: const TextStyle(
                      color: Color.fromRGB(247, 147, 26),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (helpVisible)
          HelpPopup(
            onClose: () {
              context.read(_helpVisibleProvider.notifier).state = false;
            },
          ),
      ],
    );
  }
}
