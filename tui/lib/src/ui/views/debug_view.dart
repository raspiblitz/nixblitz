import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import 'debug/generate_blocks.dart';
import 'debug/service_health.dart';
import 'debug/show_password.dart';
import 'debug/tail_log.dart';
import '../../providers/ui_state_provider.dart';

/// Debug-only utilities for exercising the stack on a running VM:
/// regtest block generation, service health rollups, log tailing, etc.
///
/// Lives in the production TUI for now because the commands need to run
/// on the installed system. A future `features.system.debugScreen` flavor
/// gate could compile-time-exclude this whole subtree via
/// `const bool _kDebugEnabled = bool.fromEnvironment('ENABLE_DEBUG', …);`.
enum DebugAction {
  menu,
  serviceHealth,
  showPassword,
  tailLog,
  generateBlocks,
}

final _debugActionProvider = StateProvider<DebugAction>(
  (ref) => DebugAction.menu,
);

class DebugView extends StatelessComponent {
  const DebugView({super.key});

  @override
  Component build(BuildContext context) {
    final action = context.watch(_debugActionProvider);
    return switch (action) {
      DebugAction.menu => const _DebugMenu(),
      DebugAction.serviceHealth => ServiceHealthView(
        onExit: () => _backToMenu(context),
      ),
      DebugAction.showPassword => ShowPasswordView(
        onExit: () => _backToMenu(context),
      ),
      DebugAction.tailLog => TailLogView(onExit: () => _backToMenu(context)),
      DebugAction.generateBlocks => GenerateBlocksView(
        onExit: () => _backToMenu(context),
      ),
    };
  }

  static void _backToMenu(BuildContext context) {
    context.read(_debugActionProvider.notifier).state = DebugAction.menu;
  }
}

final _menuSelectionProvider = StateProvider<int>((ref) => 0);

class _DebugMenu extends StatelessComponent {
  const _DebugMenu();

  @override
  Component build(BuildContext context) {
    final configAsync = context.watch(configProvider);
    final config = configAsync.value;
    final regtest = config?.bitcoind.network == "regtest";
    final blitzApi = config?.blitzApi.enabled ?? false;

    final entries = <_MenuEntry>[
      const _MenuEntry(
        DebugAction.serviceHealth,
        'Service health',
        'Systemd status for bitcoind / lnd / blitz-api / nginx / …',
      ),
      if (blitzApi)
        const _MenuEntry(
          DebugAction.showPassword,
          'Show API login password',
          'Reveals /var/lib/blitz_api/.login-password (native_python mode).',
        ),
      const _MenuEntry(
        DebugAction.tailLog,
        'Tail a unit log',
        'Pick a systemd unit → last 200 lines from journalctl.',
      ),
      if (regtest)
        const _MenuEntry(
          DebugAction.generateBlocks,
          'Generate regtest blocks',
          'Mine N blocks with optional initial delay + interval.',
        ),
    ];

    final selection = context
        .watch(_menuSelectionProvider)
        .clamp(0, entries.length - 1);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            context.read(currentViewProvider.notifier).state =
                AppView.dashboard;
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowUp ||
              event.logicalKey == LogicalKey.keyK) {
            if (selection > 0) {
              context.read(_menuSelectionProvider.notifier).state =
                  selection - 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowDown ||
              event.logicalKey == LogicalKey.keyJ) {
            if (selection < entries.length - 1) {
              context.read(_menuSelectionProvider.notifier).state =
                  selection + 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            context.read(_debugActionProvider.notifier).state =
                entries[selection].action;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Debug menu key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Debug',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            ...List.generate(entries.length, (i) {
              final focused = i == selection;
              final prefix = focused ? '> ' : '  ';
              final color = focused
                  ? const Color.fromRGB(247, 147, 26)
                  : const Color.fromRGB(200, 200, 200);
              return Text(
                '$prefix${entries[i].label}',
                style: TextStyle(color: color),
              );
            }),
            const SizedBox(height: 1),
            Text(
              entries.isEmpty
                  ? '(no actions applicable to this configuration)'
                  : entries[selection].description,
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuEntry {
  final DebugAction action;
  final String label;
  final String description;
  const _MenuEntry(this.action, this.label, this.description);
}
