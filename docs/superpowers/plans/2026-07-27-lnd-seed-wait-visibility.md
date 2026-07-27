# LND Seed-Wait Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the wizard's opaque LND seed-wait spinner with a live sub-step checklist, defer/announce the sudo prompt, and add an `[l]` scrollable LND-journal popup.

**Architecture:** A stateful `LndSeedWaitService` in `common` runs one short-lived poll pass per 2 s tick (unprivileged `systemctl show` first; sudo only after the unit is active, and only after one "announce" tick so the UI shows the sudo warning before the prompt). The setup view renders the returned `SeedWaitStatus` as a checklist and mounts an on-demand journal popup that re-runs `sudo journalctl -u lnd -n 150 --no-pager` every 2 s while open.

**Tech Stack:** Dart, nocterm + nocterm_riverpod (TUI), Riverpod, `package:test`. jj colocated with git.

**Spec:** `docs/superpowers/specs/2026-07-27-lnd-seed-wait-visibility-design.md`

## Global Constraints

- Branch: `feat/seed-wait-visibility` (stacked on `fix/update-check-observability`). Commits via `jj` (`jj describe -m "..."` then `jj new`), never `git commit`.
- Nocterm pitfalls (CLAUDE.md) are binding: no StateProvider writes mid-key-handler followed by more work; full try/catch around every handler body; sync I/O in key handlers; no IOSink/stream file writing; guard re-entry with plain instance bools.
- **No sudo subprocess of any kind may run while the LND unit is not yet active** (this is the fix for the surprise popup).
- The sudo warning must be rendered on screen at least one poll tick (2 s) before the first sudo call.
- Seed safety unchanged: seed words only ever live in `SeedWaitStatus.seedWords` (transient) and the view's `_lndSeedWords` instance field; never in a Riverpod provider, never logged.
- Journal popup: poll-based only (`journalctl -n 150 --no-pager` per tick while open) — no `journalctl -f`, no long-lived child process.
- The visibility layer must never block the wizard: failures degrade to the existing error screen + retry.
- Post-task verification trio before claiming done: `just test`, `just analyze`, `just format`.

## Refinements vs the spec (agreed at planning)

1. `SeedWaitPhase` has **no `failed` value**. Failure = `error != null` while `phase` keeps pointing at the item that failed (so the checklist knows which row gets `✗`). Terminal = `done` or `error != null`.
2. The sudo announcement is a dim hint line under the checklist (rendered from the moment the unit is active), in addition to the `(needs sudo)` suffix on item 3 — because the `test -f` probe of item 2 also needs sudo, the hint must precede item 2's first sudo call.

---

### Task 1: `LndSeedWaitService` + `SeedWaitStatus` (common)

**Files:**

- Create: `common/lib/src/services/lnd_seed_wait_service.dart`
- Modify: `common/lib/common.dart` (add one `export` line, alphabetical with the others)
- Test: `common/test/services/lnd_seed_wait_service_test.dart`

**Interfaces:**

- Consumes: `ServiceState` + `SystemService.parseServiceStatus` from `common/lib/src/services/system_service.dart` (`parseServiceStatus(String name, String output) → ServiceStatus`, maps `ActiveState=active|inactive|failed|activating` → `running|stopped|failed|activating`, else `unknown`).
- Produces (later tasks rely on these exact names):
  - `enum SeedWaitPhase { startingService, waitingForSeedFile, readingSeed, done }`
  - `class SeedWaitStatus { final SeedWaitPhase phase; final ServiceState lndState; final String? error; final List<String>? seedWords; bool get isTerminal; }`
  - `class LndSeedWaitService { LndSeedWaitService({required this.ensureSudoFresh, required this.runSudo, ProcessRunner? runProcess, String seedPath, String unit}); Future<SeedWaitStatus> poll(); }`
  - `typedef SudoResult = ({int exitCode, String stdout, String stderr});`

- [ ] **Step 1: Write the failing tests**

`common/test/services/lnd_seed_wait_service_test.dart`:

```dart
import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

/// Scripted fakes: each test declares what systemctl reports and how the
/// sudo probes behave, then asserts the returned phase AND how many sudo
/// calls were made (the deferral guarantee is call-count based).
class _Harness {
  _Harness({
    required this.activeStates, // consumed one per poll() call
    this.ensureFreshResult = true,
    this.testFileExists = false,
    this.catResult = (exitCode: 0, stdout: '', stderr: ''),
  });

  final List<String> activeStates;
  bool ensureFreshResult;
  bool testFileExists;
  ({int exitCode, String stdout, String stderr}) catResult;

  int systemctlCalls = 0;
  int ensureFreshCalls = 0;
  final List<List<String>> sudoCalls = [];

  late final LndSeedWaitService service = LndSeedWaitService(
    ensureSudoFresh: () async {
      ensureFreshCalls++;
      return ensureFreshResult;
    },
    runSudo: (args) async {
      sudoCalls.add(args);
      if (args.first == 'test') {
        return (exitCode: testFileExists ? 0 : 1, stdout: '', stderr: '');
      }
      if (args.first == 'cat') return catResult;
      return (exitCode: 0, stdout: '', stderr: '');
    },
    runProcess: (cmd, args) async {
      systemctlCalls++;
      final state = activeStates[
          systemctlCalls <= activeStates.length ? systemctlCalls - 1 : activeStates.length - 1];
      return ProcessResult(0, 0, 'ActiveState=$state\nSubState=x\n', '');
    },
  );
}

const _seed24 =
    'ability ability ability ability ability ability ability ability '
    'ability ability ability ability ability ability ability ability '
    'ability ability ability ability ability ability ability ability';

void main() {
  group('LndSeedWaitService.poll', () {
    test('unit inactive → startingService, ZERO sudo activity', () async {
      final h = _Harness(activeStates: ['inactive']);
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.startingService);
      expect(s.lndState, ServiceState.stopped);
      expect(s.isTerminal, isFalse);
      expect(h.ensureFreshCalls, 0);
      expect(h.sudoCalls, isEmpty);
    });

    test('unit activating → startingService, still no sudo', () async {
      final h = _Harness(activeStates: ['activating']);
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.startingService);
      expect(h.ensureFreshCalls, 0);
    });

    test('unit failed → error set, phase startingService, no sudo', () async {
      final h = _Harness(activeStates: ['failed']);
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.startingService);
      expect(s.error, contains('lnd service failed'));
      expect(s.isTerminal, isTrue);
      expect(h.ensureFreshCalls, 0);
    });

    test('first active poll is announce-only: waitingForSeedFile with '
        'ZERO sudo calls; second active poll probes', () async {
      final h = _Harness(activeStates: ['active', 'active']);
      final first = await h.service.poll();
      expect(first.phase, SeedWaitPhase.waitingForSeedFile);
      expect(h.ensureFreshCalls, 0, reason: 'announce tick must not sudo');
      expect(h.sudoCalls, isEmpty);

      final second = await h.service.poll();
      expect(second.phase, SeedWaitPhase.waitingForSeedFile);
      expect(h.ensureFreshCalls, 1);
      expect(h.sudoCalls, [
        ['test', '-f', '/mnt/data/lnd/lnd-seed-mnemonic'],
      ]);
    });

    test('sudo cancelled → error, phase waitingForSeedFile', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..ensureFreshResult = false;
      await h.service.poll(); // announce
      final s = await h.service.poll();
      expect(s.error, 'Sudo authorization cancelled.');
      expect(s.phase, SeedWaitPhase.waitingForSeedFile);
      expect(s.isTerminal, isTrue);
    });

    test('file present + 24 words → done with seedWords', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..testFileExists = true
        ..catResult = (exitCode: 0, stdout: _seed24, stderr: '');
      await h.service.poll(); // announce
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.done);
      expect(s.seedWords, hasLength(24));
      expect(s.isTerminal, isTrue);
    });

    test('cat fails → error mentions exit code, phase readingSeed', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..testFileExists = true
        ..catResult = (exitCode: 1, stdout: '', stderr: 'denied');
      await h.service.poll();
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.readingSeed);
      expect(s.error, contains('exit 1'));
    });

    test('wrong word count → error, phase readingSeed', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..testFileExists = true
        ..catResult = (exitCode: 0, stdout: 'only three words', stderr: '');
      await h.service.poll();
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.readingSeed);
      expect(s.error, contains('3 words'));
    });

    test('systemctl runner throwing → error status, not an exception', () async {
      final service = LndSeedWaitService(
        ensureSudoFresh: () async => true,
        runSudo: (_) async => (exitCode: 0, stdout: '', stderr: ''),
        runProcess: (_, __) async => throw const ProcessException('systemctl', []),
      );
      final s = await service.poll();
      expect(s.error, isNotNull);
      expect(s.isTerminal, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd common && dart test test/services/lnd_seed_wait_service_test.dart`
Expected: FAIL — `LndSeedWaitService` / `SeedWaitPhase` undefined.

- [ ] **Step 3: Implement**

`common/lib/src/services/lnd_seed_wait_service.dart`:

```dart
import 'dart:io';

import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/system_service.dart' show SystemService;

typedef SudoResult = ({int exitCode, String stdout, String stderr});

/// Which checklist row is currently in progress. Failure is NOT a phase:
/// on failure [SeedWaitStatus.error] is set while [SeedWaitStatus.phase]
/// keeps pointing at the row that failed, so the UI can mark that row ✗.
enum SeedWaitPhase { startingService, waitingForSeedFile, readingSeed, done }

class SeedWaitStatus {
  final SeedWaitPhase phase;
  final ServiceState lndState;
  final String? error;

  /// Present only when [phase] == done. The caller (setup view) moves
  /// these into its own instance state and drops this object — the
  /// service never retains them (see below).
  final List<String>? seedWords;

  const SeedWaitStatus({
    required this.phase,
    this.lndState = ServiceState.unknown,
    this.error,
    this.seedWords,
  });

  bool get isTerminal => phase == SeedWaitPhase.done || error != null;
}

/// One short-lived poll pass per call — composed by the setup view's
/// existing 2 s timer. Guarantees:
///
///  1. No sudo subprocess runs while the lnd unit is not active
///     (the unprivileged `systemctl show` gate comes first).
///  2. The first poll after the unit turns active is announce-only:
///     it returns without touching sudo, giving the UI a full tick to
///     render the "will ask for sudo" warning before the prompt can
///     appear.
///
/// Stateful only in `_sudoAnnounced`; the seed itself is returned, not
/// retained.
class LndSeedWaitService {
  LndSeedWaitService({
    required this.ensureSudoFresh,
    required this.runSudo,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
    this.seedPath = '/mnt/data/lnd/lnd-seed-mnemonic',
    this.unit = 'lnd',
  }) : _runProcess = runProcess ?? _defaultRunProcess;

  final Future<bool> Function() ensureSudoFresh;
  final Future<SudoResult> Function(List<String> args) runSudo;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final String seedPath;
  final String unit;

  bool _sudoAnnounced = false;

  static Future<ProcessResult> _defaultRunProcess(
    String cmd,
    List<String> args,
  ) => Process.run(cmd, args);

  Future<SeedWaitStatus> poll() async {
    try {
      return await _pollInner();
    } catch (e, st) {
      LogService.error('LndSeedWaitService.poll failed', e, st);
      return SeedWaitStatus(
        phase: SeedWaitPhase.startingService,
        error: 'Seed wait failed: $e',
      );
    }
  }

  Future<SeedWaitStatus> _pollInner() async {
    // Unprivileged gate first — never sudo before the unit is active.
    final show = await _runProcess('systemctl', [
      'show',
      unit,
      '--property=ActiveState,SubState',
      '--no-pager',
    ]);
    final state =
        SystemService.parseServiceStatus(unit, show.stdout as String).state;

    if (state == ServiceState.failed) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.startingService,
        lndState: state,
        error: 'lnd service failed to start — press [l] for the LND log.',
      );
    }
    if (state != ServiceState.running) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.startingService,
        lndState: state,
      );
    }

    // Announce-only tick: the UI gets one full poll interval showing
    // the sudo warning before the first privileged call can prompt.
    if (!_sudoAnnounced) {
      _sudoAnnounced = true;
      return SeedWaitStatus(
        phase: SeedWaitPhase.waitingForSeedFile,
        lndState: state,
      );
    }

    final ok = await ensureSudoFresh();
    if (!ok) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.waitingForSeedFile,
        lndState: state,
        error: 'Sudo authorization cancelled.',
      );
    }

    final probe = await runSudo(['test', '-f', seedPath]);
    if (probe.exitCode != 0) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.waitingForSeedFile,
        lndState: state,
      );
    }

    final res = await runSudo(['cat', seedPath]);
    if (res.exitCode != 0) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.readingSeed,
        lndState: state,
        error:
            'Could not read seed file (exit ${res.exitCode}): '
            '${res.stderr.trim()}',
      );
    }

    final words = res.stdout
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.length != 24) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.readingSeed,
        lndState: state,
        error:
            'Seed file has ${words.length} words; expected 24. '
            'Aborting display.',
      );
    }

    return SeedWaitStatus(
      phase: SeedWaitPhase.done,
      lndState: state,
      seedWords: words,
    );
  }
}
```

In `common/lib/common.dart`, add (sorted beside the other service exports):

```dart
export 'src/services/lnd_seed_wait_service.dart';
```

- [ ] **Step 4: Run tests**

Run: `cd common && dart test test/services/lnd_seed_wait_service_test.dart`
Expected: PASS (9 tests).

- [ ] **Step 5: Trio + commit**

Run `just test && just analyze && just format` from the repo root, then:

```bash
jj describe -m "feat(common): LndSeedWaitService — phased, sudo-deferred seed-wait poll

One short-lived pass per tick: unprivileged systemctl gate, an
announce-only tick after the unit turns active (so the UI can warn
about sudo a full 2s before the prompt), then the existing test -f /
cat probes. Failure is error-on-phase rather than a phase, so the
checklist knows which row to mark failed.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj new
```

---

### Task 2: Checklist rows + widget (tui)

**Files:**

- Create: `tui/lib/src/ui/widgets/seed_wait_checklist.dart`
- Test: `tui/test/seed_wait_checklist_test.dart`

**Interfaces:**

- Consumes: `SeedWaitPhase`, `SeedWaitStatus`, `ServiceState` from `package:common/common.dart` (Task 1).
- Produces:
  - `class SeedWaitRow { final String glyph; final String label; final bool isCurrent; final bool isFailed; }`
  - `List<SeedWaitRow> seedWaitChecklistRows(SeedWaitStatus status)` — pure, nocterm-free.
  - `class SeedWaitChecklist extends StatelessComponent { const SeedWaitChecklist({required this.status}); }` — renders rows + sudo hint + `[l]` hint + error line.

- [ ] **Step 1: Write the failing test**

`tui/test/seed_wait_checklist_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:tui/src/ui/widgets/seed_wait_checklist.dart';
import 'package:test/test.dart';

void main() {
  group('seedWaitChecklistRows', () {
    test('startingService: row 0 current, rest pending', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(phase: SeedWaitPhase.startingService),
      );
      expect(rows, hasLength(3));
      expect(rows[0].isCurrent, isTrue);
      expect(rows[0].glyph, '⠿'); // spinner placeholder glyph
      expect(rows[1].glyph, '○');
      expect(rows[2].glyph, '○');
      expect(rows[2].label, contains('sudo'));
    });

    test('waitingForSeedFile: row 0 done, row 1 current', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(
          phase: SeedWaitPhase.waitingForSeedFile,
          lndState: ServiceState.running,
        ),
      );
      expect(rows[0].glyph, '✓');
      expect(rows[1].isCurrent, isTrue);
      expect(rows[2].glyph, '○');
    });

    test('done: all rows ✓', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(phase: SeedWaitPhase.done),
      );
      expect(rows.map((r) => r.glyph), everyElement('✓'));
    });

    test('failure marks the phase row ✗ and keeps earlier rows ✓', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(
          phase: SeedWaitPhase.readingSeed,
          error: 'Could not read seed file (exit 1): denied',
        ),
      );
      expect(rows[0].glyph, '✓');
      expect(rows[1].glyph, '✓');
      expect(rows[2].glyph, '✗');
      expect(rows[2].isFailed, isTrue);
    });

    test('failure during startingService marks row 0 ✗', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(
          phase: SeedWaitPhase.startingService,
          lndState: ServiceState.failed,
          error: 'lnd service failed to start — press [l] for the LND log.',
        ),
      );
      expect(rows[0].glyph, '✗');
      expect(rows[0].isFailed, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd tui && dart test test/seed_wait_checklist_test.dart`
Expected: FAIL — file/function not found.

- [ ] **Step 3: Implement**

`tui/lib/src/ui/widgets/seed_wait_checklist.dart`:

```dart
import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

import 'spinner.dart';

/// Pure row model so glyph/label logic is testable without nocterm.
class SeedWaitRow {
  final String glyph;
  final String label;
  final bool isCurrent;
  final bool isFailed;

  const SeedWaitRow({
    required this.glyph,
    required this.label,
    this.isCurrent = false,
    this.isFailed = false,
  });
}

const _labels = [
  'LND service started',
  'Waiting for LND to create the wallet seed',
  'Read seed file (needs sudo)',
];

/// Maps a [SeedWaitStatus] to the three checklist rows. The current
/// row's glyph is '⠿' — a placeholder the widget swaps for a live
/// [Spinner]; tests assert on the placeholder.
List<SeedWaitRow> seedWaitChecklistRows(SeedWaitStatus status) {
  final currentIdx = switch (status.phase) {
    SeedWaitPhase.startingService => 0,
    SeedWaitPhase.waitingForSeedFile => 1,
    SeedWaitPhase.readingSeed => 2,
    SeedWaitPhase.done => 3, // past the end: everything ✓
  };
  final failed = status.error != null;
  return List.generate(3, (i) {
    if (i < currentIdx) {
      return SeedWaitRow(glyph: '✓', label: _labels[i]);
    }
    if (i == currentIdx) {
      return SeedWaitRow(
        glyph: failed ? '✗' : '⠿',
        label: _labels[i],
        isCurrent: !failed,
        isFailed: failed,
      );
    }
    return SeedWaitRow(glyph: '○', label: _labels[i]);
  });
}

class SeedWaitChecklist extends StatelessComponent {
  const SeedWaitChecklist({required this.status});

  final SeedWaitStatus status;

  @override
  Component build(BuildContext context) {
    final rows = seedWaitChecklistRows(status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Lightning Wallet Setup',
          style: const TextStyle(
            color: Color.fromRGB(247, 147, 26),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 1),
        for (final row in rows)
          if (row.isCurrent)
            Spinner(label: row.label)
          else
            Text(
              '${row.glyph} ${row.label}',
              style: TextStyle(
                color: row.isFailed
                    ? const Color.fromRGB(255, 80, 80)
                    : row.glyph == '✓'
                    ? const Color.fromRGB(80, 220, 120)
                    : const Color.fromRGB(120, 120, 140),
              ),
            ),
        const SizedBox(height: 1),
        if (status.phase != SeedWaitPhase.startingService ||
            status.error != null)
          const Text(
            'Reading the seed requires root — a sudo prompt may appear.',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        if (status.error != null) ...[
          const SizedBox(height: 1),
          Text(
            status.error!,
            style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
          ),
        ],
        const SizedBox(height: 1),
        const Text(
          '[l] show LND log',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      ],
    );
  }
}
```

Note: if `Spinner` takes different constructor args on this branch, match
the existing call in `setup_view.dart` (`Spinner(label: '...')`). If the
`for`/`if` collection-element mix trips the analyzer with nocterm's
non-const widgets, fall back to building a plain `List<Component>` first.

- [ ] **Step 4: Run tests**

Run: `cd tui && dart test test/seed_wait_checklist_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Trio + commit**

```bash
jj describe -m "feat(tui): seed-wait checklist rows + widget

Pure row model (glyph/label/current/failed) so phase→row mapping is
unit-tested without nocterm; widget renders rows, the sudo warning
(shown before any sudo call can fire, per the announce tick), the
error line, and the [l] log hint.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj new
```

---

### Task 3: `LndJournalPopup` (tui)

**Files:**

- Create: `tui/lib/src/ui/widgets/lnd_journal_popup.dart`

**Interfaces:**

- Consumes: `PopupChrome` + `kPopupAccent` (`popup_chrome.dart`), `ScrollableLog` with `ignoreModalGate: true` (`scrollable_log.dart`), `viewportSizeProvider` (`../../providers/viewport_provider.dart`). Mirror `update_check_log_popup.dart` for sizing/chrome.
- Produces: `class LndJournalPopup extends StatefulComponent { const LndJournalPopup({required this.fetchJournal, required this.onClose}); final Future<String> Function() fetchJournal; final VoidCallback onClose; }`
- No unit test (timer + nocterm rendering; covered by the manual VM gate). The fetch callback is injected so the widget owns no sudo logic.

- [ ] **Step 1: Implement**

`tui/lib/src/ui/widgets/lnd_journal_popup.dart`:

```dart
import 'dart:async';
import 'dart:math' as math;

import 'package:common/common.dart' show LogService;
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/viewport_provider.dart';
import 'popup_chrome.dart';
import 'scrollable_log.dart';

/// Live LND journal viewer for the wizard's seed-wait step ([l]).
/// Poll-based on purpose: each 2 s tick runs a short-lived
/// `journalctl -n 150` via the injected [fetchJournal] — no
/// `journalctl -f` stream to manage, nothing to tear down beyond the
/// timer. Fetch errors become the popup's content; the wizard is never
/// affected.
class LndJournalPopup extends StatefulComponent {
  const LndJournalPopup({required this.fetchJournal, required this.onClose});

  final Future<String> Function() fetchJournal;
  final VoidCallback onClose;

  @override
  State<LndJournalPopup> createState() => _LndJournalPopupState();
}

class _LndJournalPopupState extends State<LndJournalPopup> {
  List<String> _lines = const ['Loading LND journal…'];
  Timer? _timer;
  bool _fetching = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final out = await component.fetchJournal();
      if (_disposed) return;
      setState(() {
        _lines = out.split('\n');
      });
    } catch (e, st) {
      LogService.error('LndJournalPopup: journal fetch failed', e, st);
      if (_disposed) return;
      setState(() {
        _lines = ['Journal fetch failed: $e'];
      });
    } finally {
      _fetching = false;
    }
  }

  @override
  Component build(BuildContext context) {
    final viewportWidth = context.watch(viewportSizeProvider).width;
    final viewportHeight = context.watch(viewportSizeProvider).height;
    final width = math.min(100, math.max(30, viewportWidth - 6));
    final height = math.min(30, math.max(10, viewportHeight - 6));

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            component.onClose();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('LndJournalPopup key handler failed', e, st);
          return true;
        }
      },
      child: Center(
        child: PopupChrome(
          width: width.toDouble(),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: SizedBox(
            height: height.toDouble(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'LND journal (refreshes every 2s)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: kPopupAccent,
                  ),
                ),
                const Divider(),
                Expanded(
                  child: ScrollableLog(lines: _lines, ignoreModalGate: true),
                ),
                const Divider(),
                const Text(
                  '[Esc] close   ↑/↓ scroll',
                  style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

Note: copy the exact `State`/`component` accessor idiom, `Divider` usage,
and scroll-hint footer from `update_check_log_popup.dart` on this branch —
if that file's structure differs from the sketch above (e.g. accessor is
`widget.` or the footer hint text differs), the existing file wins.

- [ ] **Step 2: Verify it compiles**

Run: `cd tui && dart analyze`
Expected: No issues.

- [ ] **Step 3: Trio + commit**

```bash
jj describe -m "feat(tui): poll-based LND journal popup for the seed-wait step

Mirrors the update-check log popup (PopupChrome + gate-ignoring
ScrollableLog). Poll-per-tick instead of journalctl -f so there is
no long-lived privileged child to tear down; fetch errors render as
popup content and never touch the wizard flow.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj new
```

---

### Task 4: Wire into `setup_view.dart`

**Files:**

- Modify: `tui/lib/src/ui/views/setup_view.dart` — the seed-wait cluster: instance fields near `_lndSeedWords` (~line 100), `_startLndSeedPoll`/`_tryLoadLndSeed` (~lines 1178–1258), `_buildLndSeedWaiting` (~line 1439), `_buildLndSeedError` (~line 1532).

**Interfaces:**

- Consumes: `LndSeedWaitService`, `SeedWaitStatus`, `SeedWaitPhase` (Task 1); `SeedWaitChecklist` (Task 2); `LndJournalPopup` (Task 3); existing `sudoSessionProvider`, `_kLndSeedPath`, `_stopLndSeedPoll`, `_markStepCompleted`.
- Produces: no new public surface — behavior change only.

- [ ] **Step 1: Add imports and instance state**

Imports (top of file, beside the other widget imports):

```dart
import '../widgets/lnd_journal_popup.dart';
import '../widgets/seed_wait_checklist.dart';
```

New instance fields next to `_lndSeedWords` / `_lndSeedError`:

```dart
/// Latest poll status for the checklist. Never outlives the step:
/// on `done` the words move to [_lndSeedWords] and this is reset to
/// a plain non-terminal value so a Riverpod-triggered rebuild can't
/// re-read stale seed words from it.
SeedWaitStatus _seedWaitStatus = const SeedWaitStatus(
  phase: SeedWaitPhase.startingService,
);

/// Poll service. Created lazily on first use so `context.read` of the
/// sudo session happens inside a build/microtask, not at field-init.
LndSeedWaitService? _seedWaitService;

/// Journal popup visibility. Plain bool (nocterm pitfall #1: no
/// provider writes mid-handler).
bool _lndJournalVisible = false;
```

- [ ] **Step 2: Replace `_tryLoadLndSeed` body with a `poll()` delegation**

```dart
  Future<void> _tryLoadLndSeed() async {
    if (_lndSeedLoading) return;
    if (_lndSeedWords != null || _lndSeedError != null) return;
    _lndSeedLoading = true;
    try {
      final session = context.read(sudoSessionProvider);
      _seedWaitService ??= LndSeedWaitService(
        ensureSudoFresh: session.ensureFresh,
        runSudo: (args) => session.runOneShot(args),
        seedPath: _kLndSeedPath,
      );
      final status = await _seedWaitService!.poll();
      if (status.phase == SeedWaitPhase.done && status.seedWords != null) {
        setState(() {
          _lndSeedWords = status.seedWords;
          // Wipe the words from checklist state immediately — the
          // reveal gate reads _lndSeedWords only.
          _seedWaitStatus = const SeedWaitStatus(phase: SeedWaitPhase.done);
        });
        _stopLndSeedPoll();
        return;
      }
      if (status.error != null) {
        setState(() {
          _seedWaitStatus = status;
          _lndSeedError = status.error;
        });
        _stopLndSeedPoll();
        return;
      }
      setState(() {
        _seedWaitStatus = status;
      });
    } catch (e, st) {
      LogService.error('LND seed load failed', e, st);
      setState(() {
        _lndSeedError = 'Error reading seed: $e';
      });
      _stopLndSeedPoll();
    } finally {
      _lndSeedLoading = false;
    }
  }
```

The old inline sudo/test/cat logic is gone — it now lives in the service
(Task 1) with identical messages, so `_buildLndSeedError` output text is
unchanged.

- [ ] **Step 3: Rewrite `_buildLndSeedWaiting` as checklist + popup overlay**

```dart
  Component _buildLndSeedWaiting() {
    return Stack(
      children: [
        Focusable(
          // Yield to the popup while it's up (same dispatch rule as the
          // app-level modals: the popup's Focusable must be reached by
          // the Stack iteration).
          focused: !_lndJournalVisible,
          onKeyEvent: (event) {
            try {
              if (event.character?.toLowerCase() == 'l') {
                setState(() {
                  _lndJournalVisible = true;
                });
                return true;
              }
              return false;
            } catch (e, st) {
              LogService.error('seed-wait key handler failed', e, st);
              return true;
            }
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: SeedWaitChecklist(status: _seedWaitStatus),
          ),
        ),
        if (_lndJournalVisible)
          LndJournalPopup(
            fetchJournal: _fetchLndJournal,
            onClose: () {
              setState(() {
                _lndJournalVisible = false;
              });
            },
          ),
      ],
    );
  }

  /// Journal fetch for the popup. Uses the sudo session's one-shot
  /// runner; by the time anyone opens the log the session is normally
  /// fresh, but ensureFresh here makes an explicit open work even
  /// before the poll's first sudo call (the user asked for the log —
  /// a prompt is expected then, not a surprise).
  Future<String> _fetchLndJournal() async {
    final session = context.read(sudoSessionProvider);
    final ok = await session.ensureFresh();
    if (!ok) return 'Sudo authorization cancelled — cannot read journal.';
    final res = await session.runOneShot([
      'journalctl',
      '-u',
      'lnd',
      '-n',
      '150',
      '--no-pager',
    ]);
    if (res.exitCode != 0) {
      return 'journalctl failed (exit ${res.exitCode}): ${res.stderr}';
    }
    return res.stdout;
  }
```

- [ ] **Step 4: Add `[l]` to the error screen**

In `_buildLndSeedError` (keeps existing `[r]` retry and `[Enter]` skip):

1. Wrap the existing `Container` child in the same `Stack` + popup pattern
   as Step 3 (popup element identical; `focused: !_lndJournalVisible` on
   the existing Focusable).
2. In its key handler, before the `'r'` branch, add:

```dart
          if (c == 'l') {
            setState(() {
              _lndJournalVisible = true;
            });
            return true;
          }
```

3. In the `'r'` (retry) branch, also reset the checklist so the retry
   starts from a clean state — replace the existing setState with:

```dart
            setState(() {
              _lndSeedError = null;
              _seedWaitStatus = const SeedWaitStatus(
                phase: SeedWaitPhase.startingService,
              );
              _seedWaitService = null; // fresh announce tick on retry
            });
```

4. Append to the hint line text: `[R] retry   [L] LND log   [Enter] continue without showing`.

- [ ] **Step 5: Run the full trio**

Run: `just test && just analyze && just format`
Expected: all pass; no analyzer issues in `setup_view.dart`.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(tui): live checklist + journal access for the LND seed wait

The initLightning step now renders the poll service's status as a
three-row checklist, warns about sudo before the first privileged
call can prompt (announce tick), marks the failing row on error, and
offers [l] — a live LND journal popup — from both the waiting and
error screens. Closes the wizard's last black-box wait.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj new
```

---

## Final verification

- `just test`, `just analyze`, `just format` — all green.
- Manual VM gate (user-run): full wizard pass — checklist advances
  row-by-row; sudo prompt appears only after "LND service started" shows ✓
  and the sudo warning line is visible; `[l]` opens a refreshing journal;
  Esc returns; seed reveal + choice flow unchanged; `[r]` retry after a
  forced failure restarts cleanly.
