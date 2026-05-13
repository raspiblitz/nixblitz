import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

import '../format.dart';
import '../layout.dart';
import '../widgets/spinner.dart';
import '../widgets/tappable.dart';
import '../../providers/ui_state_provider.dart';
import '../../providers/viewport_provider.dart';
import '../../services/check_runner.dart';
import 'update/action_gating.dart';
import 'update_view.dart' show pendingUpdateIntentProvider, UpdateActionIntent;

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
enum SystemSection { check, apply, power }

/// Which column has focus — same idiom as Configure.
enum SystemColumn { sidebar, content }

final systemSectionProvider = StateProvider<SystemSection>(
  (ref) => SystemSection.check,
);
final systemColumnProvider = StateProvider<SystemColumn>(
  (ref) => SystemColumn.sidebar,
);
final _systemActionIndexProvider = StateProvider<int>((ref) => 0);

/// Label of the Power-section action currently in "press Enter
/// again to confirm" mode. `null` when nothing is armed. Cleared
/// by Esc, by switching section, or by changing selection.
final _armedPowerActionProvider = StateProvider<String?>((ref) => null);

/// Latched status string for Power actions ('Authorizing…' /
/// 'Rebooting…' / 'Cancelled.'). Null while idle. Drives the
/// inline status line rendered under the Power actions.
final _powerStatusProvider = StateProvider<String?>((ref) => null);

/// A row in the body's action list. Each action has a short, action-y
/// label + a longer description rendered below it in dim text.
/// [danger] re-tints the row red — used for armed Power actions
/// ("press Enter again to power off").
class _SystemAction {
  const _SystemAction({
    required this.label,
    required this.description,
    required this.run,
    this.danger = false,
  });
  final String label;
  final String description;
  final bool danger;
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
    final hasCachedWouldBuild = status.heavy?.compileNeeded ?? false;
    final armedPower = context.watch(_armedPowerActionProvider);
    final powerStatus = context.watch(_powerStatusProvider);
    final actions = _actionsFor(
      section,
      hasCachedDiff: hasCachedDiff,
      hasCachedWouldBuild: hasCachedWouldBuild,
      armedPower: armedPower,
    );
    final selected = actionIndex.clamp(0, actions.length - 1);

    return Focusable(
      focused: !modalActive,
      onKeyEvent: (event) {
        try {
          // Vertical nav within the focused column.
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (column == SystemColumn.sidebar) {
              final next = switch (section) {
                SystemSection.check => SystemSection.apply,
                SystemSection.apply => SystemSection.power,
                SystemSection.power => null,
              };
              if (next != null) {
                context.read(systemSectionProvider.notifier).state = next;
                context.read(_systemActionIndexProvider.notifier).state = 0;
                _disarmPower(context);
              }
            } else {
              if (selected < actions.length - 1) {
                context.read(_systemActionIndexProvider.notifier).state =
                    selected + 1;
                _disarmPower(context);
              }
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (column == SystemColumn.sidebar) {
              final prev = switch (section) {
                SystemSection.power => SystemSection.apply,
                SystemSection.apply => SystemSection.check,
                SystemSection.check => null,
              };
              if (prev != null) {
                context.read(systemSectionProvider.notifier).state = prev;
                context.read(_systemActionIndexProvider.notifier).state = 0;
                _disarmPower(context);
              }
            } else {
              if (selected > 0) {
                context.read(_systemActionIndexProvider.notifier).state =
                    selected - 1;
                _disarmPower(context);
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

          // `v` jumps straight to the cached package viewer from
          // anywhere in the Check section. Matches the existing [v]
          // shortcut in the Update view's selectMode so muscle memory
          // carries across — operators don't have to remember which
          // pane they're on. Gated on something actually being
          // viewable so a stray `v` on a fresh install doesn't open
          // an empty pane.
          if (event.logicalKey == LogicalKey.keyV &&
              section == SystemSection.check &&
              (hasCachedDiff || hasCachedWouldBuild)) {
            context.read(currentViewProvider.notifier).state =
                AppView.packageDiff;
            return true;
          }

          // Esc: ascend (content → sidebar, sidebar → dashboard).
          // Always disarms any armed Power action — escaping is a
          // clear "I changed my mind" signal.
          if (event.logicalKey == LogicalKey.escape) {
            _disarmPower(context);
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
            child: _buildBody(
              context: context,
              compact:
                  context.watch(viewportClassProvider) == ViewportClass.compact,
              section: section,
              column: column,
              actions: actions,
              selected: selected,
              powerStatus: powerStatus,
            ),
          ),
        ],
      ),
    );
  }

  Component _buildBody({
    required BuildContext context,
    required bool compact,
    required SystemSection section,
    required SystemColumn column,
    required List<_SystemAction> actions,
    required int selected,
    required String? powerStatus,
  }) {
    final sidebar = _SystemSidebar(
      current: section,
      focused: column == SystemColumn.sidebar,
    );
    final content = _SystemContentPane(
      section: section,
      column: column,
      actions: actions,
      selected: selected,
      powerStatus: powerStatus,
      headingFor: _headingFor,
    );

    if (!compact) {
      // `stretch` so both bordered panes (sidebar + content) fill
      // the available row height regardless of how much content
      // they currently render. Without this the content's outer
      // Container shrinks to fit its body — fine when the action
      // list overflows, ugly when it fits in half the pane and
      // the border ends mid-screen.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          sidebar,
          Expanded(child: content),
        ],
      );
    }

    // Compact / phone-over-SSH: one pane at a time. Sidebar fills
    // the screen when focused; content fills + grows a back header
    // when drilled in. Esc / tap-back returns to sidebar.
    if (column == SystemColumn.sidebar) {
      return SizedBox.expand(child: sidebar);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CompactSystemBackHeader(section: section),
        Expanded(child: content),
      ],
    );
  }

  String _headingFor(SystemSection section) => switch (section) {
    SystemSection.check => 'Check — read-only probes',
    SystemSection.apply => 'Apply — run nixos-rebuild',
    SystemSection.power => 'Power — shutdown / reboot',
  };

  List<_SystemAction> _actionsFor(
    SystemSection section, {
    bool hasCachedDiff = false,
    bool hasCachedWouldBuild = false,
    String? armedPower,
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
            'Probes the new system closure off-disk via '
            '`nix build --dry-run` and runs nvd diff when every '
            'path is substitutable. Bails before realising the '
            'toplevel if any path would need a local compile so '
            'the Pi 5 doesn\'t pin all 4 cores for hours; the '
            'would-build list is reachable via "View packages to '
            'compile" below. Weekly timer runs this in the '
            'background.',
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
      if (hasCachedWouldBuild)
        _SystemAction(
          label: 'View packages to compile',
          description:
              'Open the would-build list from the most recent Heavy '
              'check — derivations that need a local compile because '
              'no binary-cache substitute is available. Full-screen, '
              'scrollable. Only appears when the cached check '
              'reports compile-needed.',
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
        label: 'Apply config edits',
        description:
            'Runs nixos-rebuild switch against the current '
            'config.json so unsaved edits in Configure flip from '
            '"pending" to "applied" on the running system. The '
            'flake.lock is left as-is — for upstream commits, '
            'pick "Update TUI only" or "Update entire system" '
            'below.',
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
          ctx.read(pendingUpdateIntentProvider.notifier).state =
              UpdateActionIntent.tuiOnly;
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
          ctx.read(pendingUpdateIntentProvider.notifier).state =
              UpdateActionIntent.entireSystem;
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
      _SystemAction(
        label: 'Update plugins',
        description:
            'For every installed plugin whose upstream is ahead '
            'of its pinned rev, pull the new rev + rebuild. Same '
            'shape as Update TUI only — one click, sudo, '
            'streamed rebuild output, done.',
        run: (ctx) {
          ctx.read(pendingUpdateIntentProvider.notifier).state =
              UpdateActionIntent.updatePlugins;
          ctx.read(currentViewProvider.notifier).state = AppView.update;
        },
      ),
    ],
    SystemSection.power => [
      _SystemAction(
        label: 'Shutdown',
        description: armedPower == 'shutdown'
            ? 'Press Enter again to power off. Esc to cancel.'
            : 'Power the node off via `systemctl poweroff`. You '
                  'will need to power it back on manually.',
        danger: armedPower == 'shutdown',
        run: (ctx) {
          if (ctx.read(_armedPowerActionProvider) == 'shutdown') {
            _executePower(ctx, 'poweroff', 'Shutting down');
          } else {
            ctx.read(_armedPowerActionProvider.notifier).state = 'shutdown';
          }
        },
      ),
      _SystemAction(
        label: 'Reboot',
        description: armedPower == 'reboot'
            ? 'Press Enter again to reboot. Esc to cancel.'
            : 'Reboot the node via `systemctl reboot`. The TUI '
                  'will exit; reconnect once the node is back.',
        danger: armedPower == 'reboot',
        run: (ctx) {
          if (ctx.read(_armedPowerActionProvider) == 'reboot') {
            _executePower(ctx, 'reboot', 'Rebooting');
          } else {
            ctx.read(_armedPowerActionProvider.notifier).state = 'reboot';
          }
        },
      ),
    ],
  };

  /// Clear any armed Power action + reset the status line. Called on
  /// Esc, on navigation, on row change — anything that suggests the
  /// operator's no longer about to confirm.
  static void _disarmPower(BuildContext ctx) {
    if (ctx.read(_armedPowerActionProvider) != null) {
      ctx.read(_armedPowerActionProvider.notifier).state = null;
    }
    if (ctx.read(_powerStatusProvider) != null) {
      ctx.read(_powerStatusProvider.notifier).state = null;
    }
  }

  /// Force a fresh sudo prompt (regardless of cached timestamp),
  /// then dispatch `systemctl <verb>`. The cached timestamp is
  /// always invalidated first so power actions don't ride a recent
  /// Apply's auth — shutting down the box is exactly the kind of
  /// thing where a re-typed password is the right friction.
  ///
  /// Best-effort: the system goes down before the runOneShot
  /// resolves, so nothing depends on its result.
  static void _executePower(BuildContext ctx, String verb, String label) {
    final sudo = ctx.read(sudoSessionProvider);
    ctx.read(_powerStatusProvider.notifier).state = 'Authorizing…';
    sudo
        .forget()
        .then((_) => sudo.ensureFresh())
        .then((ok) {
          if (!ok) {
            ctx.read(_armedPowerActionProvider.notifier).state = null;
            ctx.read(_powerStatusProvider.notifier).state = 'Cancelled.';
            return;
          }
          ctx.read(_powerStatusProvider.notifier).state = '$label…';
          // Fire and forget — the system is going down; the
          // subprocess's resolution doesn't matter to the TUI.
          sudo.runOneShot(['systemctl', verb]).catchError((
            Object e,
            StackTrace st,
          ) {
            LogService.error('systemctl $verb failed', e, st);
            return (exitCode: 1, stdout: '', stderr: '$e');
          });
        })
        .catchError((Object e, StackTrace st) {
          LogService.error('Power action authorization failed: $verb', e, st);
          ctx.read(_armedPowerActionProvider.notifier).state = null;
          ctx.read(_powerStatusProvider.notifier).state = 'Failed: $e';
        });
  }
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
    } else if (heavy.compileNeeded) {
      // Single-line summary in the value cell, plus an indented
      // pointer at the action below — the full would-build list
      // is reachable via "View packages to compile" but that
      // wasn't obvious from the status panel alone (operators
      // saw the count and didn't connect it to the trailing
      // action). Inlining all the names here pushed "Plugins
      // check" off the bottom of the pane on a Pi-sized terminal,
      // so the drill-in action stays the primary surface; this
      // is just signage.
      final n = heavy.wouldBuild.length;
      rows.add(
        _topLevelRow(
          'system closure',
          n == 1 ? '1 needs compile' : '$n need compile',
          humanizeAge(heavy.checkedAt),
          state: _RowState.ahead,
        ),
      );
      rows.add(_indentedNote('see "View packages to compile" below'));
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
// _CompactSystemBackHeader — single-pane content header in compact mode
//
// Shown above the section content when sidebar+content collapses to
// a single pane. The `◀ <Section>` label tells the operator they're
// inside a sub-section and Esc / tap-back returns to the sidebar.
// Pure visual today; Tappable wiring lands in a follow-up.
// ---------------------------------------------------------------------------

class _CompactSystemBackHeader extends StatelessComponent {
  final SystemSection section;
  const _CompactSystemBackHeader({required this.section});

  @override
  Component build(BuildContext context) {
    final label = switch (section) {
      SystemSection.check => 'Check',
      SystemSection.apply => 'Apply',
      SystemSection.power => 'Power',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      decoration: const BoxDecoration(
        border: BoxBorder(bottom: BorderSide(color: Color.fromRGB(50, 50, 70))),
      ),
      child: Tappable(
        // Tap = back to the section sidebar. Same as Esc.
        onTap: () => context.read(systemColumnProvider.notifier).state =
            SystemColumn.sidebar,
        child: Text(
          '◀ $label',
          style: const TextStyle(
            color: Color.fromRGB(180, 180, 200),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SystemContentPane — scrollable right column with heading + actions
//
// Stateful so it can own a [ScrollController] and call `ensureVisible`
// whenever the selected action changes (keyboard j/k or tap). Without
// auto-scroll, on a compact viewport the operator's selection drifts
// off-screen below the actions they pulled up to navigate.
//
// Row-height estimate: compact mode collapses every action to a 1-row
// label + a 1-row blank separator. We pre-compute the header offset
// (heading + status panel) per section so `ensureVisible` is roughly
// accurate. The estimate over-budgets the status panel a bit so the
// selected row lands slightly inside the viewport rather than at the
// edge.
// ---------------------------------------------------------------------------

class _SystemContentPane extends StatefulComponent {
  final SystemSection section;
  final SystemColumn column;
  final List<_SystemAction> actions;
  final int selected;
  final String? powerStatus;
  final String Function(SystemSection) headingFor;

  const _SystemContentPane({
    required this.section,
    required this.column,
    required this.actions,
    required this.selected,
    required this.powerStatus,
    required this.headingFor,
  });

  @override
  State<_SystemContentPane> createState() => _SystemContentPaneState();
}

class _SystemContentPaneState extends State<_SystemContentPane> {
  final ScrollController _scroll = ScrollController();
  int? _lastSelected;

  // Rough header-row budget per section. Counts heading (1) + blank
  // (1) + the Check section's status panel (~10 rows on 40-col due
  // to wrapping — slightly over-estimated to push the selected row
  // a bit inside the viewport rather than at the very top).
  int _headerOffset() => switch (component.section) {
    SystemSection.check => 12,
    SystemSection.apply => 2,
    SystemSection.power => 2,
  };

  // Per-action vertical budget. Unselected actions render only the
  // label (1 row) + a spacer (1 row) — 2 rows. The currently-
  // selected action expands to label + ~3 wrapped description rows
  // + spacer, ~5 rows; the description's true height depends on
  // pane width so we over-estimate by aiming the scroll target at
  // the *bottom* of the expanded block. This keeps the description
  // visible after a `j` step instead of clipping it off the
  // viewport's bottom edge.
  static const int _rowsPerAction = 2;
  static const int _selectedExpansion = 4;

  void _maybeScrollToSelected() {
    if (_lastSelected == component.selected) return;
    _lastSelected = component.selected;
    final base = _headerOffset() + component.selected * _rowsPerAction;
    final offset = base + _selectedExpansion;
    // Microtask defer so the scroll happens AFTER the new content
    // layout has settled — otherwise viewportDimension may still
    // reflect the previous frame.
    Future.microtask(() {
      if (!mounted) return;
      _scroll.ensureVisible(itemOffset: offset.toDouble(), itemExtent: 1);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    _maybeScrollToSelected();

    final section = component.section;
    final column = component.column;
    final actions = component.actions;
    final selected = component.selected;
    final powerStatus = component.powerStatus;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          component.headingFor(section),
          style: TextStyle(
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
          Tappable(
            onTap: () {
              context.read(_systemActionIndexProvider.notifier).state = i;
              context.read(systemColumnProvider.notifier).state =
                  SystemColumn.content;
              actions[i].run(context);
            },
            child: _ActionRow(
              action: actions[i],
              selected: i == selected,
              columnFocused: column == SystemColumn.content,
            ),
          ),
          if (i < actions.length - 1) const SizedBox(height: 1),
        ],
        if (section == SystemSection.power && powerStatus != null) ...[
          const SizedBox(height: 1),
          Text(
            powerStatus,
            style: const TextStyle(
              color: Color.fromRGB(220, 180, 100),
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ],
    );

    return Container(
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: column == SystemColumn.content
              ? const Color.fromRGB(140, 140, 180)
              : const Color.fromRGB(50, 50, 70),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: MouseRegion(
        // Mouse-wheel + two-finger scroll over the content. Wheel
        // events fire onHover with button == wheelUp / wheelDown,
        // not motion — same trick ScrollableLog uses.
        onHover: (event) {
          if (event.button == MouseButton.wheelUp) {
            _scroll.scrollUp();
          } else if (event.button == MouseButton.wheelDown) {
            _scroll.scrollDown();
          }
        },
        child: SingleChildScrollView(controller: _scroll, child: body),
      ),
    );
  }
}

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
            context,
            SystemSection.check,
            'Check',
            accent,
            idle,
            dim,
          ),
          _sidebarEntry(
            context,
            SystemSection.apply,
            'Apply',
            accent,
            idle,
            dim,
          ),
          _sidebarEntry(
            context,
            SystemSection.power,
            'Power',
            accent,
            idle,
            dim,
          ),
        ],
      ),
    );
  }

  Component _sidebarEntry(
    BuildContext context,
    SystemSection section,
    String label,
    Color accent,
    Color idle,
    Color dim,
  ) {
    // The `>` cursor stays on the active entry even when the column
    // isn't focused — the operator needs to know which section
    // they're in while working in the content pane. Color gradient:
    //   focused active   → accent + bold
    //   focused inactive → idle
    //   unfocused active → idle (no bold)
    //   unfocused inactive → dim
    final isActive = current == section;
    final prefix = isActive ? '> ' : '  ';
    final color = focused
        ? (isActive ? accent : idle)
        : (isActive ? idle : dim);
    return Tappable(
      // Tap selects the section AND focuses the content pane —
      // same as Enter on the keyboard. iOS Settings paradigm.
      onTap: () {
        context.read(systemSectionProvider.notifier).state = section;
        context.read(_systemActionIndexProvider.notifier).state = 0;
        context.read(systemColumnProvider.notifier).state =
            SystemColumn.content;
      },
      child: Text(
        '$prefix${truncateSidebarLabel(label)}',
        style: TextStyle(
          color: color,
          fontWeight: isActive && focused ? FontWeight.bold : FontWeight.normal,
        ),
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
    const danger = Color.fromRGB(255, 80, 80);
    const dangerDim = Color.fromRGB(220, 120, 120);

    // Cursor + accent only when this column owns focus. Otherwise the
    // whole pane drops to the same dim grey the sidebar uses for its
    // idle state — no `>`, no bold — so it's visually clear that
    // j/k is going somewhere else. Armed-Power rows override colour
    // to red so the "press Enter again" warning stands out.
    final showCursor = selected && columnFocused;
    final Color labelColor;
    final Color descColor;
    if (action.danger) {
      labelColor = columnFocused ? danger : dangerDim;
      descColor = columnFocused ? danger : dangerDim;
    } else {
      labelColor = columnFocused ? (selected ? accent : normal) : inactive;
      descColor = columnFocused ? dim : inactive;
    }

    // iOS-Settings-style disclosure: only the focused action shows
    // its description inline. Unselected actions collapse to a
    // single label row so a long action list (System → Check has
    // up to 5 rows when both View affordances appear) doesn't
    // push the trailing entries below the fold on a Pi-sized
    // terminal. Danger rows always show the description —
    // "Press Enter again to power off" is a state warning, not
    // a help blurb, and must stay visible regardless of focus.
    //
    // Auto-scroll keeps the selected row + its expanded
    // description on-screen as the operator moves; see
    // `_SystemContentPaneState._maybeScrollToSelected`.
    final showDescription = action.danger || (selected && columnFocused);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${showCursor ? "> " : "  "}${action.label}',
          style: TextStyle(
            color: labelColor,
            fontWeight: showCursor || action.danger
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
        if (showDescription)
          Text('    ${action.description}', style: TextStyle(color: descColor)),
      ],
    );
  }
}
