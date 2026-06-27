# Simplify the Updates Screen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-present the System update screen as two operator-facing rows (NixBlitz, Plugins) + a plain-language "when you apply" note, with the per-input/package detail behind one "What's changing…" drill-down.

**Architecture:** A pure `CheckResult → UpdatesDisplay` mapper in `common` holds the branching (rollup, note text, gating) and is unit-tested. `_CheckStatusPanel` (the Check body) and the Check actions are rewritten to render the mapper's output; the sidebar/heading rename `Check → Updates`; the existing `CachedPackageDiff` viewer gains an "Updated software" section so it serves as the consolidated details view. No model / check-service / Apply changes.

**Tech Stack:** Dart (`common` + `tui`), nocterm.

## Global Constraints

- **Single repo** (`/home/f44/dev/blitz/nixblitz`). All tasks main-repo.
- **Commits are the user's.** Do NOT run `jj`/`git commit`. Each task ends by running the verification gate and presenting a ready-to-paste commit message (subject + why-focused body + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`).
- **Verification gate:** after each task run `just test`, `just analyze`, `just format` (in that order); all green. Pre-existing `implementation_imports` infos in `tile_renderer.dart`/`dashboard_view.dart` are not yours unless your change adds new ones.
- **Presentation-only:** do NOT change `UpdateCheckService`, `CheckResult`/`InputAhead`/`PluginAhead`, staging, the daily check, or the Apply flow. This re-presents existing data.
- **nocterm:** view code only renders; no provider sets inside the affected `build()` paths beyond what already exists. Wrap any new key handlers in try/catch.
- **Exact note strings** (copy verbatim):
  - compile: `Applying builds N package(s) on the node first — can be slow on a Pi.`
  - fast: `Applying downloads prebuilt packages (no local build).`
  - re-pin: `Inputs moved but the built system is unchanged — applying re-pins, nothing rebuilds.`

---

### Task 1: `UpdatesDisplay` mapper (`common`)

**Files:**

- Create: `common/lib/src/models/updates_display.dart`
- Modify: `common/lib/common.dart` (add export)
- Test: `common/test/models/updates_display_test.dart`

**Interfaces:**

- Consumes: `CheckResult` (`ok`, `error`, `inputsAhead`, `pluginsAhead`, `diffText`, `noChanges`, `wouldBuild`, `compileNeeded`) from `update_status.dart`.
- Produces:
  - `enum UpdateRowStatus { upToDate, updateAvailable, notChecked }`
  - `class UpdatesDisplay { UpdateRowStatus nixblitz; UpdateRowStatus plugins; int pluginsAheadCount; String? applyNote; bool detailsAvailable; String? error; }`
  - `UpdatesDisplay mapUpdatesDisplay({required CheckResult? result, required int aheadInputCount})` — `aheadInputCount` is the count of flake inputs still ahead AFTER `filterStillAhead` (the view computes it; keeps this function pure/IO-free).

- [ ] **Step 1: Write the failing tests**

Create `common/test/models/updates_display_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:common/src/models/update_status.dart';
import 'package:common/src/models/updates_display.dart';

CheckResult _result({
  bool ok = true,
  String? error,
  List<PluginAhead> plugins = const [],
  String diffText = '',
  bool noChanges = false,
  List<String> wouldBuild = const [],
}) => CheckResult(
  checkedAt: DateTime(2026, 1, 1),
  ok: ok,
  error: error,
  inputsAhead: const [],
  pluginsAhead: plugins,
  diffText: diffText,
  noChanges: noChanges,
  wouldBuild: wouldBuild,
);

PluginAhead _plugin(String id) => PluginAhead(
  pluginId: id,
  currentRev: 'a' * 40,
  upstreamRev: 'b' * 40,
  url: 'forgejo:x/$id',
);

void main() {
  group('mapUpdatesDisplay', () {
    test('null result → not checked, no note, no details', () {
      final d = mapUpdatesDisplay(result: null, aheadInputCount: 0);
      expect(d.nixblitz, UpdateRowStatus.notChecked);
      expect(d.plugins, UpdateRowStatus.notChecked);
      expect(d.applyNote, isNull);
      expect(d.detailsAvailable, isFalse);
      expect(d.error, isNull);
    });

    test('failed probe surfaces the error', () {
      final d = mapUpdatesDisplay(
        result: _result(ok: false, error: 'network down'),
        aheadInputCount: 0,
      );
      expect(d.error, 'network down');
      expect(d.nixblitz, UpdateRowStatus.notChecked);
    });

    test('all up to date → both ✓, no note, no details', () {
      final d = mapUpdatesDisplay(
        result: _result(noChanges: true),
        aheadInputCount: 0,
      );
      expect(d.nixblitz, UpdateRowStatus.upToDate);
      expect(d.plugins, UpdateRowStatus.upToDate);
      expect(d.applyNote, isNull);
      expect(d.detailsAvailable, isFalse);
    });

    test('an input ahead → NixBlitz update available + details', () {
      final d = mapUpdatesDisplay(
        result: _result(noChanges: false, diffText: '[U] x 1 -> 2'),
        aheadInputCount: 1,
      );
      expect(d.nixblitz, UpdateRowStatus.updateAvailable);
      expect(d.detailsAvailable, isTrue);
      expect(d.applyNote, 'Applying downloads prebuilt packages (no local build).');
    });

    test('plugins ahead → count + pluralization', () {
      final d = mapUpdatesDisplay(
        result: _result(plugins: [_plugin('a'), _plugin('b')]),
        aheadInputCount: 0,
      );
      expect(d.plugins, UpdateRowStatus.updateAvailable);
      expect(d.pluginsAheadCount, 2);
      expect(d.detailsAvailable, isTrue);
    });

    test('compile needed → build warning with N', () {
      final d = mapUpdatesDisplay(
        result: _result(wouldBuild: ['rustc', 'llvm', 'gcc']),
        aheadInputCount: 1,
      );
      expect(d.applyNote, 'Applying builds 3 packages on the node first — can be slow on a Pi.');
      expect(d.detailsAvailable, isTrue);
    });

    test('compile needed singular', () {
      final d = mapUpdatesDisplay(
        result: _result(wouldBuild: ['rustc']),
        aheadInputCount: 1,
      );
      expect(d.applyNote, 'Applying builds 1 package on the node first — can be slow on a Pi.');
    });

    test('rev moved but system unchanged → re-pin note', () {
      final d = mapUpdatesDisplay(
        result: _result(noChanges: true),
        aheadInputCount: 1,
      );
      expect(d.nixblitz, UpdateRowStatus.updateAvailable);
      expect(d.applyNote, 'Inputs moved but the built system is unchanged — applying re-pins, nothing rebuilds.');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/models/updates_display_test.dart`
Expected: FAIL — `updates_display.dart` / `mapUpdatesDisplay` undefined.

- [ ] **Step 3: Implement the mapper**

Create `common/lib/src/models/updates_display.dart`:

```dart
import 'package:common/src/models/update_status.dart';

/// Per-row status on the simplified Updates screen.
enum UpdateRowStatus { upToDate, updateAvailable, notChecked }

/// View-model for the Updates panel, derived from a [CheckResult]. Pure:
/// the mapper takes the already-filtered ahead-input count so it does no
/// IO and stays unit-testable. See
/// docs/superpowers/specs/2026-06-28-updates-screen-simplify-design.md.
class UpdatesDisplay {
  /// "NixBlitz" = all non-plugin flake inputs rolled up. updateAvailable
  /// when any input is still ahead.
  final UpdateRowStatus nixblitz;

  /// "Plugins" = the auto-update plugin probe.
  final UpdateRowStatus plugins;

  /// Count behind the Plugins row ("N updates available").
  final int pluginsAheadCount;

  /// Plain-language note about the net effect of applying, or null when
  /// there is nothing to say (everything up to date).
  final String? applyNote;

  /// Whether the "What's changing…" drill-down has anything to show.
  final bool detailsAvailable;

  /// Plain-language probe error, or null when the last check was ok / absent.
  final String? error;

  const UpdatesDisplay({
    required this.nixblitz,
    required this.plugins,
    required this.pluginsAheadCount,
    required this.applyNote,
    required this.detailsAvailable,
    required this.error,
  });
}

/// Map a [CheckResult] (+ the count of inputs still ahead after
/// `filterStillAhead`) to the Updates panel view-model.
UpdatesDisplay mapUpdatesDisplay({
  required CheckResult? result,
  required int aheadInputCount,
}) {
  if (result == null) {
    return const UpdatesDisplay(
      nixblitz: UpdateRowStatus.notChecked,
      plugins: UpdateRowStatus.notChecked,
      pluginsAheadCount: 0,
      applyNote: null,
      detailsAvailable: false,
      error: null,
    );
  }
  if (!result.ok) {
    return UpdatesDisplay(
      nixblitz: UpdateRowStatus.notChecked,
      plugins: UpdateRowStatus.notChecked,
      pluginsAheadCount: 0,
      applyNote: null,
      detailsAvailable: false,
      error: result.error ?? "Couldn't check for updates",
    );
  }

  final pluginsCount = result.pluginsAhead.length;
  final nixblitzAhead = aheadInputCount > 0;
  final pluginsAhead = pluginsCount > 0;
  final hasDiff = result.diffText.trim().isNotEmpty;

  final String? note;
  if (result.compileNeeded) {
    final n = result.wouldBuild.length;
    note =
        'Applying builds $n package${n == 1 ? '' : 's'} on the node first '
        '— can be slow on a Pi.';
  } else if (!result.noChanges && hasDiff) {
    note = 'Applying downloads prebuilt packages (no local build).';
  } else if (nixblitzAhead || pluginsAhead) {
    note =
        'Inputs moved but the built system is unchanged — applying re-pins, '
        'nothing rebuilds.';
  } else {
    note = null;
  }

  return UpdatesDisplay(
    nixblitz: nixblitzAhead
        ? UpdateRowStatus.updateAvailable
        : UpdateRowStatus.upToDate,
    plugins: pluginsAhead
        ? UpdateRowStatus.updateAvailable
        : UpdateRowStatus.upToDate,
    pluginsAheadCount: pluginsCount,
    applyNote: note,
    detailsAvailable:
        nixblitzAhead || pluginsAhead || result.wouldBuild.isNotEmpty || hasDiff,
    error: null,
  );
}
```

- [ ] **Step 4: Export from the barrel**

In `common/lib/common.dart`, next to the `update_status.dart` export:

```dart
export 'src/models/updates_display.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd common && dart test test/models/updates_display_test.dart`
Expected: PASS (all).

- [ ] **Step 6: Verification gate + commit message**

Run: `just test && just analyze && just format`. Suggested subject:
`feat(updates): CheckResult→display mapper for the simplified screen`

---

### Task 2: Rewrite the Updates panel + actions + rename (`tui`)

**Files:**

- Modify: `tui/lib/src/ui/views/system_view.dart`

**Interfaces:**

- Consumes: `mapUpdatesDisplay`, `UpdatesDisplay`, `UpdateRowStatus` (via `package:common/common.dart`, already imported); existing `readUpdateStatus()`, `UpdateCheckService.filterStillAhead`, `readRootFlakeInputs`, `_topLevelRow`, `_RowState`, the palette, `runCheckSubprocess`, `AppView.packageDiff`.

No automated test (nocterm UI); covered by Task 1 + manual.

- [ ] **Step 1: Rewrite `_CheckStatusPanel.build`**

Replace the whole `build` method body of `_CheckStatusPanel` (currently lines ~447–562, from `@override Component build` down to the `return Column(...)`) with:

```dart
  @override
  Component build(BuildContext context) {
    // Trigger a rebuild after each check subprocess exits.
    context.watch(checkRefreshTickProvider);
    final running = context.watch(runningCheckProvider);
    final baseDir = context.watch(baseDirProvider);
    final status = readUpdateStatus();
    final result = status.checkResult;

    final ready = result != null && result.ok;
    final age = ready ? humanizeAge(result.checkedAt) : '—';
    // Inputs still ahead after dropping cached entries whose currentRev no
    // longer matches the live flake.lock — same path the dashboard uses.
    final aheadInputCount = ready
        ? UpdateCheckService.filterStillAhead(
            result.inputsAhead,
            flakePath: baseDir,
          ).length
        : 0;

    final display = mapUpdatesDisplay(
      result: result,
      aheadInputCount: aheadInputCount,
    );

    final rows = <Component>[
      Row(
        children: [
          const Text(
            'Last check',
            style: TextStyle(color: _labelCol, fontWeight: FontWeight.bold),
          ),
          Expanded(child: const SizedBox.shrink()),
          Text('checked $age', style: const TextStyle(color: _ageCol)),
        ],
      ),
    ];

    if (running) {
      rows.add(const SizedBox(height: 1));
      rows.add(const Spinner(label: 'Running check…'));
    }

    if (display.error != null) {
      rows.add(const SizedBox(height: 1));
      rows.add(_indentedNote("Couldn't check for updates — ${display.error}"));
    }

    rows.add(const SizedBox(height: 1));
    rows.add(_statusRow('NixBlitz', display.nixblitz, count: null));
    rows.add(
      _statusRow('Plugins', display.plugins, count: display.pluginsAheadCount),
    );

    if (display.applyNote != null) {
      rows.add(const SizedBox(height: 1));
      rows.add(_indentedNote(display.applyNote!));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// Status row mapping a [UpdateRowStatus] to the shared `_topLevelRow`.
  /// [count] (>1) appends "N updates available" for the Plugins row.
  Component _statusRow(String label, UpdateRowStatus s, {int? count}) {
    final (value, state) = switch (s) {
      UpdateRowStatus.upToDate => ('up to date', _RowState.ok),
      UpdateRowStatus.updateAvailable => (
        (count != null && count > 0)
            ? '$count update${count == 1 ? '' : 's'} available'
            : 'update available',
        _RowState.ahead,
      ),
      UpdateRowStatus.notChecked => ('not checked yet', _RowState.unknown),
    };
    return _topLevelRow(label, value, '', state: state);
  }
```

Then **drop the now-unused helpers** `_headerRow`, `_inputRow`, and `_followsRow` from `_CheckStatusPanel` (the new panel doesn't render per-input rows). Keep `_topLevelRow`, `_indentedNote`, `_RowState`, and the palette.

Note: `_topLevelRow` renders a trailing `($age)`. Passing `''` yields `()`. To avoid that, change `_topLevelRow` to omit the age widget when the age arg is empty:

```dart
        Expanded(
          child: Text(value, style: TextStyle(color: valueColor)),
        ),
        if (age.isNotEmpty)
          Text('($age)', style: const TextStyle(color: _ageCol)),
```

(Apply this one-line guard inside `_topLevelRow`.)

- [ ] **Step 2: Replace the Check actions with a single gated "What's changing…"**

In `_actionsFor`, the `SystemSection.check` arm currently has `Check for updates` + two conditional view actions (`View package diff` when `hasCachedDiff`, `View packages to compile` when `hasCachedWouldBuild`). Replace the two conditional actions with one:

```dart
    SystemSection.check => [
      _SystemAction(
        label: 'Check for updates',
        description:
            'Probe NixBlitz + each installed plugin for new versions, then '
            'preview the new system off-disk. Bails before building if any '
            'package would need a local compile (so a Pi 5 is not pinned for '
            'hours). Stages anything found for the next Apply. Runs daily in '
            'the background; 1-10 min.',
        run: (ctx) => runCheckSubprocess(ctx),
      ),
      if (hasCachedDiff || hasCachedWouldBuild)
        _SystemAction(
          label: "What's changing…",
          description:
              'Show the details from the most recent check — which software '
              'moved, any packages that build on the node, and the per-'
              'package diff. Read-only.',
          run: (ctx) =>
              ctx.read(currentViewProvider.notifier).state = AppView.packageDiff,
        ),
    ],
```

(`hasCachedDiff`/`hasCachedWouldBuild` are already passed into `_actionsFor`; their OR is the `detailsAvailable` gate for this screen.)

- [ ] **Step 3: Rename Check → Updates (heading + sidebar)**

Three string edits:

1. `_headingFor`: `SystemSection.check => 'Check — read-only probes',` → `SystemSection.check => 'Updates',`
2. The label switch (~line 708): `SystemSection.check => 'Check',` → `SystemSection.check => 'Updates',`
3. `_SystemSidebar` (~line 927): the literal `'Check'` sidebar entry → `'Updates'`.

(Leave the `[c]` hotkey and `SystemSection.check` enum value as-is — only display strings change.)

- [ ] **Step 4: Analyze + format + test**

Run: `just analyze` (no NEW issues in system_view.dart) ; `just format` ; `just test` (all pass — no regressions; the panel logic is covered by Task 1).

- [ ] **Step 5: Self-check + commit message**

Confirm by reading: the panel shows exactly two status rows (NixBlitz, Plugins) + an optional note + one top timestamp; the old `flake inputs:` / per-input / `system closure` rows are gone; the Check section's view-actions collapsed to one gated "What's changing…"; the sidebar + heading read "Updates".

Suggested subject: `feat(updates): two-row Updates panel + rename Check → Updates`

---

### Task 3: "Updated software" section in the details viewer (`tui`)

**Files:**

- Modify: `tui/lib/src/ui/widgets/cached_package_diff.dart`

**Interfaces:**

- Consumes: `readUpdateStatus()`, `CheckResult.inputsAhead` (`InputAhead`: `name`, `currentRev`, `upstreamRev`), `CheckResult.pluginsAhead` (`PluginAhead`: `pluginId`, `currentVersion?`, `upstreamVersion?`, `currentRev`, `upstreamRev`), `wouldBuild`, `diffText`, `kTuiInputName`, `nvdLineColor`, `humanizeAge`.

No automated test (nocterm UI); covered by manual.

- [ ] **Step 1: Build a single combined body with an "Updated software" section first**

Replace the body-shaping block in `CachedPackageDiff.build` (currently the `compileNeeded` if/else that sets `title`, `lines`, `lineColor`, lines ~32–54) with a single combined builder that always leads with "Updated software" when present, then the build list, then the diff:

```dart
    final lines = <String>[];

    // ── Updated software (which inputs / plugins moved) ──
    final inputs = result?.inputsAhead ?? const <InputAhead>[];
    final plugins = result?.pluginsAhead ?? const <PluginAhead>[];
    if (inputs.isNotEmpty || plugins.isNotEmpty) {
      lines.add('Updated software');
      for (final i in inputs) {
        final name = i.name == kTuiInputName
            ? '${i.name} (the NixBlitz software)'
            : i.name;
        lines.add(
          '  $name  ${_short(i.currentRev)} → ${_short(i.upstreamRev)}',
        );
      }
      for (final p in plugins) {
        final from = p.currentVersion ?? _short(p.currentRev);
        final to = p.upstreamVersion ?? _short(p.upstreamRev);
        lines.add('  ${p.pluginId}  $from → $to');
      }
      lines.add('');
    }

    // ── Packages that build on the node (no substitute) ──
    if (result != null && result.wouldBuild.isNotEmpty) {
      final n = result.wouldBuild.length;
      lines.add('Builds on the node ($n)');
      lines.add(
        '  No binary-cache substitute — built locally on the next Apply. On a '
        'Pi 5 a fresh rustc storm can take hours.',
      );
      for (final d in result.wouldBuild) {
        lines.add('  $d');
      }
      lines.add('');
    }

    // ── Per-package diff (nvd) ──
    final diff = (result?.diffText ?? '').trim();
    if (diff.isNotEmpty) {
      lines.add('Package changes');
      lines.addAll(diff.split('\n'));
    }

    if (lines.isEmpty) {
      lines.add('Nothing staged from the last check.');
    }

    final title = "What's changing — checked $ago";
    final lineColor = nvdLineColor; // colours the [U]/[A]/[R]/Closure lines
```

Add the `_short` helper to the file (top-level, below the class):

```dart
/// 7-char short rev for display; passes through anything already short.
String _short(String rev) => rev.length > 7 ? rev.substring(0, 7) : rev;
```

Remove the now-unused `compileNeeded` local. The `Text(title, ...)` + `ScrollableLog(lines: lines, lineColor: lineColor, ...)` widget tree below stays unchanged (it already consumes `title`, `lines`, `lineColor`).

Ensure `InputAhead`/`PluginAhead`/`kTuiInputName` resolve — they come from `package:common/common.dart` (already imported).

- [ ] **Step 2: Analyze + format + test**

Run: `just analyze` (no new issues in cached_package_diff.dart) ; `just format` ; `just test`.

- [ ] **Step 3: Self-check + commit message**

Confirm by reading: the details viewer now leads with "Updated software" (inputs with `nixblitz` labelled + plugins with version/rev deltas), then "Builds on the node (N)" when `wouldBuild` is non-empty, then "Package changes" (the nvd diff); the title reads "What's changing". Sections render only when they have content.

Suggested subject: `feat(updates): consolidate update details into "What's changing"`

---

## Self-Review

**Spec coverage:**

- Two rows (NixBlitz rollup + Plugins) → Task 2 (`_statusRow` + mapper). ✓
- "system closure" → "when you apply" note (compile/fast/re-pin/up-to-date) → Task 1 mapper + Task 2 render. ✓
- One top timestamp → Task 2 ("checked $age", per-row age dropped). ✓
- Sidebar/heading Check → Updates → Task 2 Step 3. ✓
- One "What's changing…" action gated on details → Task 2 Step 2. ✓
- Consolidated details view (inputs moved + builds + diff) → Task 3. ✓
- Testable mapper in common → Task 1. ✓
- Not changing service/model/Apply → Global Constraints; no task touches them. ✓

**Placeholder scan:** none — all code blocks are concrete; note strings copied verbatim from the spec.

**Type consistency:** `UpdatesDisplay`/`UpdateRowStatus`/`mapUpdatesDisplay({result, aheadInputCount})` defined in Task 1 are consumed verbatim in Task 2. `_statusRow`/`_topLevelRow` signatures align. `InputAhead`/`PluginAhead` field names (`name`, `currentRev`, `upstreamRev`, `pluginId`, `currentVersion`, `upstreamVersion`) match `update_status.dart` as read.
