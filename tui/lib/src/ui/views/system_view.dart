import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

import '../../providers/ui_state_provider.dart';

// ---------------------------------------------------------------------------
// System view — sidebar: [Check, Apply].
//
// Combines what used to be two top-level views (Apply, Update) into one
// place. The sidebar splits intent: read-only probes (Check) live next to
// destructive rebuilds (Apply). Each section's body is a description+button
// list — the operator can see what every action does before pressing Enter.
//
// For v0 the action runners live in the pre-existing ApplyView /
// UpdateView state machines. Picking an action transitions to one of those
// views (now non-top-menu); they hand control back to System on Esc.
// ---------------------------------------------------------------------------

/// Which sidebar section is selected.
enum _SystemSection { check, apply }

/// Which column has focus — same idiom as Configure.
enum _SystemColumn { sidebar, content }

final _systemSectionProvider = StateProvider<_SystemSection>(
  (ref) => _SystemSection.check,
);
final _systemColumnProvider = StateProvider<_SystemColumn>(
  (ref) => _SystemColumn.sidebar,
);
final _systemActionIndexProvider = StateProvider<int>((ref) => 0);

/// A row in the body's action list. Each action has a short, action-y
/// label + a longer description rendered below it in dim text.
class _SystemAction {
  const _SystemAction({
    required this.label,
    required this.description,
    required this.run,
  });
  final String label;
  final String description;
  final void Function(BuildContext) run;
}

class SystemView extends StatelessComponent {
  const SystemView({super.key});

  @override
  Component build(BuildContext context) {
    final section = context.watch(_systemSectionProvider);
    final column = context.watch(_systemColumnProvider);
    final actionIndex = context.watch(_systemActionIndexProvider);

    final actions = _actionsFor(section);
    final selected = actionIndex.clamp(0, actions.length - 1);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          // Vertical nav within the focused column.
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (column == _SystemColumn.sidebar) {
              if (section == _SystemSection.check) {
                context.read(_systemSectionProvider.notifier).state =
                    _SystemSection.apply;
                context.read(_systemActionIndexProvider.notifier).state = 0;
              }
            } else {
              if (selected < actions.length - 1) {
                context.read(_systemActionIndexProvider.notifier).state =
                    selected + 1;
              }
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (column == _SystemColumn.sidebar) {
              if (section == _SystemSection.apply) {
                context.read(_systemSectionProvider.notifier).state =
                    _SystemSection.check;
                context.read(_systemActionIndexProvider.notifier).state = 0;
              }
            } else {
              if (selected > 0) {
                context.read(_systemActionIndexProvider.notifier).state =
                    selected - 1;
              }
            }
            return true;
          }

          // Enter: descend (sidebar → content, content → run action).
          if (event.logicalKey == LogicalKey.enter ||
              event.logicalKey == LogicalKey.space) {
            if (column == _SystemColumn.sidebar) {
              context.read(_systemColumnProvider.notifier).state =
                  _SystemColumn.content;
            } else {
              actions[selected].run(context);
            }
            return true;
          }

          // Esc: ascend (content → sidebar, sidebar → dashboard).
          if (event.logicalKey == LogicalKey.escape) {
            if (column == _SystemColumn.content) {
              context.read(_systemColumnProvider.notifier).state =
                  _SystemColumn.sidebar;
            } else {
              context.read(currentViewProvider.notifier).state =
                  AppView.dashboard;
            }
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('System view key handler failed', e, st);
          return true;
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SystemSidebar(
                  current: section,
                  focused: column == _SystemColumn.sidebar,
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: BoxBorder.all(
                        color: column == _SystemColumn.content
                            ? const Color.fromRGB(140, 140, 180)
                            : const Color.fromRGB(50, 50, 70),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 1,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _headingFor(section),
                          style: const TextStyle(
                            color: Color.fromRGB(247, 147, 26),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 1),
                        for (var i = 0; i < actions.length; i++) ...[
                          _ActionRow(
                            action: actions[i],
                            focused: i == selected,
                          ),
                          if (i < actions.length - 1) const SizedBox(height: 1),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _headingFor(_SystemSection section) => switch (section) {
    _SystemSection.check => 'Check — read-only probes',
    _SystemSection.apply => 'Apply — run nixos-rebuild',
  };

  List<_SystemAction> _actionsFor(_SystemSection section) => switch (section) {
    _SystemSection.check => [
      _SystemAction(
        label: 'Simple check',
        description:
            'Polls each flake input + each installed plugin against '
            'its pinned rev (HTTP only, no rebuild). Daily timer '
            'runs this in the background. ~5s.',
        run: (ctx) {
          // Route to the Update view; user presses [c] there.
          // Auto-trigger is a follow-up.
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
      _SystemAction(
        label: 'Heavy check',
        description:
            'Builds the new system closure off-disk and runs nvd '
            'diff so you can preview every package change before '
            'committing. Slow — several minutes — and CPU-heavy. '
            'Weekly timer runs this in the background.',
        run: (ctx) {
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
      _SystemAction(
        label: 'Plugins check',
        description:
            'Same as Simple check but scoped to installed plugins '
            'only — useful right after pushing a plugin update '
            'when you want the ↑ marker to reflect upstream right '
            'now without waiting for the daily timer.',
        run: (ctx) {
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
    ],
    _SystemSection.apply => [
      _SystemAction(
        label: 'Apply pending changes',
        description:
            'Runs nixos-rebuild switch against the current '
            'config.json so unsaved edits in Configure flip from '
            '"pending" to "applied" on the running system. The '
            'flake.lock is left as-is.',
        run: (ctx) {
          ctx.read(currentViewProvider.notifier).state = AppView.apply;
        },
      ),
      _SystemAction(
        label: 'Update TUI only',
        description:
            'Pulls the latest nixblitz_ng input + rebuilds. The '
            'new binary replaces the running TUI on the next '
            'launch; other services stay on their pinned versions.',
        run: (ctx) {
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
      _SystemAction(
        label: 'Update entire system',
        description:
            'Pulls every flake input, runs the heavy check for an '
            'nvd preview, then rebuilds + activates. The full path '
            "everyone calls 'an update' on RaspiBlitz.",
        run: (ctx) {
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
      _SystemAction(
        label: 'Refresh plugins',
        description:
            'For every installed plugin whose upstream is ahead of '
            'its pinned rev, pull the new rev to disk. Combine '
            'with Apply pending changes (or Update entire system) '
            'to activate the new plugin versions.',
        run: (ctx) {
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
    ],
  };
}

// ---------------------------------------------------------------------------
// _SystemSidebar — left column with Check / Apply
// ---------------------------------------------------------------------------

class _SystemSidebar extends StatelessComponent {
  final _SystemSection current;
  final bool focused;

  const _SystemSidebar({required this.current, required this.focused});

  @override
  Component build(BuildContext context) {
    const accent = Color.fromRGB(247, 147, 26);
    const idle = Color.fromRGB(180, 180, 200);
    const dim = Color.fromRGB(85, 85, 105);
    const borderActive = Color.fromRGB(140, 140, 180);
    const borderIdle = Color.fromRGB(50, 50, 70);

    // Widest label = "Check" / "Apply" → 5 chars, plus the standard
    // sidebar overhead (cursor + padding + nocterm border deflate).
    final width = 5 + 8;

    return Container(
      width: width.toDouble(),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      decoration: BoxDecoration(
        border: BoxBorder.all(color: focused ? borderActive : borderIdle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sidebarEntry(
            'Check',
            current == _SystemSection.check,
            accent,
            idle,
            dim,
          ),
          _sidebarEntry(
            'Apply',
            current == _SystemSection.apply,
            accent,
            idle,
            dim,
          ),
        ],
      ),
    );
  }

  Component _sidebarEntry(
    String label,
    bool isActive,
    Color accent,
    Color idle,
    Color dim,
  ) {
    final showCursor = isActive && focused;
    final prefix = showCursor ? '> ' : '  ';
    final color = focused ? (isActive ? accent : idle) : dim;
    return Text(
      '$prefix$label',
      style: TextStyle(
        color: color,
        fontWeight: showCursor ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ActionRow — one button + description in the body
// ---------------------------------------------------------------------------

class _ActionRow extends StatelessComponent {
  final _SystemAction action;
  final bool focused;

  const _ActionRow({required this.action, required this.focused});

  @override
  Component build(BuildContext context) {
    const accent = Color.fromRGB(247, 147, 26);
    const normal = Color.fromRGB(200, 200, 200);
    const dim = Color.fromRGB(140, 140, 150);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${focused ? "> " : "  "}${action.label}',
          style: TextStyle(
            color: focused ? accent : normal,
            fontWeight: focused ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text('    ${action.description}', style: const TextStyle(color: dim)),
      ],
    );
  }
}
