import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

import '../format.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';

// ---------------------------------------------------------------------------
// System view — sidebar: [Check, Apply].
//
// Combines what used to be two top-level views (Apply, Update) into one
// place. The sidebar splits intent: read-only probes (Check) live next to
// destructive rebuilds (Apply). Each section's body shows the relevant
// status + actions; the operator stays inside System rather than getting
// teleported to a separate Update screen.
//
// Apply actions still navigate to the pre-existing ApplyView / UpdateView
// state machines for the rebuild streaming UX (heavy refactor to fold them
// in is a follow-up). Check actions run inline via `nixblitz check ...`
// subprocesses and refresh the status panel on exit.
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

/// The check subprocess currently in flight, by mode (`light` / `heavy`).
/// `null` when nothing is running. Drives the inline spinner + prevents
/// re-trigger spam while a check is mid-flight.
final _runningCheckProvider = StateProvider<String?>((ref) => null);

/// Bumps each time a check subprocess exits. Watched by the status
/// panel so it re-reads `update-status.json` after a check writes
/// fresh data.
final _checkRefreshTickProvider = StateProvider<int>((ref) => 0);

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
    final modalActive = context.watch(modalActiveProvider);

    final actions = _actionsFor(section);
    final selected = actionIndex.clamp(0, actions.length - 1);

    return Focusable(
      focused: !modalActive,
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
                        if (section == _SystemSection.check) ...[
                          _CheckStatusPanel(),
                          const SizedBox(height: 1),
                        ],
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
        run: (ctx) => _runCheck(ctx, 'light'),
      ),
      _SystemAction(
        label: 'Heavy check',
        description:
            'Builds the new system closure off-disk and runs nvd '
            'diff so you can preview every package change before '
            'committing. Slow — several minutes — and CPU-heavy. '
            'Weekly timer runs this in the background.',
        run: (ctx) => _runCheck(ctx, 'heavy'),
      ),
      _SystemAction(
        label: 'Plugins check',
        description:
            'Same as Simple check but scoped to installed plugins '
            'only — useful right after pushing a plugin update '
            'when you want the ↑ marker to reflect upstream right '
            'now without waiting for the daily timer.',
        run: (ctx) => _runCheck(ctx, 'light'),
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

  /// Fire `nixblitz check <mode>` as a subprocess. Updates
  /// [_runningCheckProvider] while in flight + bumps
  /// [_checkRefreshTickProvider] on exit so the status panel
  /// re-reads update-status.json.
  static void _runCheck(BuildContext ctx, String mode) {
    if (ctx.read(_runningCheckProvider) != null) return;
    ctx.read(_runningCheckProvider.notifier).state = mode;
    LogService.info('System check started: nixblitz check $mode');

    Process.start('nixblitz', ['check', mode])
        .then((proc) async {
          // Drain stdout / stderr so they don't backpressure the
          // subprocess. The cached update-status.json is what we
          // read after — actual stdout content isn't shown inline
          // (terminal real estate is precious; the operator can tail
          // `journalctl -u nixblitz-check-heavy` if they want detail).
          proc.stdout.drain<void>();
          proc.stderr.drain<void>();
          final code = await proc.exitCode;
          LogService.info('System check exited: $mode (code $code)');
          ctx.read(_runningCheckProvider.notifier).state = null;
          ctx.read(_checkRefreshTickProvider.notifier).state++;
        })
        .catchError((Object e, StackTrace st) {
          LogService.error('System check failed to start: $mode', e, st);
          ctx.read(_runningCheckProvider.notifier).state = null;
        });
  }
}

// ---------------------------------------------------------------------------
// _CheckStatusPanel — last-check summary embedded in the Check section
// ---------------------------------------------------------------------------

class _CheckStatusPanel extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    // Trigger a rebuild after each check subprocess exits.
    context.watch(_checkRefreshTickProvider);
    final running = context.watch(_runningCheckProvider);
    final status = readUpdateStatus();
    final light = status.lightweight;
    final heavy = status.heavy;

    const dim = Color.fromRGB(140, 140, 150);
    const normal = Color.fromRGB(200, 200, 200);

    final rows = <Component>[
      const Text(
        'Last check',
        style: TextStyle(
          color: Color.fromRGB(150, 150, 180),
          fontWeight: FontWeight.bold,
        ),
      ),
    ];

    if (running != null) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        Row(
          children: [
            Spinner(
              label: running == 'heavy'
                  ? 'Running heavy check…'
                  : 'Running simple check…',
            ),
          ],
        ),
      );
    }

    rows.add(const SizedBox(height: 1));

    // flake inputs row — anything other than the TUI input pinned ahead.
    final tuiInput = 'nixblitz';
    if (light == null || !light.ok) {
      rows.add(_row('flake inputs', 'no check yet', '—', dim));
    } else {
      final ahead = light.inputsAhead.where((i) => i.name != tuiInput).toList();
      final value = ahead.isEmpty
          ? 'up to date'
          : ahead.map((i) => i.name).take(3).join(', ') +
                (ahead.length > 3 ? ' (+${ahead.length - 3} more)' : '');
      rows.add(
        _row('flake inputs', value, humanizeAge(light.checkedAt), normal),
      );
    }

    // TUI binary row — only the TUI input.
    if (light == null || !light.ok) {
      rows.add(_row('TUI binary', 'no check yet', '—', dim));
    } else {
      final tuiAhead = light.inputsAhead.any((i) => i.name == tuiInput);
      rows.add(
        _row(
          'TUI binary',
          tuiAhead ? 'ahead — pull and rebuild' : 'up to date',
          humanizeAge(light.checkedAt),
          normal,
        ),
      );
    }

    // plugins row.
    if (light == null || !light.ok) {
      rows.add(_row('plugins', 'no check yet', '—', dim));
    } else {
      final n = light.pluginsAhead.length;
      rows.add(
        _row(
          'plugins',
          n == 0 ? 'up to date' : '$n update${n == 1 ? "" : "s"} available',
          humanizeAge(light.checkedAt),
          normal,
        ),
      );
    }

    // system closure (heavy) row.
    if (heavy == null || !heavy.ok) {
      rows.add(_row('system closure', 'no full check yet', '—', dim));
    } else {
      final value = heavy.noChanges || heavy.diffText.trim().isEmpty
          ? 'no system changes'
          : 'changes pending';
      rows.add(
        _row('system closure', value, humanizeAge(heavy.checkedAt), normal),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Component _row(String label, String value, String age, Color valueColor) {
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: Text(
            '  $label',
            style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ),
        Expanded(
          child: Text(value, style: TextStyle(color: valueColor)),
        ),
        Text(
          '($age)',
          style: const TextStyle(color: Color.fromRGB(120, 120, 140)),
        ),
      ],
    );
  }
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
