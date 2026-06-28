# SBOM Version Tracking + Look-Ahead Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a git-committed CycloneDX SBOM of the node's system (refreshed + committed each Apply so its diff is the package-version changelog), and use a candidate SBOM during a Check to preview which package versions an update would change.

**Architecture:** A `SbomService` in `common` runs `sbomnix --cdx` (volatile fields stripped), reads CycloneDX components into `name→version`, and diffs two component maps. Apply generates + commits the SBOM from `/run/current-system` after a successful rebuild. The check service, on its substitutable path, diffs a candidate SBOM against the committed one into `CheckResult.sbomChanges`, which the "What's changing…" view renders.

**Tech Stack:** Dart (`common` + `tui`), nocterm; `sbomnix` (nixpkgs) + `jq` via subprocess.

## Global Constraints

- **Single repo** (`/home/f44/dev/blitz/nixblitz`). All tasks main-repo.
- **Commits are the user's.** Do NOT run `jj`/`git commit`. Each task ends by running the verification gate and presenting a ready-to-paste commit message (subject + why-focused body + `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`).
- **Verification gate:** after each task run `just test`, `just analyze`, `just format`; all green. Pre-existing `implementation_imports` infos in `tile_renderer.dart`/`dashboard_view.dart` are not yours unless your change adds new ones.
- **No cross-project references** in any committed doc/code comment — describe techniques generically, never name another repo.
- **`common` is the only package that runs `Process`** (sbomnix/jq live in `SbomService`; `tui` calls the service).
- **Best-effort SBOM work:** sbomnix/jq/git failures log + emit a line and never break Apply or the check — the SBOM is an additive artifact.
- **Committed SBOM path:** `<flakePath>/sbom.cdx.json` (the node's `~/nixblitz` root; Apply's `git add -A` already sweeps it, but the post-rebuild step commits it explicitly).
- **sbomnix invocation:** `nix run nixpkgs#sbomnix -- <closure> --cdx <tmp> --csv /dev/null --spdx /dev/null --impure`, then `jq 'del(.serialNumber) | del(.metadata.timestamp)'` → final file. (`nix run` needs network on first use; nodes have network during a check/apply. Don't bake sbomnix into the node closure — it'd bloat it.)
- **sbomnix runtime is unvalidated on a Pi** — the Process-running paths (generate + Apply/Check wiring) are verified manually on a node, not in CI. Unit tests cover the pure parts (`diffComponents`, `readComponents`, JSON).

---

### Task 1: `SbomChange` model + `CheckResult.sbomChanges` (`common`)

**Files:**

- Create: `common/lib/src/models/sbom_change.dart`
- Modify: `common/lib/src/models/update_status.dart` (add field + JSON)
- Modify: `common/lib/common.dart` (export `sbom_change.dart`)
- Test: `common/test/models/sbom_change_test.dart`

**Interfaces:**

- Produces:
  - `enum SbomChangeKind { added, removed, changed }`
  - `class SbomChange { final String name; final String? from; final String? to; final SbomChangeKind kind; }` with `fromJson`/`toJson`.
  - `CheckResult.sbomChanges` (`List<SbomChange>`, default `const []`), round-tripped in `CheckResult.toJson`/`fromJson` under key `sbom_changes`.

- [ ] **Step 1: Write the failing tests**

Create `common/test/models/sbom_change_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:common/src/models/sbom_change.dart';
import 'package:common/src/models/update_status.dart';

void main() {
  group('SbomChange JSON', () {
    test('round-trips a changed entry', () {
      const c = SbomChange(name: 'foo', from: '1.2', to: '1.3', kind: SbomChangeKind.changed);
      final back = SbomChange.fromJson(c.toJson());
      expect(back.name, 'foo');
      expect(back.from, '1.2');
      expect(back.to, '1.3');
      expect(back.kind, SbomChangeKind.changed);
    });

    test('round-trips added/removed (null sides)', () {
      const added = SbomChange(name: 'bar', from: null, to: '0.9', kind: SbomChangeKind.added);
      const removed = SbomChange(name: 'baz', from: '2.0', to: null, kind: SbomChangeKind.removed);
      expect(SbomChange.fromJson(added.toJson()).kind, SbomChangeKind.added);
      expect(SbomChange.fromJson(added.toJson()).to, '0.9');
      expect(SbomChange.fromJson(removed.toJson()).kind, SbomChangeKind.removed);
      expect(SbomChange.fromJson(removed.toJson()).from, '2.0');
    });
  });

  group('CheckResult.sbomChanges', () {
    test('defaults to empty + round-trips', () {
      final r = CheckResult(
        checkedAt: DateTime(2026, 1, 1),
        ok: true,
        sbomChanges: const [
          SbomChange(name: 'foo', from: '1.2', to: '1.3', kind: SbomChangeKind.changed),
        ],
      );
      expect(
        CheckResult(checkedAt: DateTime(2026, 1, 1), ok: true).sbomChanges,
        isEmpty,
      );
      final back = CheckResult.fromJson(r.toJson());
      expect(back.sbomChanges, hasLength(1));
      expect(back.sbomChanges.first.to, '1.3');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/models/sbom_change_test.dart`
Expected: FAIL — `sbom_change.dart` / `SbomChange` / `sbomChanges` undefined.

- [ ] **Step 3: Implement `SbomChange`**

Create `common/lib/src/models/sbom_change.dart`:

```dart
/// A single package-level difference between two SBOMs.
enum SbomChangeKind { added, removed, changed }

/// One entry in an SBOM diff: a package that was added, removed, or had its
/// version change between two CycloneDX component sets.
class SbomChange {
  final String name;

  /// Version on the "before" side; null for an `added` package.
  final String? from;

  /// Version on the "after" side; null for a `removed` package.
  final String? to;

  final SbomChangeKind kind;

  const SbomChange({
    required this.name,
    required this.from,
    required this.to,
    required this.kind,
  });

  factory SbomChange.fromJson(Map<String, dynamic> j) => SbomChange(
    name: j['name'] as String,
    from: j['from'] as String?,
    to: j['to'] as String?,
    kind: SbomChangeKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => SbomChangeKind.changed,
    ),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    'kind': kind.name,
  };
}
```

- [ ] **Step 4: Add `sbomChanges` to `CheckResult`**

In `common/lib/src/models/update_status.dart`:

Add the import at the top (with the other model imports):

```dart
import 'package:common/src/models/sbom_change.dart';
```

Add the constructor param (after `this.wouldBuild = const [],`):

```dart
    this.sbomChanges = const [],
```

Add the field (after the `wouldBuild` field):

```dart
  /// Package-version changes a candidate (updated) system would bring vs the
  /// committed `sbom.cdx.json`. Populated only on the substitutable check
  /// path; empty otherwise (and when there is no committed SBOM baseline).
  final List<SbomChange> sbomChanges;
```

In `CheckResult.fromJson`, add (parsing the list — mirror `pluginsAhead`):

```dart
        sbomChanges: (j['sbom_changes'] as List<dynamic>? ?? const [])
            .map((e) => SbomChange.fromJson(e as Map<String, dynamic>))
            .toList(),
```

In `CheckResult.toJson`, add (mirror `plugins_ahead`):

```dart
      if (sbomChanges.isNotEmpty)
        'sbom_changes': sbomChanges.map((e) => e.toJson()).toList(),
```

- [ ] **Step 5: Export from the barrel**

In `common/lib/common.dart`, next to the `update_status.dart` export:

```dart
export 'src/models/sbom_change.dart';
```

- [ ] **Step 6: Run tests + gate**

Run: `cd common && dart test test/models/sbom_change_test.dart` → PASS.
Then `just test && just analyze && just format`. Suggested subject:
`feat(sbom): SbomChange model + CheckResult.sbomChanges`

---

### Task 2: `SbomService` (`common`)

**Files:**

- Create: `common/lib/src/services/sbom_service.dart`
- Modify: `common/lib/common.dart` (export)
- Test: `common/test/services/sbom_service_test.dart`

**Interfaces:**

- Consumes: `SbomChange`/`SbomChangeKind` (Task 1).
- Produces:
  - `class SbomService` with:
    - `Future<bool> generate({required String closure, required String outPath})` — sbomnix + jq strip; true on success, false (logged) on any failure. (Process — not unit-tested.)
    - `Map<String, String> readComponents(String path)` — parse CycloneDX `components[]` → `name→version`; `{}` for missing/unparseable/empty.
    - `List<SbomChange> diffComponents(Map<String, String> before, Map<String, String> after)` — pure, sorted by name.

- [ ] **Step 1: Write the failing tests**

Create `common/test/services/sbom_service_test.dart`:

```dart
import 'dart:io';

import 'package:test/test.dart';
import 'package:common/src/models/sbom_change.dart';
import 'package:common/src/services/sbom_service.dart';

void main() {
  final svc = SbomService();

  group('diffComponents', () {
    test('changed / added / removed, sorted by name', () {
      final before = {'foo': '1.2', 'baz': '2.0'};
      final after = {'foo': '1.3', 'bar': '0.9'};
      final changes = svc.diffComponents(before, after);
      expect(changes.map((c) => '${c.name}:${c.kind.name}'), [
        'bar:added',
        'baz:removed',
        'foo:changed',
      ]);
      final foo = changes.firstWhere((c) => c.name == 'foo');
      expect(foo.from, '1.2');
      expect(foo.to, '1.3');
    });

    test('identical maps → no changes', () {
      expect(svc.diffComponents({'a': '1'}, {'a': '1'}), isEmpty);
    });
  });

  group('readComponents', () {
    test('parses CycloneDX components into name→version', () {
      final tmp = File('${Directory.systemTemp.createTempSync('sbom').path}/x.json');
      tmp.writeAsStringSync('''
        {"bomFormat":"CycloneDX","components":[
          {"name":"foo","version":"1.2","purl":"pkg:nix/foo"},
          {"name":"bar","version":"","purl":"pkg:nix/bar"}
        ]}
      ''');
      final m = svc.readComponents(tmp.path);
      expect(m['foo'], '1.2');
      expect(m['bar'], '');
    });

    test('missing file → empty map', () {
      expect(svc.readComponents('/nonexistent/sbom.cdx.json'), isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd common && dart test test/services/sbom_service_test.dart`
Expected: FAIL — `sbom_service.dart` / `SbomService` undefined.

- [ ] **Step 3: Implement `SbomService`**

Create `common/lib/src/services/sbom_service.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/sbom_change.dart';
import 'package:common/src/services/log_service.dart';

/// Generates + reads + diffs CycloneDX SBOMs for the node's system closure.
/// Generation shells out to `sbomnix`; reading/diffing are pure so they unit-
/// test without the tool. See
/// docs/superpowers/specs/2026-06-28-sbom-version-tracking-design.md.
class SbomService {
  const SbomService();

  /// Generate a volatile-stripped CycloneDX SBOM for [closure] (a realized
  /// store path like `/run/current-system`, or a candidate toplevel) into
  /// [outPath]. Best-effort: returns false (logged) on any failure.
  Future<bool> generate({
    required String closure,
    required String outPath,
  }) async {
    final tmp = '$outPath.tmp';
    try {
      final gen = await Process.run('nix', [
        'run',
        'nixpkgs#sbomnix',
        '--',
        closure,
        '--cdx',
        tmp,
        '--csv',
        '/dev/null',
        '--spdx',
        '/dev/null',
        '--impure',
      ]);
      if (gen.exitCode != 0) {
        LogService.warn('sbom: sbomnix exited ${gen.exitCode}: ${gen.stderr}');
        return false;
      }
      // Strip the random serialNumber + generation timestamp so the file only
      // diffs when packages actually change (no per-run churn).
      final strip = await Process.run('jq', [
        'del(.serialNumber) | del(.metadata.timestamp)',
        tmp,
      ]);
      if (strip.exitCode != 0) {
        LogService.warn('sbom: jq strip exited ${strip.exitCode}: ${strip.stderr}');
        return false;
      }
      File(outPath).writeAsStringSync(strip.stdout as String);
      return true;
    } catch (e, st) {
      LogService.error('sbom: generate failed', e, st);
      return false;
    } finally {
      try {
        final t = File(tmp);
        if (t.existsSync()) t.deleteSync();
      } catch (_) {}
    }
  }

  /// Parse a CycloneDX file's `components[]` into `name → version`. Returns an
  /// empty map for a missing / empty / unparseable file (best-effort).
  Map<String, String> readComponents(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return const {};
      final raw = f.readAsStringSync().trim();
      if (raw.isEmpty) return const {};
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final comps = json['components'] as List<dynamic>? ?? const [];
      final out = <String, String>{};
      for (final c in comps) {
        if (c is Map<String, dynamic>) {
          final name = c['name'];
          if (name is String) out[name] = (c['version'] as String?) ?? '';
        }
      }
      return out;
    } catch (e) {
      LogService.warn('sbom: readComponents($path) failed: $e');
      return const {};
    }
  }

  /// Diff two component maps → added / removed / changed, sorted by name.
  List<SbomChange> diffComponents(
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final names = {...before.keys, ...after.keys}.toList()..sort();
    final out = <SbomChange>[];
    for (final name in names) {
      final b = before[name];
      final a = after[name];
      if (b == null && a != null) {
        out.add(SbomChange(name: name, from: null, to: a, kind: SbomChangeKind.added));
      } else if (b != null && a == null) {
        out.add(SbomChange(name: name, from: b, to: null, kind: SbomChangeKind.removed));
      } else if (b != null && a != null && b != a) {
        out.add(SbomChange(name: name, from: b, to: a, kind: SbomChangeKind.changed));
      }
    }
    return out;
  }
}
```

- [ ] **Step 4: Export from the barrel**

In `common/lib/common.dart`, with the other service exports:

```dart
export 'src/services/sbom_service.dart';
```

- [ ] **Step 5: Run tests + gate**

Run: `cd common && dart test test/services/sbom_service_test.dart` → PASS.
Then `just test && just analyze && just format`. Suggested subject:
`feat(sbom): SbomService — generate / read / diff CycloneDX closures`

---

### Task 3: Apply commits the node SBOM after a successful rebuild (`tui`)

**Files:**

- Modify: `tui/lib/src/ui/views/apply_view.dart` (the `if (code == 0)` branch in `_continueApply`)

**Interfaces:**

- Consumes: `SbomService` (via `package:common/common.dart`, already imported), `GitService.commit(String filePath, String message)`, the existing `git`, `baseDirPath`, `_append`.

No automated test (Process + nocterm); covered by Task 1/2 unit tests + manual on a node.

- [ ] **Step 1: Generate + commit the SBOM on rebuild success**

In `_continueApply`, the rebuild result handler has `exitCode.then((code) async { … if (code == 0) { … } })`. At the **start of the `if (code == 0)` block** (before the existing post-success work), insert:

```dart
                          // Refresh the committed SBOM from the now-live system
                          // so its git diff records this Apply's package-version
                          // delta. Best-effort — never undoes a successful Apply.
                          _append('');
                          _append('> updating SBOM…');
                          try {
                            final ok = await const SbomService().generate(
                              closure: '/run/current-system',
                              outPath: '$baseDirPath/sbom.cdx.json',
                            );
                            if (ok) {
                              final committed = await git.commit(
                                'sbom.cdx.json',
                                'Update SBOM',
                              );
                              _append(
                                committed
                                    ? '  SBOM updated.'
                                    : '  SBOM unchanged.',
                              );
                            } else {
                              _append('  ! SBOM generation failed — skipped');
                            }
                          } catch (e, st) {
                            LogService.error('apply: SBOM update failed', e, st);
                            _append('  ! SBOM update failed: $e — skipped');
                          }
```

(`git.commit(filePath, message)` commits just that path and returns false when there's nothing to commit — i.e. no package change. `LogService` + `SbomService` resolve from `package:common/common.dart`.)

- [ ] **Step 2: Analyze + format + test**

Run: `just analyze` (no NEW issues in apply_view.dart) ; `just format` ; `just test` (all pass).

- [ ] **Step 3: Self-check + commit message**

Confirm by reading: the SBOM step is inside `if (code == 0)`, runs before the other success work, and every failure path emits a line + continues (the rebuild already succeeded). Suggested subject:
`feat(apply): commit a refreshed SBOM after each successful rebuild`

---

### Task 4: Check computes the look-ahead SBOM diff (`common`)

**Files:**

- Modify: `common/lib/src/services/update_check_service.dart` (the substitute-only path + `_persist`)

**Interfaces:**

- Consumes: `SbomService` (generate + readComponents + diffComponents), `SbomChange`, the existing `flakePath`, the realized candidate toplevel store path (`newTop`).
- Produces: `CheckResult.sbomChanges` populated on the substitutable path.

No new automated test (Process); the diff/read logic it calls is unit-tested in Task 2.

- [ ] **Step 1: Generate the candidate SBOM + diff vs the committed one**

In `update_check_service.dart`, the substitute-only path realizes the toplevel into `newTop`, then (when changed) runs `nvd diff`, then `_persist(...)`. In the branch that produces a diff (around the `writeNvdDiff` / `_persist(... diffText: diff)` lines), compute the SBOM look-ahead just before the `_persist` call:

```dart
        // Look-ahead: diff a candidate SBOM (the realized new toplevel) against
        // the committed one so the operator previews package-version changes.
        // Skipped (empty) when there's no committed baseline yet. Best-effort.
        var sbomChanges = const <SbomChange>[];
        final committedSbom = '$flakePath/sbom.cdx.json';
        if (File(committedSbom).existsSync()) {
          final sbom = const SbomService();
          final candTmp =
              '${Directory.systemTemp.createTempSync('sbom-check').path}/cand.cdx.json';
          final ok = await sbom.generate(closure: newTop, outPath: candTmp);
          if (ok) {
            sbomChanges = sbom.diffComponents(
              sbom.readComponents(committedSbom),
              sbom.readComponents(candTmp),
            );
          }
        }
```

Then pass it through: change the `_persist(now, probe, ok: true, diffText: diff)` call to
`_persist(now, probe, ok: true, diffText: diff, sbomChanges: sbomChanges)`.

Add the imports if absent: `import 'dart:io';` (likely already present) and the `SbomService`/`SbomChange` come from the existing `package:common/...` imports — add explicit imports if the file imports models individually:

```dart
import 'package:common/src/models/sbom_change.dart';
import 'package:common/src/services/sbom_service.dart';
```

- [ ] **Step 2: Thread `sbomChanges` through `_persist`**

Add an optional param to `_persist` and forward it to the `CheckResult`:

```dart
  Future<CheckResult> _persist(
    DateTime now,
    /* existing params … */ {
    /* existing optional params … */
    List<SbomChange> sbomChanges = const [],
  }) async {
    // … existing body …
    final result = CheckResult(
      // … existing args …
      sbomChanges: sbomChanges,
    );
    // … existing persist/write …
  }
```

(Match the real `_persist` signature; only the new `sbomChanges` param + passing it into the `CheckResult` constructor are added. The other `_persist` call sites — compile-needed, noChanges, error — keep the default empty.)

- [ ] **Step 3: Analyze + format + test**

Run: `just analyze` (no NEW issues) ; `just format` ; `just test` (all pass — no regressions; the SBOM logic is unit-tested in Task 2).

- [ ] **Step 4: Self-check + commit message**

Confirm by reading: `sbomChanges` is computed only on the diff-producing (substitutable) path, gated on a committed baseline existing, best-effort, and forwarded into `CheckResult`; the other `_persist` paths default to empty. Suggested subject:
`feat(check): look-ahead SBOM package-version diff into CheckResult`

---

### Task 5: "Package versions" section in "What's changing…" (`tui`)

**Files:**

- Modify: `tui/lib/src/ui/widgets/cached_package_diff.dart`

**Interfaces:**

- Consumes: `CheckResult.sbomChanges` (`List<SbomChange>`), `SbomChangeKind`.

No automated test (nocterm); covered by manual.

- [ ] **Step 1: Render the SBOM changes as a section**

In `cached_package_diff.dart`, in the combined-body builder, add a "Package versions" section BEFORE the existing "Package changes" (nvd) section. After the "Builds on the node" block and before the `final diff = …` block, insert:

```dart
    final sbom = result?.sbomChanges ?? const <SbomChange>[];
    if (sbom.isNotEmpty) {
      lines.add('Package versions (${sbom.length})');
      for (final c in sbom) {
        switch (c.kind) {
          case SbomChangeKind.changed:
            lines.add('  ${c.name}  ${c.from} → ${c.to}');
          case SbomChangeKind.added:
            lines.add('  + ${c.name} ${c.to ?? ''}'.trimRight());
          case SbomChangeKind.removed:
            lines.add('  - ${c.name}');
        }
      }
      lines.add('');
    }
```

`SbomChange`/`SbomChangeKind` come from `package:common/common.dart` (already imported). The "Package versions" header and `+`/`-` lines fall through `nvdLineColor` to the default colour (they don't start with `[U]/[A]/[R]/Closure`), which is fine.

Also include `sbomChanges` in the details-available gate already used upstream: the Updates panel's `What's changing…` action keys off `hasCachedDiff || hasCachedWouldBuild`. To make the section reachable when ONLY SBOM changes exist, in `system_view.dart` the `hasCachedDiff` computation (`_hasCachedPackageDiff(status)`) — extend the System view's `hasCachedDiff` OR the action gate to also be true when `r?.sbomChanges.isNotEmpty == true`. Concretely, in `system_view.dart` where `hasCachedWouldBuild` is computed (`final hasCachedWouldBuild = r?.compileNeeded ?? false;`), add next to it:

```dart
    final hasSbomChanges = r?.sbomChanges.isNotEmpty ?? false;
```

and change the action/hotkey gate `hasCachedDiff || hasCachedWouldBuild` to `hasCachedDiff || hasCachedWouldBuild || hasSbomChanges` (both the `if (hasCachedDiff || hasCachedWouldBuild)` action guard and the `[v]` hotkey guard).

- [ ] **Step 2: Analyze + format + test**

Run: `just analyze` (no NEW issues in the two files) ; `just format` ; `just test`.

- [ ] **Step 3: Self-check + commit message**

Confirm by reading: the "Package versions" section renders from `sbomChanges` above the nvd section, only when non-empty; the `What's changing…` action + `[v]` hotkey are reachable when only SBOM changes exist. Suggested subject:
`feat(updates): show look-ahead package versions in "What's changing"`

---

## Self-Review

**Spec coverage:**

- `SbomService` generate/read/diff → Task 2. ✓
- Committed `~/nixblitz/sbom.cdx.json`, refreshed + committed post-rebuild ("Update SBOM") → Task 3. ✓
- Look-ahead candidate diff on the substitutable check path → CheckResult.sbomChanges → Task 4. ✓
- "Package versions" section in "What's changing…" → Task 5. ✓
- Volatile-field strip (no-churn) → Task 2 `generate`. ✓
- First-baseline noise suppressed (no committed SBOM → empty look-ahead) → Task 4 (gated on `File(committedSbom).existsSync()`). ✓
- Best-effort everywhere → Tasks 2/3/4 (try/catch + logged false returns). ✓
- No CVE / central CI → not in any task. ✓
- Unit tests for diff/read/JSON; Process + wiring manual → Tasks 1/2 tests + the "manual on a node" notes. ✓

**Placeholder scan:** Task 4 references "the real `_persist` signature / existing params" rather than reproducing the whole method — deliberate (only the additive `sbomChanges` param + its forward into `CheckResult` change; the surrounding body is read in-file). All new code blocks are concrete.

**Type consistency:** `SbomChange{name, from?, to?, kind}` + `SbomChangeKind{added,removed,changed}` (Task 1) are used identically in Tasks 2/4/5. `SbomService.generate({closure, outPath})`/`readComponents(path)`/`diffComponents(before, after)` (Task 2) are called with matching signatures in Tasks 3/4. `CheckResult.sbomChanges` (Task 1) is written in Task 4, read in Task 5. `GitService.commit(filePath, message)` matches the real signature.
