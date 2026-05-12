import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

import '../format.dart';
import '../layout.dart';
import '../widgets/spinner.dart';
import '../../providers/ui_state_provider.dart';
import '../../services/check_runner.dart';
import 'update/action_gating.dart';

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
enum SystemSection { check, apply }

/// Which column has focus — same idiom as Configure.
enum SystemColumn { sidebar, content }

final systemSectionProvider = StateProvider<SystemSection>(
  (ref) => SystemSection.check,
);
final systemColumnProvider = StateProvider<SystemColumn>(
  (ref) => SystemColumn.sidebar,
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
    final section = context.watch(systemSectionProvider);
    final column = context.watch(systemColumnProvider);
    final actionIndex = context.watch(_systemActionIndexProvider);
    final modalActive = context.watch(modalActiveProvider);
    // Watch so the "View package diff" action appears as soon as a
    // Heavy check finishes (the tick bump triggers a SystemView
    // rebuild; without watching it here we'd only re-evaluate
    // hasCachedPackageDiff on the next navigation).
    context.watch(checkRefreshTickProvider);

    // Same filter the Update view + dashboard use — single source of
    // truth for "is this cached input-ahead claim still valid?".
    final baseDir = context.read(baseDirProvider);
    final status = readUpdateStatus();
    final liveInputsAhead =
        (status.lightweight != null && status.lightweight!.ok)
        ? UpdateCheckService.filterStillAhead(
            status.lightweight!.inputsAhead,
            flakePath: baseDir,
          )
        : <InputAhead>[];
    final hasCachedDiff = hasCachedPackageDiff(
      status,
      liveInputsAhead: liveInputsAhead,
    );
    final actions = _actionsFor(section, hasCachedDiff: hasCachedDiff);
    final selected = actionIndex.clamp(0, actions.length - 1);

    return Focusable(
      focused: !modalActive,
      onKeyEvent: (event) {
        try {
          // Vertical nav within the focused column.
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (column == SystemColumn.sidebar) {
              if (section == SystemSection.check) {
                context.read(systemSectionProvider.notifier).state =
                    SystemSection.apply;
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
            if (column == SystemColumn.sidebar) {
              if (section == SystemSection.apply) {
                context.read(systemSectionProvider.notifier).state =
                    SystemSection.check;
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
            if (column == SystemColumn.sidebar) {
              context.read(systemColumnProvider.notifier).state =
                  SystemColumn.content;
            } else {
              actions[selected].run(context);
            }
            return true;
          }

          // Esc: ascend (content → sidebar, sidebar → dashboard).
          if (event.logicalKey == LogicalKey.escape) {
            if (column == SystemColumn.content) {
              context.read(systemColumnProvider.notifier).state =
                  SystemColumn.sidebar;
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
                  focused: column == SystemColumn.sidebar,
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: BoxBorder.all(
                        color: column == SystemColumn.content
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
                          style: TextStyle(
                            // Bold + bright when this column owns
                            // focus; bold + dim grey otherwise, so
                            // the eye is pulled toward the sidebar
                            // when that's where j/k is going.
                            color: column == SystemColumn.content
                                ? const Color.fromRGB(200, 200, 220)
                                : const Color.fromRGB(110, 110, 130),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 1),
                        if (section == SystemSection.check) ...[
                          _CheckStatusPanel(),
                          const SizedBox(height: 1),
                        ],
                        for (var i = 0; i < actions.length; i++) ...[
                          _ActionRow(
                            action: actions[i],
                            selected: i == selected,
                            columnFocused: column == SystemColumn.content,
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

  String _headingFor(SystemSection section) => switch (section) {
    SystemSection.check => 'Check — read-only probes',
    SystemSection.apply => 'Apply — run nixos-rebuild',
  };

  List<_SystemAction> _actionsFor(
    SystemSection section, {
    bool hasCachedDiff = false,
  }) => switch (section) {
    SystemSection.check => [
      _SystemAction(
        label: 'Simple check',
        description:
            'Polls each flake input + each installed plugin against '
            'its pinned rev (HTTP only, no rebuild). Daily timer '
            'runs this in the background. ~5s.',
        run: (ctx) => runCheckSubprocess(ctx, 'light'),
      ),
      _SystemAction(
        label: 'Heavy check',
        description:
            'Builds the new system closure off-disk and runs nvd '
            'diff so you can preview every package change before '
            'committing. Slow — several minutes — and CPU-heavy. '
            'Weekly timer runs this in the background.',
        run: (ctx) => runCheckSubprocess(ctx, 'heavy'),
      ),
      if (hasCachedDiff)
        _SystemAction(
          label: 'View package diff',
          description:
              'Open the nvd output from the most recent Heavy check '
              '— full-screen, scrollable. No subprocess; reads the '
              'cached diff from update-status.json. Only appears '
              'when a non-empty cached diff exists.',
          run: (ctx) => ctx.read(currentViewProvider.notifier).state =
              AppView.packageDiff,
        ),
      _SystemAction(
        label: 'Plugins check',
        description:
            'Same as Simple check but scoped to installed plugins '
            'only — useful right after pushing a plugin update '
            'when you want the ↑ marker to reflect upstream right '
            'now without waiting for the daily timer.',
        run: (ctx) => runCheckSubprocess(ctx, 'light'),
      ),
    ],
    SystemSection.apply => [
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
// _CheckStatusPanel — last-check summary embedded in the Check section
// ---------------------------------------------------------------------------

// Palette shared across the check-status panel. Pulled out of the
// build method so the per-row helpers below can reuse it without
// taking ten parameters each.
const _labelCol = Color.fromRGB(150, 150, 180);
const _dimCol = Color.fromRGB(140, 140, 150);
const _normalCol = Color.fromRGB(200, 200, 200);
const _okCol = Color.fromRGB(110, 220, 110);
const _aheadCol = Color.fromRGB(247, 147, 26);
const _ageCol = Color.fromRGB(120, 120, 140);

class _CheckStatusPanel extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    // Trigger a rebuild after each check subprocess exits.
    context.watch(checkRefreshTickProvider);
    final running = context.watch(runningCheckProvider);
    final baseDir = context.watch(baseDirProvider);
    final status = readUpdateStatus();
    final light = status.lightweight;
    final heavy = status.heavy;
    final rootInputs = readRootFlakeInputs(baseDir);

    final lightReady = light != null && light.ok;
    final lightAge = lightReady ? humanizeAge(light.checkedAt) : '—';
    // Filter via `filterStillAhead` so cached entries whose `currentRev`
    // no longer matches the live `flake.lock` get dropped — same path
    // the Update view + dashboard use. The previous `tuiBinaryMatchesLock`
    // override was too aggressive: it hid REAL upstream-ahead claims
    // anytime the running binary happened to match the lock, including
    // the normal "you pushed a commit and haven't pulled it yet" state.
    final aheadInputs = lightReady
        ? UpdateCheckService.filterStillAhead(
            light.inputsAhead,
            flakePath: baseDir,
          ).map((i) => i.name).toSet()
        : const <String>{};

    final rows = <Component>[
      const Text(
        'Last check',
        style: TextStyle(color: _labelCol, fontWeight: FontWeight.bold),
      ),
    ];

    if (running != null) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        Spinner(
          label: running == 'heavy'
              ? 'Running heavy check…'
              : 'Running simple check…',
        ),
      );
    }

    rows.add(const SizedBox(height: 1));

    // ---------- flake inputs (header + per-input list) ----------
    rows.add(_headerRow('flake inputs:', lightAge));
    if (rootInputs.error != null) {
      rows.add(_indentedNote(rootInputs.error!));
    } else if (rootInputs.inputs.isEmpty) {
      rows.add(_indentedNote('no root inputs in flake.lock'));
    } else {
      for (final input in rootInputs.inputs) {
        final isTui = input.name == kTuiInputName;
        rows.add(
          _inputRow(
            name: input.name,
            isTui: isTui,
            isAhead: aheadInputs.contains(input.name),
            unknown: !lightReady,
          ),
        );
      }
    }

    rows.add(const SizedBox(height: 1));

    // ---------- plugins row ----------
    if (!lightReady) {
      rows.add(
        _topLevelRow('plugins', 'no check yet', '—', state: _RowState.unknown),
      );
    } else {
      final n = light.pluginsAhead.length;
      rows.add(
        _topLevelRow(
          'plugins',
          n == 0 ? 'up to date' : '$n update${n == 1 ? "" : "s"} available',
          lightAge,
          state: n == 0 ? _RowState.ok : _RowState.ahead,
        ),
      );
    }

    // ---------- system closure (heavy) row ----------
    if (heavy == null || !heavy.ok) {
      rows.add(
        _topLevelRow(
          'system closure',
          'no full check yet',
          '—',
          state: _RowState.unknown,
        ),
      );
    } else {
      final noChange = heavy.noChanges || heavy.diffText.trim().isEmpty;
      rows.add(
        _topLevelRow(
          'system closure',
          noChange ? 'no system changes' : 'changes pending',
          humanizeAge(heavy.checkedAt),
          state: noChange ? _RowState.ok : _RowState.ahead,
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// Header row: indented label, age on the right, no value column.
  /// Used for the "flake inputs:" parent above the per-input list.
  Component _headerRow(String label, String age) {
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: Text('  $label', style: const TextStyle(color: _labelCol)),
        ),
        Expanded(child: const SizedBox.shrink()),
        Text('($age)', style: const TextStyle(color: _ageCol)),
      ],
    );
  }

  /// Top-level row with status icon, label, value, age. Used for the
  /// `plugins` and `system closure` rows.
  Component _topLevelRow(
    String label,
    String value,
    String age, {
    required _RowState state,
  }) {
    final (icon, iconColor, valueColor) = switch (state) {
      _RowState.ok => ('✓ ', _okCol, _normalCol),
      _RowState.ahead => ('↑ ', _aheadCol, _aheadCol),
      _RowState.unknown => ('  ', _dimCol, _dimCol),
    };
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: Row(
            children: [
              Text(icon, style: TextStyle(color: iconColor)),
              Text(label, style: const TextStyle(color: _labelCol)),
            ],
          ),
        ),
        Expanded(
          child: Text(value, style: TextStyle(color: valueColor)),
        ),
        Text('($age)', style: const TextStyle(color: _ageCol)),
      ],
    );
  }

  /// Indented per-input row: status icon, input name (+ optional
  /// "(this TUI)" annotation), state text. No age column — the
  /// parent "flake inputs:" header carries it.
  Component _inputRow({
    required String name,
    required bool isTui,
    required bool isAhead,
    required bool unknown,
  }) {
    final state = unknown
        ? _RowState.unknown
        : (isAhead ? _RowState.ahead : _RowState.ok);
    final (icon, iconColor, valueColor) = switch (state) {
      _RowState.ok => ('✓ ', _okCol, _normalCol),
      _RowState.ahead => ('↑ ', _aheadCol, _aheadCol),
      _RowState.unknown => ('  ', _dimCol, _dimCol),
    };
    final stateText = switch (state) {
      _RowState.ok => 'up to date',
      _RowState.ahead => 'update available',
      _RowState.unknown => '—',
    };
    final displayName = isTui ? '$name (this TUI)' : name;
    return Row(
      children: [
        SizedBox(
          width: 26,
          child: Row(
            children: [
              const SizedBox(width: 4),
              Text(icon, style: TextStyle(color: iconColor)),
              Text(displayName, style: const TextStyle(color: _normalCol)),
            ],
          ),
        ),
        Expanded(
          child: Text(stateText, style: TextStyle(color: valueColor)),
        ),
      ],
    );
  }

  /// Indented error / fallback note under the "flake inputs:" header.
  Component _indentedNote(String message) {
    return Row(
      children: [
        const SizedBox(width: 4),
        Text(message, style: const TextStyle(color: _dimCol)),
      ],
    );
  }
}

enum _RowState { ok, ahead, unknown }

// ---------------------------------------------------------------------------
// _SystemSidebar — left column with Check / Apply
// ---------------------------------------------------------------------------

class _SystemSidebar extends StatelessComponent {
  final SystemSection current;
  final bool focused;

  const _SystemSidebar({required this.current, required this.focused});

  @override
  Component build(BuildContext context) {
    const accent = Color.fromRGB(247, 147, 26);
    const idle = Color.fromRGB(180, 180, 200);
    const dim = Color.fromRGB(85, 85, 105);
    const borderActive = Color.fromRGB(140, 140, 180);
    const borderIdle = Color.fromRGB(50, 50, 70);

    return Container(
      width: kSidebarWidth.toDouble(),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      decoration: BoxDecoration(
        border: BoxBorder.all(color: focused ? borderActive : borderIdle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sidebarEntry(
            'Check',
            current == SystemSection.check,
            accent,
            idle,
            dim,
          ),
          _sidebarEntry(
            'Apply',
            current == SystemSection.apply,
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
      '$prefix${truncateSidebarLabel(label)}',
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
  final bool selected;
  final bool columnFocused;

  const _ActionRow({
    required this.action,
    required this.selected,
    required this.columnFocused,
  });

  @override
  Component build(BuildContext context) {
    const accent = Color.fromRGB(247, 147, 26);
    const normal = Color.fromRGB(200, 200, 200);
    const dim = Color.fromRGB(140, 140, 150);
    const inactive = Color.fromRGB(85, 85, 105);

    // Cursor + accent only when this column owns focus. Otherwise the
    // whole pane drops to the same dim grey the sidebar uses for its
    // idle state — no `>`, no bold — so it's visually clear that
    // j/k is going somewhere else.
    final showCursor = selected && columnFocused;
    final labelColor = columnFocused ? (selected ? accent : normal) : inactive;
    final descColor = columnFocused ? dim : inactive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${showCursor ? "> " : "  "}${action.label}',
          style: TextStyle(
            color: labelColor,
            fontWeight: showCursor ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text('    ${action.description}', style: TextStyle(color: descColor)),
      ],
    );
  }
}
