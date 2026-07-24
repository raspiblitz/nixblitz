# Install Progress Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the install screen's silent, frozen-looking output with a live progress panel — install phase, a copy-progress bar for the long store-copy phase, elapsed time, and a log tail — using a heuristic source (disko phase markers + `df`/`du` byte counts), behind a source-agnostic panel a future internal-json source can reuse.

**Architecture:** A pure phase matcher (`install_phase.dart`) that `InstallService.parseDiskoStep` delegates to; an `InstallProgressTracker` (in `common`) fed line-by-line with injected `du`/`df` byte readers, emitting an `InstallProgress` value; a `BuildProgressPanel` nocterm widget; and `install_view` wiring. No `nix-output-monitor` binary — heuristic only.

**Tech Stack:** Dart (`common` + `tui`, `package:test`, Riverpod, nocterm + nocterm_test), `du`/`df` (coreutils) via `Process.run`.

## Global Constraints

- `common` does all IO / `Process` work; `tui` is UI only. (CLAUDE.md)
- Nocterm pitfalls: no `StateProvider` write mid-key-handler before sync work; full-body `try/catch` in key handlers; synchronous IO in handlers; no `IOSink`. (Provider writes inside a _stream listener_ — not a key handler — are fine; `install_view` already does this.)
- **The progress UI must never block, slow, or fail the install.** Every `du`/`df` failure degrades silently (drop the bar, keep phase + log). The existing exit-code → complete/failed routing, `[r]` retry, and `~/nixblitz.log` capture are preserved unchanged.
- **No new runtime dependency** — no `nix-output-monitor` in the closure; `du`/`df` only.
- jj colocated repo — commits via `jj`, not `git`. The spec (`docs/superpowers/specs/2026-07-24-install-progress-panel-design.md`) is already committed as the branch base of `feat/install-progress-panel`; Task 1 does NOT re-commit it.
- Branch: `feat/install-progress-panel` (off `main`). Do NOT merge to main — manual VM verification of a live `disko-install` is the acceptance gate.
- Commit trailer on every message: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. `#N` issue refs allowed. Print/apply commits via jj per the executor's convention.
- Disko-install's offline heavy phase is a plain `xargs cp` (no nix json). The two load-bearing markers are the verbatim disko-install echoes **`Copying store paths`** and **`Loading nix database`**.

---

## File Structure

**Create (`common`):**

- `common/lib/src/services/install/install_phase.dart` — `InstallPhase` enum, `installPhaseForLine`, `phaseLabel` (pure).
- `common/lib/src/services/install/install_progress.dart` — `InstallProgress` value + `InstallProgressTracker` + pure `parseDuBytes`/`parseDfUsedBytes` + the real `du`/`df` reader helpers.

**Create (`tui`):**

- `tui/lib/src/ui/widgets/build_progress_panel.dart` — the panel widget.

**Modify:**

- `common/lib/src/services/install_service.dart` — `parseDiskoStep` delegates to `installPhaseForLine`+`phaseLabel`.
- `common/lib/common.dart` — export the two new `install/` files (io-bearing; keep out of any web-safe export set).
- `tui/lib/src/ui/views/install_view.dart` — feed the tracker, render the panel, `[l]` log toggle.
- `tui/lib/src/providers/ui_state_provider.dart` (or wherever install providers live — grep `installCurrentStepLabelProvider`) — add `installProgressProvider`.

---

## Interfaces (locked signatures)

```dart
// install_phase.dart
enum InstallPhase {
  preparing, building, partitioning, formatting, mounting,
  copying, loadingDb, installing, done,
}
// Note: install FAILURE is represented by the existing `InstallStep.failed`
// at the view level (the view switches to _buildFailed on non-zero exit),
// so InstallPhase deliberately has no `failed` member.
InstallPhase? installPhaseForLine(String line); // null == no transition
String phaseLabel(InstallPhase phase);

// install_progress.dart
class InstallProgress {
  final InstallPhase phase;
  final double? copyFraction; // 0..1 while copying (rising, clamped ≤0.99) and
                              // exactly 1.0 during loadingDb; null otherwise
  const InstallProgress({required this.phase, this.copyFraction});
  // value equality (== / hashCode) so provider writes don't churn
}
int? parseDuBytes(String duStdout);        // "12345\t/nix/store\n" -> 12345
int? parseDfUsedBytes(String dfStdout);    // "used\n12345\n" -> 12345
Future<int?> duSourceBytes([String path = '/nix/store']);          // Process.run('du',['-sb',path])
Future<int?> dfUsedBytes(String mountPoint);                       // Process.run('df',['-B1','--output=used',mountPoint])

class InstallProgressTracker {
  InstallProgressTracker({
    required Future<int?> Function() readTotalBytes,
    required Future<int?> Function() readUsedBytes,
    Duration pollInterval = const Duration(seconds: 2),
    void Function(InstallProgress) onChange,   // controller wires this to the provider
  });
  InstallProgress get value;
  void addLine(String line);
  void dispose();
}
```

---

## Task 1: Install phase matcher

**Files:**

- Create: `common/lib/src/services/install/install_phase.dart`
- Modify: `common/lib/src/services/install_service.dart` (`parseDiskoStep`)
- Test: `common/test/services/install/install_phase_test.dart`

**Interfaces:**

- Produces: `enum InstallPhase`, `InstallPhase? installPhaseForLine(String)`, `String phaseLabel(InstallPhase)`.
- Consumed by: Task 2 (tracker), Task 4 (label + panel).

**Design:** `installPhaseForLine` is the single matcher; `parseDiskoStep` becomes `installPhaseForLine(line)` → `phaseLabel`. `phaseLabel` returns the SAME strings `parseDiskoStep` already returns for existing markers (so existing labels/tests are preserved), and adds labels for the new phases. First-match-wins order; the offline markers (`Copying store paths`, `Loading nix database`) and `nixos-install` are the additions that fix the "frozen during cp" gap.

- [ ] **Step 1: Write the failing test**

```dart
// common/test/services/install/install_phase_test.dart
import 'package:test/test.dart';
import 'package:common/src/services/install/install_phase.dart';
import 'package:common/src/services/install_service.dart';

void main() {
  group('installPhaseForLine', () {
    test('detects the verbatim disko-install offline markers', () {
      expect(installPhaseForLine('Copying store paths'), InstallPhase.copying);
      expect(installPhaseForLine('Loading nix database'), InstallPhase.loadingDb);
    });
    test('detects partition/format/mount/build/install/done markers', () {
      expect(installPhaseForLine('running sgdisk ...'), InstallPhase.partitioning);
      expect(installPhaseForLine('mkfs.ext4 /dev/sda2'), InstallPhase.formatting);
      expect(installPhaseForLine('mount /dev/sda2 /mnt'), InstallPhase.mounting);
      expect(installPhaseForLine("building '/nix/store/...'"), InstallPhase.building);
      expect(installPhaseForLine('installing the boot loader'), InstallPhase.installing);
      expect(installPhaseForLine('running nixos-install'), InstallPhase.installing);
      expect(installPhaseForLine('disko-install succeeded'), InstallPhase.done);
    });
    test('lowercase nix "copying path" still maps to copying', () {
      expect(installPhaseForLine("copying path '/nix/store/x' ..."), InstallPhase.copying);
    });
    test('non-marker lines produce no transition', () {
      expect(installPhaseForLine('some unrelated chatter'), isNull);
      expect(installPhaseForLine(''), isNull);
    });
  });

  group('phaseLabel', () {
    test('preserves existing parseDiskoStep label strings', () {
      expect(phaseLabel(InstallPhase.partitioning), 'Partitioning disk...');
      expect(phaseLabel(InstallPhase.formatting), 'Formatting partitions...');
      expect(phaseLabel(InstallPhase.mounting), 'Mounting filesystems...');
      expect(phaseLabel(InstallPhase.copying), 'Copying NixOS store paths...');
      expect(phaseLabel(InstallPhase.installing), 'Installing bootloader...');
      expect(phaseLabel(InstallPhase.loadingDb), 'Loading Nix database...');
    });
  });

  group('parseDiskoStep delegates (behaviour preserved + markers added)', () {
    test('existing markers keep their labels', () {
      expect(InstallService.parseDiskoStep('running sgdisk'), 'Partitioning disk...');
      expect(InstallService.parseDiskoStep('boot loader'), 'Installing bootloader...');
    });
    test('now also catches the offline cp markers it used to miss', () {
      expect(InstallService.parseDiskoStep('Copying store paths'), 'Copying NixOS store paths...');
      expect(InstallService.parseDiskoStep('Loading nix database'), 'Loading Nix database...');
    });
  });
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd common && dart test test/services/install/install_phase_test.dart`
Expected: FAIL — `install_phase.dart` missing / symbols undefined.

- [ ] **Step 3: Implement the matcher**

```dart
// common/lib/src/services/install/install_phase.dart

/// Coarse phase of a `disko-install` run, derived from its plain output.
/// Failure is NOT a phase here — the view represents it via
/// `InstallStep.failed` on a non-zero exit.
enum InstallPhase {
  preparing,
  building,
  partitioning,
  formatting,
  mounting,
  copying,
  loadingDb,
  installing,
  done,
}

/// Classify a single output line into a phase transition, or null when
/// the line implies no change. First match wins; ordered so the
/// load-bearing offline markers ("Copying store paths", "Loading nix
/// database") and end phases win over the coarser build/partition ones.
InstallPhase? installPhaseForLine(String line) {
  final l = line.toLowerCase();
  if (l.contains('disko-install succeeded')) return InstallPhase.done;
  if (l.contains('loading nix database')) return InstallPhase.loadingDb;
  if (l.contains('boot loader') || l.contains('nixos-install')) {
    return InstallPhase.installing;
  }
  // "Copying store paths" (disko-install echo) OR nix's "copying path '...'".
  if (l.contains('copying store paths') || l.contains('copying')) {
    return InstallPhase.copying;
  }
  if (l.contains('mkfs') || l.contains('formatting')) {
    return InstallPhase.formatting;
  }
  if (l.contains('mount ')) return InstallPhase.mounting;
  if (l.contains('sgdisk') || l.contains('wipefs') || l.contains('zpool')) {
    return InstallPhase.partitioning;
  }
  if (l.contains('building ') || l.contains('evaluating')) {
    return InstallPhase.building;
  }
  return null;
}

/// Human label for a phase. For phases that `parseDiskoStep` already
/// labelled, the string is identical (preserving existing behaviour).
String phaseLabel(InstallPhase phase) => switch (phase) {
  InstallPhase.preparing => 'Starting...',
  InstallPhase.building => 'Building install artifacts...',
  InstallPhase.partitioning => 'Partitioning disk...',
  InstallPhase.formatting => 'Formatting partitions...',
  InstallPhase.mounting => 'Mounting filesystems...',
  InstallPhase.copying => 'Copying NixOS store paths...',
  InstallPhase.loadingDb => 'Loading Nix database...',
  InstallPhase.installing => 'Installing bootloader...',
  InstallPhase.done => 'Finishing...',
};
```

Then refactor `parseDiskoStep` in `common/lib/src/services/install_service.dart` (add the import `import 'install/install_phase.dart';` at the top of the file):

```dart
  static String? parseDiskoStep(String line) {
    final phase = installPhaseForLine(line);
    return phase == null ? null : phaseLabel(phase);
  }
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd common && dart test test/services/install/install_phase_test.dart`
Expected: PASS. Then `cd common && dart test test/services/install_service_test.dart` (if present) — the existing parseDiskoStep cases stay green because the labels are unchanged.

- [ ] **Step 5: Commit**

```
feat(common): install phase matcher (fixes silent-cp step label)

parseDiskoStep only matched lowercase "copying", missing disko-install's
verbatim "Copying store paths" / "Loading nix database" echoes — so the
label froze during the offline xargs cp. Extract a single InstallPhase
matcher, delegate parseDiskoStep to it, and catch the missed markers.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## Task 2: InstallProgress + tracker

**Files:**

- Create: `common/lib/src/services/install/install_progress.dart`
- Modify: `common/lib/common.dart` (export `install/install_phase.dart` + `install/install_progress.dart`)
- Test: `common/test/services/install/install_progress_test.dart`

**Interfaces:**

- Consumes: `InstallPhase`, `installPhaseForLine` (Task 1).
- Produces: `InstallProgress`, `InstallProgressTracker`, `parseDuBytes`, `parseDfUsedBytes`, `duSourceBytes`, `dfUsedBytes` (see locked signatures).

**Design/behaviour:**

- `addLine(line)`: `installPhaseForLine(line)`; if non-null and differs from the current phase, transition (see below), then `onChange(value)`.
- Entering `copying`: read total once (cache it), start a periodic timer; each tick read used → `copyFraction = (total != null && total > 0 && used != null) ? min(0.99, used/total) : null` → `onChange`.
- Transition to `loadingDb`: **stop the timer, set `copyFraction = 1.0`** (the snap), emit. Any later phase (`installing`/`done`): `copyFraction = null`.
- `dispose()`: cancel timer. Idempotent.
- `parseDuBytes`/`parseDfUsedBytes` are pure and unit-tested; the `du`/`df` `Process.run` wrappers return null on any failure (never throw) and are manual-VM verified.

- [ ] **Step 1: Write the failing test**

```dart
// common/test/services/install/install_progress_test.dart
import 'dart:async';
import 'package:test/test.dart';
import 'package:common/src/services/install/install_phase.dart';
import 'package:common/src/services/install/install_progress.dart';

void main() {
  group('parse helpers', () {
    test('parseDuBytes reads the leading byte count', () {
      expect(parseDuBytes('12345\t/nix/store\n'), 12345);
      expect(parseDuBytes('nonsense'), isNull);
    });
    test('parseDfUsedBytes reads the value under the "used" header', () {
      expect(parseDfUsedBytes('used\n67890\n'), 67890);
      expect(parseDfUsedBytes(''), isNull);
    });
  });

  group('InstallProgressTracker', () {
    test('phase transitions emit and copy polls rise then snap to 1.0', () async {
      final emissions = <InstallProgress>[];
      var used = 0;
      final tracker = InstallProgressTracker(
        readTotalBytes: () async => 100,
        readUsedBytes: () async => used,
        pollInterval: const Duration(milliseconds: 10),
        onChange: emissions.add,
      );

      tracker.addLine('running sgdisk');           // partitioning
      expect(tracker.value.phase, InstallPhase.partitioning);

      tracker.addLine('Copying store paths');      // -> copying, starts poll
      expect(tracker.value.phase, InstallPhase.copying);

      used = 50;
      await Future.delayed(const Duration(milliseconds: 25));
      expect(tracker.value.copyFraction, closeTo(0.5, 0.001));

      used = 1000; // over total -> clamp
      await Future.delayed(const Duration(milliseconds: 25));
      expect(tracker.value.copyFraction, 0.99);

      tracker.addLine('Loading nix database');     // snap
      expect(tracker.value.phase, InstallPhase.loadingDb);
      expect(tracker.value.copyFraction, 1.0);

      // poll stopped: further used changes don't move the fraction
      used = 0;
      await Future.delayed(const Duration(milliseconds: 25));
      expect(tracker.value.copyFraction, 1.0);

      tracker.addLine('installing the boot loader'); // installing -> no bar
      expect(tracker.value.phase, InstallPhase.installing);
      expect(tracker.value.copyFraction, isNull);

      tracker.dispose();
      expect(emissions, isNotEmpty);
    });

    test('null total keeps the bar hidden during copying', () async {
      final tracker = InstallProgressTracker(
        readTotalBytes: () async => null,
        readUsedBytes: () async => 500,
        pollInterval: const Duration(milliseconds: 10),
        onChange: (_) {},
      );
      tracker.addLine('Copying store paths');
      await Future.delayed(const Duration(milliseconds: 25));
      expect(tracker.value.phase, InstallPhase.copying);
      expect(tracker.value.copyFraction, isNull);
      tracker.dispose();
    });
  });
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cd common && dart test test/services/install/install_progress_test.dart`
Expected: FAIL — `install_progress.dart` missing.

- [ ] **Step 3: Implement**

```dart
// common/lib/src/services/install/install_progress.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../log_service.dart';
import 'install_phase.dart';

/// Snapshot of install progress for the panel.
class InstallProgress {
  final InstallPhase phase;
  final double? copyFraction;
  const InstallProgress({required this.phase, this.copyFraction});

  @override
  bool operator ==(Object other) =>
      other is InstallProgress &&
      other.phase == phase &&
      other.copyFraction == copyFraction;

  @override
  int get hashCode => Object.hash(phase, copyFraction);
}

/// Parse `du -sb <path>` stdout ("<bytes>\t<path>") into bytes.
int? parseDuBytes(String duStdout) {
  final first = duStdout.trim().split(RegExp(r'\s+')).firstOrNull;
  return first == null ? null : int.tryParse(first);
}

/// Parse `df -B1 --output=used <mnt>` stdout ("used\n<bytes>") into bytes.
int? parseDfUsedBytes(String dfStdout) {
  final lines = dfStdout.trim().split('\n');
  if (lines.length < 2) return null;
  return int.tryParse(lines[1].trim());
}

/// Total bytes of the source store (the closure being copied). Null on
/// any failure — the tracker then hides the bar.
Future<int?> duSourceBytes([String path = '/nix/store']) async {
  try {
    final r = await Process.run('du', ['-sb', path]);
    if (r.exitCode != 0) return null;
    return parseDuBytes(r.stdout as String);
  } catch (e) {
    LogService.warn('duSourceBytes failed: $e');
    return null;
  }
}

/// Bytes used on the target mount. Null when the mount is absent or the
/// command fails — the tracker keeps showing a spinner instead.
Future<int?> dfUsedBytes(String mountPoint) async {
  try {
    final r = await Process.run('df', ['-B1', '--output=used', mountPoint]);
    if (r.exitCode != 0) return null;
    return parseDfUsedBytes(r.stdout as String);
  } catch (e) {
    LogService.warn('dfUsedBytes failed: $e');
    return null;
  }
}

/// Drives an [InstallProgress] from disko-install output lines + polled
/// filesystem byte counts. Never throws into the caller; all reader
/// failures degrade to a hidden bar.
class InstallProgressTracker {
  InstallProgressTracker({
    required Future<int?> Function() readTotalBytes,
    required Future<int?> Function() readUsedBytes,
    this.pollInterval = const Duration(seconds: 2),
    required this.onChange,
  })  : _readTotal = readTotalBytes,
        _readUsed = readUsedBytes;

  final Future<int?> Function() _readTotal;
  final Future<int?> Function() _readUsed;
  final Duration pollInterval;
  final void Function(InstallProgress) onChange;

  InstallProgress _value = const InstallProgress(phase: InstallPhase.preparing);
  InstallProgress get value => _value;

  Timer? _pollTimer;
  int? _total;
  bool _totalRequested = false;

  void addLine(String line) {
    final next = installPhaseForLine(line);
    if (next == null || next == _value.phase) return;
    switch (next) {
      case InstallPhase.copying:
        _emit(InstallProgress(phase: next, copyFraction: null));
        _startCopyPoll();
      case InstallPhase.loadingDb:
        _stopCopyPoll();
        _emit(const InstallProgress(phase: InstallPhase.loadingDb, copyFraction: 1.0));
      default:
        _stopCopyPoll();
        _emit(InstallProgress(phase: next, copyFraction: null));
    }
  }

  void _startCopyPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    if (_value.phase != InstallPhase.copying) return;
    if (!_totalRequested) {
      _totalRequested = true;
      _total = await _readTotal();
    }
    final used = await _readUsed();
    if (_value.phase != InstallPhase.copying) return; // phase changed mid-await
    double? frac;
    if (_total != null && _total! > 0 && used != null) {
      frac = math.min(0.99, used / _total!);
    }
    _emit(InstallProgress(phase: InstallPhase.copying, copyFraction: frac));
  }

  void _stopCopyPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _emit(InstallProgress p) {
    if (p == _value) return;
    _value = p;
    onChange(p);
  }

  void dispose() => _stopCopyPoll();
}
```

Add to `common/lib/common.dart`:

```dart
export 'src/services/install/install_phase.dart';
export 'src/services/install/install_progress.dart';
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd common && dart test test/services/install/install_progress_test.dart`
Expected: PASS. Then `just analyze` — no new issues.

- [ ] **Step 5: Commit**

```
feat(common): InstallProgressTracker + du/df byte readers

Consumes disko-install lines into an InstallProgress (phase + copy
fraction); polls df(target)/du(source) during the copy phase, clamps at
0.99, and snaps to 1.0 on the "Loading nix database" marker. Reader
failures degrade to a hidden bar — never blocks the install.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## Task 3: BuildProgressPanel widget

**Files:**

- Create: `tui/lib/src/ui/widgets/build_progress_panel.dart`
- Test: `tui/test/ui/widgets/build_progress_panel_test.dart`

**Interfaces:**

- Consumes: `InstallPhase`, `phaseLabel`, `InstallProgress` (import `package:common/common.dart`).
- Produces: `BuildProgressPanel` (StatelessComponent).

**Design:** source-agnostic (named `Build…`, not `Install…`, for future reuse). Renders: a title, the phase label, a progress bar when `copyFraction != null` else a `Spinner`, elapsed, the last N log lines, and a `[l] log` hint. Bar is a fixed-width `[###--] NN%` string (reuse the codebase's existing bar style if one exists — grep `██` / progress bar; else the ASCII form below). Pure rendering; no timers, no IO.

- [ ] **Step 1: Write the failing test**

```dart
// tui/test/ui/widgets/build_progress_panel_test.dart
import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/nocterm_test.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/widgets/build_progress_panel.dart';

void main() {
  testNocterm('renders a bar with percent while copying', (tester) async {
    await tester.pumpComponent(
      const BuildProgressPanel(
        progress: InstallProgress(phase: InstallPhase.copying, copyFraction: 0.73),
        elapsedSeconds: 252,
        recentLines: ['copying path a', 'copying path b'],
      ),
    );
    expect(tester.terminalState.toString(), contains('Copying NixOS store paths'));
    expect(tester.terminalState.toString(), contains('73%'));
    expect(tester.terminalState.toString(), contains('4m12s'));
  });

  testNocterm('renders a spinner (no bar) when copyFraction is null', (tester) async {
    await tester.pumpComponent(
      const BuildProgressPanel(
        progress: InstallProgress(phase: InstallPhase.installing, copyFraction: null),
        elapsedSeconds: 3,
        recentLines: ['installing the boot loader'],
      ),
    );
    final s = tester.terminalState.toString();
    expect(s, contains('Installing bootloader'));
    expect(s, isNot(contains('%')));
    expect(s, contains('[l]'));
  });
}
```

_(If `testNocterm`/`terminalState` names differ, match the existing widget tests — grep `tui/test` for `testNocterm` / `pumpComponent` and copy that harness exactly.)_

- [ ] **Step 2: Run test, verify it fails**

Run: `cd tui && dart test test/ui/widgets/build_progress_panel_test.dart`
Expected: FAIL — widget missing.

- [ ] **Step 3: Implement**

```dart
// tui/lib/src/ui/widgets/build_progress_panel.dart
import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

import 'spinner.dart';

/// Source-agnostic build/install progress panel: phase label, a copy
/// progress bar (when a fraction is known) or a spinner, elapsed time,
/// and a tail of recent log lines. Pure rendering.
class BuildProgressPanel extends StatelessComponent {
  const BuildProgressPanel({
    super.key,
    required this.progress,
    required this.elapsedSeconds,
    required this.recentLines,
    this.tailCount = 6,
    this.barWidth = 24,
  });

  final InstallProgress progress;
  final int elapsedSeconds;
  final List<String> recentLines;
  final int tailCount;
  final int barWidth;

  static String formatElapsed(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return m > 0 ? '${m}m${sec}s' : '${sec}s';
  }

  String _bar(double f) {
    final filled = (f * barWidth).round().clamp(0, barWidth);
    final pct = (f * 100).round();
    return '[${'#' * filled}${'-' * (barWidth - filled)}] $pct%';
  }

  @override
  Component build(BuildContext context) {
    final frac = progress.copyFraction;
    final tail = recentLines.length <= tailCount
        ? recentLines
        : recentLines.sublist(recentLines.length - tailCount);
    const dim = TextStyle(color: Color.fromRGB(150, 150, 180));
    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Installing NixBlitz',
            style: TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          if (frac != null)
            Text(
              '${phaseLabel(progress.phase)}   ${_bar(frac)}   '
              '${formatElapsed(elapsedSeconds)}',
            )
          else
            Row(
              children: [
                Spinner(label: phaseLabel(progress.phase)),
                Text('   ${formatElapsed(elapsedSeconds)}', style: dim),
              ],
            ),
          const SizedBox(height: 1),
          for (final line in tail) Text(line, style: dim),
          const SizedBox(height: 1),
          const Text('[l] full log', style: dim),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cd tui && dart test test/ui/widgets/build_progress_panel_test.dart`
Expected: PASS. Then `just analyze` — only the 6 pre-existing `implementation_imports` infos may remain.

- [ ] **Step 5: Commit**

```
feat(tui): BuildProgressPanel widget

Source-agnostic panel: phase label + copy progress bar (or spinner) +
elapsed + a log tail + [l] toggle hint. Reused later by the internal-json
rebuild-screen source.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## Task 4: Wire the panel into install_view

**Files:**

- Modify: `tui/lib/src/ui/views/install_view.dart`
- Modify: the install providers file (grep for `installCurrentStepLabelProvider` — likely `tui/lib/src/providers/ui_state_provider.dart`) to add `installProgressProvider`.

**Interfaces:**

- Consumes: `InstallProgressTracker`, `InstallProgress`, `InstallPhase`, `duSourceBytes`, `dfUsedBytes` (from `package:common/common.dart`), `BuildProgressPanel` (Task 3).

**Design:** Reuse the existing single `output.listen` — do NOT re-subscribe (`diskoInstall`'s stream is single-subscription). Inside the existing listener, alongside the current log-append + `parseDiskoStep` label update, call `tracker.addLine(line)`. The tracker's `onChange` writes an `installProgressProvider` (a `StateProvider<InstallProgress>`), which `_buildInstalling` watches to render `BuildProgressPanel`. `[l]` toggles an instance-var `_logOpen` between the panel and the existing `ScrollableLog`. Failure/complete routing, `_elapsedTimer` (drives `_totalSeconds`), and `[r]` retry are unchanged. This is a UI wiring change — **manual-VM verified**, not unit-tested (only the pieces from Tasks 1–3 are).

- [ ] **Step 1: Add the provider**

In the providers file, beside `installCurrentStepLabelProvider`:

```dart
final installProgressProvider = StateProvider<InstallProgress>(
  (ref) => const InstallProgress(phase: InstallPhase.preparing),
);
```

(add `import 'package:common/common.dart';` if not already imported there.)

- [ ] **Step 2: Hold the tracker + toggle in `_InstallViewState`**

Add fields near `_outputSub`:

```dart
  InstallProgressTracker? _tracker;
  bool _logOpen = false;
```

In `dispose()` add `_tracker?.dispose();`.

- [ ] **Step 3: Create + feed the tracker in `_startInstall`**

Immediately before `final (:output, :exitCode) = installService.diskoInstall(...)`, create the tracker:

```dart
      _tracker = InstallProgressTracker(
        readTotalBytes: () => duSourceBytes(),
        readUsedBytes: () => dfUsedBytes('/mnt/disko-install-root'),
        onChange: (p) {
          // Stream-listener context (not a key handler) — provider write is safe.
          context.read(installProgressProvider.notifier).state = p;
        },
      );
```

Inside the existing `output.listen((line) { ... })` body, after the `installLogProvider` append and the `parseDiskoStep` block, add:

```dart
          _tracker?.addLine(line);
```

_(Keep the existing `parseDiskoStep` label block — it drives `installCurrentStepLabelProvider` + `_stepSeconds` reset, which now benefits from the fixed markers automatically.)_

- [ ] **Step 4: Render the panel in `_buildInstalling`**

Locate `_buildInstalling()` (the `InstallStep.installing` branch). Replace its body so it renders `BuildProgressPanel` by default and the full `ScrollableLog` when `_logOpen`, wrapped in a `Focusable` whose `onKeyEvent` (full try/catch) toggles `_logOpen` on `l` and delegates scroll keys to the log when open:

```dart
  Component _buildInstalling() {
    final progress = context.watch(installProgressProvider);
    final log = context.watch(installLogProvider);
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.character?.toLowerCase() == 'l') {
            setState(() => _logOpen = !_logOpen);
            return true;
          }
          return false; // let ScrollableLog handle scroll keys when open
        } catch (e, st) {
          LogService.error('install progress key handler failed', e, st);
          return true;
        }
      },
      child: _logOpen
          ? ScrollableLog(lines: log, focused: true)
          : BuildProgressPanel(
              progress: progress,
              elapsedSeconds: _totalSeconds,
              recentLines: log,
            ),
    );
  }
```

_(If the existing `_buildInstalling` renders extra chrome (a header, the `installCurrentStepLabelProvider` line), preserve whatever the failure/complete screens rely on; the panel replaces the log-rendering portion only. Match the file's actual structure — read `_buildInstalling` before editing.)_

- [ ] **Step 5: Verify + Commit**

Run: `just analyze` (only the 6 pre-existing `tui` infos) and `just format`. `just test` stays green (no unit test covers the view; Tasks 1–3 carry the coverage).
Manual-VM note for the executor's report: the live behaviour (phases advance, bar rises during the cp and snaps at `Loading nix database`, `[l]` toggles the log, failure still routes to `_buildFailed`) is verified on a VM install, not in CI.

```
feat(tui): live progress panel on the install screen

Feeds disko-install output into InstallProgressTracker and renders
BuildProgressPanel (phase + copy bar + elapsed + log tail), with [l] to
reveal the full log. The formerly-silent xargs-cp phase now shows a
rising, df-derived progress bar. Exit-code routing and retry unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## Manual verification (VM — acceptance gate)

The `du`/`df` reader wrappers and the live view can't be unit-tested. On a VM install:

1. `just vm-boot`; run the wizard to the install step on a blank disk.
2. Watch phases advance: partitioning → formatting → **copying (bar rises)** → **loadingDb (bar snaps to 100%)** → installing → complete.
3. Confirm the copy bar actually moves during the previously-silent `cp` (this is the whole point) and elapsed ticks.
4. Press `[l]` → full `ScrollableLog` appears and scrolls; `[l]` again returns to the panel.
5. Force a failure (e.g. eject/ën error) → the failure screen + `[r]` retry still work unchanged.
6. Sanity: `df`/`du` at the 2 s cadence add no perceptible load.

---

## Self-Review

**Spec coverage:** §2.1 phases → Task 1 enum. §2.2 markers → Task 1 `installPhaseForLine` (incl. the two verbatim disko markers). §2.3 copy bar (du-total once, df-target poll, ≤0.99 clamp, snap-to-1.0) → Task 2 tracker. §2.4 panel layout → Task 3. §3 components → all four tasks + exports. §4 data flow → Task 4 wiring (single listener tee via `addLine`, provider write in listener). §5 degradation (reader failure → hidden bar, no throw, timer lifecycle) → Task 2 (`_pollOnce` null-guards, `dispose`) + Task 4 (dispose). §6 testing → Tasks 1–3 unit tests + Manual verification. §7 future (json source) → panel/model built source-agnostic (`Build…` name, `InstallProgress` fed by any source).

**Placeholder scan:** none. The two "match the existing harness/structure" notes (Task 3 test harness names, Task 4 `_buildInstalling` chrome) are explicit "read the real file" instructions with a concrete fallback, not vague hand-waves.

**Type consistency:** `InstallPhase`, `installPhaseForLine`, `phaseLabel`, `InstallProgress{phase,copyFraction}`, `InstallProgressTracker{addLine,dispose,value,onChange,readTotalBytes,readUsedBytes,pollInterval}`, `parseDuBytes`/`parseDfUsedBytes`/`duSourceBytes`/`dfUsedBytes`, `BuildProgressPanel{progress,elapsedSeconds,recentLines}`, `installProgressProvider` — used identically across Tasks 1→4. `phaseLabel` strings match `parseDiskoStep`'s existing outputs for overlapping phases (Task 1 test asserts parity).
