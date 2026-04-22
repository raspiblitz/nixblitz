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
    final configPath = '$baseDir/config.json';
    final configExists = File(configPath).existsSync();

    // Safety: if we're not on a live ISO AND there's no config, this is
    // an installed non-NixBlitz system. Refuse to start to prevent accidents
    // (install mode would try to wipe a disk).
    if (!isLiveIso && !configExists) {
      return _RefusalScreen(message: _noConfigNonIsoMessage);
    }

    AppView initialView;
    if (isLiveIso) {
      initialView = AppView.install;
    } else {
      // configExists is guaranteed true here (refusal above handles the else)
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
                // Wrap the view swap in a stable SizedBox.expand so the
                // flex parent data applied by Expanded stays anchored to
                // one render object across view (and internal step)
                // changes. Without this, views that swap their root
                // widget type between steps (install, setup, update…)
                // lose the flex data and crash when they contain an
                // inner Expanded(ScrollableLog).
                Expanded(
                  child: SizedBox.expand(
                    child: switch (context.watch(currentViewProvider)) {
                      AppView.install => const InstallView(),
                      AppView.setup => const SetupView(),
                      AppView.dashboard => const DashboardView(),
                      AppView.configure => const ConfigureView(),
                      AppView.apply => const ApplyView(),
                      AppView.update => const UpdateView(),
                    },
                  ),
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
                      AppView.update =>
                        '[↑/↓]: Navigate  [Enter]: Select  [Esc]: Back  [?]: Help',
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

const String _noConfigNonIsoMessage = '''
This system does not appear to be a NixBlitz installation.

To install NixBlitz:
  1. Boot a NixOS ISO (any recent 25.11 image)
  2. Run: nix run git+https://forge.f44.fyi/f44/nixblitz_ng

Refusing to start install mode on an installed system to prevent
accidental disk wipe.

Press any key to exit.''';

class _RefusalScreen extends StatelessComponent {
  final String message;

  const _RefusalScreen({required this.message});

  @override
  Component build(BuildContext context) {
    return ProviderScope(
      child: NoctermApp(
        title: 'NixBlitz',
        theme: TuiThemeData.dark,
        home: Focusable(
          focused: true,
          onKeyEvent: (event) {
            _shutdownWithTerminalRestore(1);
            return true;
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NixBlitz — Cannot Start',
                  style: TextStyle(
                    color: Color.fromRGB(255, 80, 80),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 1),
                Text(message),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
