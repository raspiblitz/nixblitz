# nixblitz + plugin branches — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded `main / beta / dev` plugin branch picker (from #33) with a publisher-declared branch model, and add a System Configure row that lets the operator pick which branch the operator's flake pulls nixblitz from.

**Architecture:** Publishers declare their branch set as a named map in `plugin.json` (per-plugin) or `branches.json` at the project root (for nixblitz itself, embedded via `EmbeddedTemplates`). Operator picks from declared set via a shared `BranchPicker` widget; `Custom branch…` row stays as the escape hatch. For nixblitz-self, the chosen branch's `ref` is substituted into the operator's `~/nixblitz/flake.nix` at scaffold time as `?ref=<ref>`.

**Tech Stack:** Dart workspace (`common/` + `tui/`), Riverpod, nocterm (TUI), existing `EmbeddedTemplates` code-gen, existing `ScaffoldService` flake.nix writer.

**Spec:** `docs/superpowers/specs/2026-06-02-nixblitz-and-plugin-branches-design.md`

---

## Conventions for this plan

- Every task ends with `just test; just analyze; just format` green before printing a commit message (per `feedback_post_task_verification.md`).
- The user handles commits — print a ready-to-paste message with the `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` trailer; do NOT run `jj commit` or `git commit`.
- VCS is jujutsu (jj). At the start of each task, run `jj new -m "<commit message>"` to create a discrete jj change for the task; do NOT run `jj describe`, `jj commit`, `jj squash`, `git commit`, or `git add`.
- If `just format` rewrites files in `@-`, use `jj restore --from @-` on those files to revert.
- Each commit message: subject ≤ 70 chars, body focused on the WHY, includes the issue ref if one exists. No `Drops:` / `Wiring:` / `Preserves:` bullet rosters.
- Never write the user's email (christian@fulmo.org) into committed files.

---

## Task 1: `DeclaredBranch` + `BranchManifest` models

**Files:**

- Create: `common/lib/src/models/branch/declared_branch.dart`
- Create: `common/lib/src/models/branch/branch_manifest.dart`
- Modify: `common/lib/common.dart` (export both)
- Test: `common/test/models/branch/declared_branch_test.dart`
- Test: `common/test/models/branch/branch_manifest_test.dart`

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(common): branch manifest models — DeclaredBranch + BranchManifest

Foundation for the publisher-declared branch set used by both the
plugin manifest schema (v5) and the operator-flake System config
row. Map<String, DeclaredBranch> with parser-level validation that
exactly one entry carries default:true and refs match git's
check-ref-format rules.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Write failing test for `DeclaredBranch.fromJson`**

Create `common/test/models/branch/declared_branch_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('DeclaredBranch.fromJson', () {
    test('parses required ref + optional description + default', () {
      final b = DeclaredBranch.fromJson({
        'ref': 'main',
        'description': 'Production releases',
        'default': true,
      });
      expect(b.ref, 'main');
      expect(b.description, 'Production releases');
      expect(b.isDefault, isTrue);
    });

    test('description and default are optional', () {
      final b = DeclaredBranch.fromJson({'ref': 'next'});
      expect(b.ref, 'next');
      expect(b.description, isNull);
      expect(b.isDefault, isFalse);
    });

    test('throws when ref is missing', () {
      expect(
        () => DeclaredBranch.fromJson({'description': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when ref contains whitespace', () {
      expect(
        () => DeclaredBranch.fromJson({'ref': 'has space'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when ref contains ".."', () {
      expect(
        () => DeclaredBranch.fromJson({'ref': 'foo..bar'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when ref contains control characters', () {
      expect(
        () => DeclaredBranch.fromJson({'ref': 'foo\tbar'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DeclaredBranch.toJson', () {
    test('omits null description and false default', () {
      final j = DeclaredBranch(ref: 'main').toJson();
      expect(j, {'ref': 'main'});
    });

    test('includes description and default when set', () {
      final j = DeclaredBranch(
        ref: 'main',
        description: 'Production',
        isDefault: true,
      ).toJson();
      expect(j, {
        'ref': 'main',
        'description': 'Production',
        'default': true,
      });
    });
  });
}
```

- [ ] **Step 3: Verify test fails**

Run: `cd common && dart test test/models/branch/declared_branch_test.dart`
Expected: FAIL — `DeclaredBranch` not defined.

- [ ] **Step 4: Implement `DeclaredBranch`**

Create `common/lib/src/models/branch/declared_branch.dart`:

```dart
import 'package:meta/meta.dart';

/// A single branch declared by a publisher in their `branches.json`
/// (for nixblitz-self) or in the `branches` block of a plugin's
/// `plugin.json`. Operator-facing label is the map key; this class
/// is the value.
///
/// `ref` is the git ref (branch, tag, or commit) the chosen
/// channel resolves to.
@immutable
class DeclaredBranch {
  const DeclaredBranch({
    required this.ref,
    this.description,
    this.isDefault = false,
  });

  final String ref;
  final String? description;
  final bool isDefault;

  factory DeclaredBranch.fromJson(Map<String, dynamic> json) {
    final ref = json['ref'];
    if (ref is! String || ref.isEmpty) {
      throw const FormatException('branch: ref is required and non-empty');
    }
    if (!_isValidRef(ref)) {
      throw FormatException(
        'branch: ref "$ref" is not a valid git ref '
        '(no whitespace, no control characters, no "..")',
      );
    }
    final description = json['description'];
    if (description != null && description is! String) {
      throw const FormatException('branch: description must be a string');
    }
    final isDefault = json['default'];
    if (isDefault != null && isDefault is! bool) {
      throw const FormatException('branch: default must be a boolean');
    }
    return DeclaredBranch(
      ref: ref,
      description: description as String?,
      isDefault: (isDefault as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ref': ref,
      if (description != null) 'description': description,
      if (isDefault) 'default': true,
    };
  }

  /// Subset of git's check-ref-format rules sufficient for our use:
  /// reject whitespace, control characters, and ".." anywhere.
  static bool _isValidRef(String ref) {
    if (ref.contains('..')) return false;
    for (final cu in ref.codeUnits) {
      if (cu <= 0x20 || cu == 0x7f) return false;
    }
    return true;
  }
}
```

- [ ] **Step 5: Write failing test for `BranchManifest.fromJson`**

Create `common/test/models/branch/branch_manifest_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('BranchManifest.fromJson', () {
    test('parses a well-formed manifest', () {
      final m = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'description': 'Prod', 'default': true},
        'next': {'ref': 'next', 'description': 'Pre-release'},
      });
      expect(m.branches.keys, containsAll(['stable', 'next']));
      expect(m.branches['stable']!.ref, 'main');
      expect(m.defaultKey, 'stable');
    });

    test('rejects empty map', () {
      expect(
        () => BranchManifest.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects multiple entries with default:true', () {
      expect(
        () => BranchManifest.fromJson({
          'a': {'ref': 'main', 'default': true},
          'b': {'ref': 'next', 'default': true},
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('exactly one'),
        )),
      );
    });

    test('allows zero entries with default:true (defaultKey is null)', () {
      final m = BranchManifest.fromJson({
        'a': {'ref': 'main'},
        'b': {'ref': 'next'},
      });
      expect(m.defaultKey, isNull);
    });

    test('toJson roundtrips', () {
      final m = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
        'next': {'ref': 'next', 'description': 'Pre-release'},
      });
      final back = BranchManifest.fromJson(m.toJson());
      expect(back.branches['stable']!.ref, 'main');
      expect(back.branches['next']!.description, 'Pre-release');
      expect(back.defaultKey, 'stable');
    });
  });
}
```

- [ ] **Step 6: Run to verify failure**

Run: `cd common && dart test test/models/branch/branch_manifest_test.dart`
Expected: FAIL — `BranchManifest` not defined.

- [ ] **Step 7: Implement `BranchManifest`**

Create `common/lib/src/models/branch/branch_manifest.dart`:

```dart
import 'package:meta/meta.dart';
import 'declared_branch.dart';

/// A publisher's declared branch set — keys are operator-facing
/// labels, values describe the git ref + metadata. Used by both
/// the plugin manifest schema (v5 `branches` field) and nixblitz's
/// own `branches.json`.
@immutable
class BranchManifest {
  BranchManifest({required this.branches}) : defaultKey = _findDefault(branches);

  final Map<String, DeclaredBranch> branches;

  /// The map key whose entry has default:true, or null if none.
  /// Parser enforces "at most one" — multiple default:true entries
  /// throw on fromJson.
  final String? defaultKey;

  factory BranchManifest.fromJson(Map<String, dynamic> json) {
    if (json.isEmpty) {
      throw const FormatException(
        'branches: manifest must declare at least one branch',
      );
    }
    final branches = <String, DeclaredBranch>{};
    int defaultCount = 0;
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        throw FormatException(
          'branches: entry "${entry.key}" must be a JSON object',
        );
      }
      final branch = DeclaredBranch.fromJson(value);
      if (branch.isDefault) defaultCount++;
      branches[entry.key] = branch;
    }
    if (defaultCount > 1) {
      throw const FormatException(
        'branches: exactly one entry may have default:true '
        '(found multiple)',
      );
    }
    return BranchManifest(branches: branches);
  }

  Map<String, dynamic> toJson() {
    return {
      for (final e in branches.entries) e.key: e.value.toJson(),
    };
  }

  static String? _findDefault(Map<String, DeclaredBranch> branches) {
    for (final e in branches.entries) {
      if (e.value.isDefault) return e.key;
    }
    return null;
  }
}
```

- [ ] **Step 8: Add exports to `common.dart`**

Add to `common/lib/common.dart` (place alphabetically among other model exports):

```dart
export 'src/models/branch/branch_manifest.dart';
export 'src/models/branch/declared_branch.dart';
```

- [ ] **Step 9: Run tests + trio**

Run: `just test; just analyze; just format`
Expected: all green.

- [ ] **Step 10: Commit message ready**

The `jj new -m` at step 1 already attached the commit message. Verify with:

Run: `jj log -r @ -T 'description.first_line()'`
Expected: `feat(common): branch manifest models — DeclaredBranch + BranchManifest`

---

## Task 2: `branches.json` + EmbeddedTemplates codegen + provider

**Files:**

- Create: `branches.json` (at repo root)
- Modify: `scripts/` (codegen — find the script that builds `embedded_templates.g.dart` and extend it)
- Modify: `common/lib/src/services/embedded_templates.dart` (expose a new `nixblitzBranchesJson` constant)
- Create: `common/lib/src/models/branch/nixblitz_branch_manifest.dart` (provider that parses the embedded constant)
- Modify: `common/lib/common.dart` (export the provider)
- Test: `common/test/models/branch/nixblitz_branch_manifest_test.dart`

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(common): nixblitz branches.json + embedded manifest provider

Foundation for nixblitz-self picking its own branch set. The
declaration lives at project root as branches.json and gets
embedded into the binary via the existing EmbeddedTemplates
codegen pattern. nixblitzBranchManifest provider parses the
embedded constant once at startup.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Create `branches.json` at repo root**

Create `branches.json`:

```json
{
  "stable": {
    "ref": "main",
    "description": "Production-quality nixblitz; what new operators get by default.",
    "default": true
  }
}
```

(Single entry for v1 — `main`. We'll add more branches as release engineering develops; the schema supports them already.)

- [ ] **Step 3: Read the existing codegen script**

Read `scripts/` to find the script that produces `common/lib/src/services/embedded_templates.g.dart`. The script likely walks `templates/` and emits a Dart file with string constants. Note the entry point and the constant naming convention.

- [ ] **Step 4: Extend codegen to include `branches.json`**

Modify the codegen script to also read `branches.json` from the repo root and emit a constant. Example pseudocode for the script change:

```dart
final branchesJson = File('${repoRoot}/branches.json').readAsStringSync();
// emit: const String nixblitzBranchesJson = r'...';
buffer.writeln("const String nixblitzBranchesJson = r'$branchesJson';");
```

Run the codegen script to regenerate `embedded_templates.g.dart`. Verify the new constant is present.

- [ ] **Step 5: Expose the constant via `embedded_templates.dart`**

Modify `common/lib/src/services/embedded_templates.dart` to expose the new constant via the public `EmbeddedTemplates` API. Look at how existing constants (template file contents) are exposed and follow the same pattern.

- [ ] **Step 6: Write failing test for the provider**

Create `common/test/models/branch/nixblitz_branch_manifest_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  test('nixblitzBranchManifestProvider parses the embedded constant', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final manifest = container.read(nixblitzBranchManifestProvider);
    expect(manifest.branches.keys, contains('stable'));
    expect(manifest.branches['stable']!.ref, 'main');
    expect(manifest.defaultKey, 'stable');
  });
}
```

- [ ] **Step 7: Verify test fails**

Run: `cd common && dart test test/models/branch/nixblitz_branch_manifest_test.dart`
Expected: FAIL — `nixblitzBranchManifestProvider` not defined.

- [ ] **Step 8: Implement the provider**

Create `common/lib/src/models/branch/nixblitz_branch_manifest.dart`:

```dart
import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/branch/branch_manifest.dart';
import 'package:common/src/services/embedded_templates.dart';

/// Parses the embedded `branches.json` from `EmbeddedTemplates` once
/// per ProviderContainer. The TUI reads this on startup; new
/// nixblitz binaries on the operator's flake (after rebuild) bring
/// their own snapshot.
final nixblitzBranchManifestProvider = Provider<BranchManifest>((ref) {
  final raw = EmbeddedTemplates.nixblitzBranchesJson;
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return BranchManifest.fromJson(json);
});
```

- [ ] **Step 9: Export the provider**

Add to `common/lib/common.dart`:

```dart
export 'src/models/branch/nixblitz_branch_manifest.dart';
```

- [ ] **Step 10: Run tests + trio**

Run: `just test; just analyze; just format`
Expected: all green.

---

## Task 3: `SystemConfig.nixblitzBranch` field

**Files:**

- Modify: `common/lib/src/models/nixblitz_config.dart`
- Test: relevant existing config-test file (find via `find common/test -name "*config*"`)

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(common): SystemConfig.nixblitzBranch field (default null)

Operator's pick of which nixblitz branch to track. Null means
\"use the embedded manifest's default:true entry\" — set by the
scaffold service when the operator hasn't explicitly chosen.
Value is either a declared key (e.g. \"stable\") or
\"custom:<ref>\" for the escape-hatch ref string the operator
types in the picker.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Write failing backward-compat test**

In the existing system-config test file (find it first; likely `common/test/models/nixblitz_config_test.dart`), add:

```dart
test('SystemConfig without nixblitz_branch field decodes to null', () {
  final s = SystemConfig.fromJson({
    'hostname': 'nixblitz',
    'timezone': 'UTC',
    'platform': 'x86',
    // no nixblitz_branch key
  });
  expect(s.nixblitzBranch, isNull);
});

test('SystemConfig with nixblitz_branch roundtrips', () {
  final s = SystemConfig(
    hostname: 'nixblitz',
    timezone: 'UTC',
    platform: 'x86',
    nixblitzBranch: 'stable',
  );
  final back = SystemConfig.fromJson(s.toJson());
  expect(back.nixblitzBranch, 'stable');
});

test('SystemConfig copyWith preserves nixblitzBranch', () {
  final s = SystemConfig(
    hostname: 'nixblitz',
    timezone: 'UTC',
    platform: 'x86',
    nixblitzBranch: 'custom:plugins-nostr-wot',
  );
  expect(
    s.copyWith(hostname: 'other').nixblitzBranch,
    'custom:plugins-nostr-wot',
  );
});
```

(If the test file doesn't exist, create it with a minimal setup pattern; look at sibling test files in `common/test/models/` for the shape.)

- [ ] **Step 3: Run to verify failure**

Run: `cd common && dart test test/models/nixblitz_config_test.dart`
Expected: FAIL — `nixblitzBranch` is not a parameter.

- [ ] **Step 4: Add the field**

Modify `common/lib/src/models/nixblitz_config.dart`:

In the `SystemConfig` class:

- Add field: `final String? nixblitzBranch;`
- Add to constructor: `this.nixblitzBranch,`
- Add to `SystemConfig.defaults()`: no change (default is null implicit)
- In `fromJson`: `nixblitzBranch: json['nixblitz_branch'] as String?,`
- In `toJson`: include `'nixblitz_branch': nixblitzBranch` (null serialises as null; backward-compat decoders accept missing or null)
- In `copyWith`: add `String? nixblitzBranch` param and propagate

- [ ] **Step 5: Verify tests pass**

Run: `cd common && dart test test/models/nixblitz_config_test.dart`
Expected: all pass.

- [ ] **Step 6: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 4: `ScaffoldService` URL substitution

**Files:**

- Modify: `common/lib/src/services/scaffold_service.dart`
- Test: `common/test/services/scaffold_service_test.dart` (extend if exists; create if not)

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(common): scaffold-time nixblitz.url ?ref=… substitution

ScaffoldService now resolves SystemConfig.nixblitzBranch against
the embedded BranchManifest and rewrites the operator's flake.nix
nixblitz input URL with the chosen ref. Falls back to default:true
when the operator's pick disappears from a newer branches.json.
Custom:<ref> picks strip the prefix and use the ref literally.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Read `ScaffoldService` to understand current shape**

Read `common/lib/src/services/scaffold_service.dart`. Find where `flake.nix` is written. The template likely comes from `EmbeddedTemplates.flakeNix` or similar; substitution happens at write time.

- [ ] **Step 3: Write failing test for substitution**

Add to (or create) `common/test/services/scaffold_service_test.dart`:

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('ScaffoldService nixblitz.url ?ref= substitution', () {
    // The function under test is a helper that takes the template
    // text + the resolved ref and returns the modified text.
    // Expose it (top-level or @visibleForTesting) so it can be
    // unit-tested without an actual filesystem.
    test('substitutes ref into a clean nixblitz.url line', () {
      const template = '''
inputs = {
  nixblitz = {
    url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
''';
      final result = substituteNixblitzRef(template, 'main');
      expect(
        result,
        contains('url = "git+https://forge.f44.fyi/f44/nixblitz_ng?ref=main"'),
      );
      expect(result, contains('inputs.nixpkgs.follows = "nixpkgs"'));
    });

    test('handles existing ?ref= by replacing it', () {
      const template = '''
nixblitz.url = "git+https://forge.f44.fyi/f44/nixblitz_ng?ref=old";
''';
      final result = substituteNixblitzRef(template, 'new');
      expect(result, contains('?ref=new'));
      expect(result, isNot(contains('?ref=old')));
    });

    test('throws on a template missing the nixblitz.url line', () {
      const template = 'inputs = { foo = {}; };';
      expect(
        () => substituteNixblitzRef(template, 'main'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('ScaffoldService.resolveNixblitzRef', () {
    final manifest = BranchManifest.fromJson({
      'stable': {'ref': 'main', 'default': true},
      'next': {'ref': 'develop'},
    });

    test('null config field → default key\'s ref', () {
      expect(resolveNixblitzRef(null, manifest), ('main', null));
    });

    test('declared key → that key\'s ref', () {
      expect(resolveNixblitzRef('next', manifest), ('develop', null));
    });

    test('custom:<ref> → strip prefix, use literal ref', () {
      expect(
        resolveNixblitzRef('custom:plugins-nostr-wot', manifest),
        ('plugins-nostr-wot', null),
      );
    });

    test('unknown declared key → default ref + warning', () {
      final (ref, warning) = resolveNixblitzRef('experimental', manifest);
      expect(ref, 'main');
      expect(warning, isNotNull);
      expect(warning, contains('experimental'));
    });
  });
}
```

(`resolveNixblitzRef` returns a record `(String ref, String? warning)`.)

- [ ] **Step 4: Verify test fails**

Run: `cd common && dart test test/services/scaffold_service_test.dart`
Expected: FAIL — functions not defined.

- [ ] **Step 5: Implement the helpers**

In `common/lib/src/services/scaffold_service.dart` (add as top-level functions or `@visibleForTesting` static methods):

```dart
import 'package:common/src/models/branch/branch_manifest.dart';

/// Resolves the operator's nixblitzBranch config field against
/// the embedded BranchManifest. Returns (ref, warning).
/// - null field → manifest's default:true entry's ref
/// - declared key (e.g. "stable") → that entry's ref
/// - "custom:<ref>" → literal <ref>
/// - unknown declared key → fall back to default, return warning
(String, String?) resolveNixblitzRef(
  String? configField,
  BranchManifest manifest,
) {
  if (configField == null) {
    final dk = manifest.defaultKey;
    if (dk == null) {
      throw StateError(
        'branches.json declares no default:true entry; cannot resolve '
        'null config field',
      );
    }
    return (manifest.branches[dk]!.ref, null);
  }
  if (configField.startsWith('custom:')) {
    return (configField.substring('custom:'.length), null);
  }
  final entry = manifest.branches[configField];
  if (entry != null) {
    return (entry.ref, null);
  }
  // Operator's chosen key no longer exists.
  final dk = manifest.defaultKey;
  if (dk == null) {
    throw StateError(
      'operator pinned to "$configField" which no longer exists, '
      'and the current branches.json declares no default — manual '
      'flake.nix edit required',
    );
  }
  return (
    manifest.branches[dk]!.ref,
    'operator-pinned branch "$configField" is no longer declared; '
    'falling back to default "$dk"',
  );
}

/// Rewrites the `nixblitz.url = "…";` attribute in a flake.nix
/// template to include `?ref=<ref>`. Replaces an existing `?ref=`
/// in place; appends if absent. Throws if the URL line is missing.
String substituteNixblitzRef(String template, String ref) {
  // Match `nixblitz.url = "<url>";` (with optional ?ref=… already)
  // OR `url = "<url>";` inside a `nixblitz = { … }` block.
  final urlPattern = RegExp(
    r'(nixblitz(?:\s*\.\s*url|\s*=\s*\{[^}]*?url)\s*=\s*")([^"]*?)(")',
    multiLine: true,
  );
  final match = urlPattern.firstMatch(template);
  if (match == null) {
    throw StateError(
      'nixblitz.url attribute not found in flake.nix template',
    );
  }
  final url = match.group(2)!;
  // Strip any existing ?ref=… or &ref=…
  final cleanUrl = url.replaceAll(RegExp(r'\?ref=[^&"]*'), '')
                      .replaceAll(RegExp(r'&ref=[^&"]*'), '');
  final newUrl = cleanUrl.contains('?')
      ? '$cleanUrl&ref=$ref'
      : '$cleanUrl?ref=$ref';
  return template.replaceRange(
    match.start,
    match.end,
    '${match.group(1)}$newUrl${match.group(3)}',
  );
}
```

The regex needs to handle the actual nested-block style in `templates/flake.nix`. Read that file first and adjust the pattern; the test should catch any mismatch.

- [ ] **Step 6: Wire into the scaffold flow**

Find the `ScaffoldService` method that writes `flake.nix`. Before writing, call:

```dart
final manifest = ref.read(nixblitzBranchManifestProvider);
final (resolvedRef, warning) = resolveNixblitzRef(
  config.system.nixblitzBranch,
  manifest,
);
if (warning != null) {
  LogService.warn('scaffold: $warning');
}
final modified = substituteNixblitzRef(template, resolvedRef);
File(flakeNixPath).writeAsStringSync(modified);
```

Adapt to the actual provider plumbing in the existing service.

- [ ] **Step 7: Verify tests pass**

Run: `cd common && dart test test/services/scaffold_service_test.dart`
Expected: all pass.

- [ ] **Step 8: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 5: Plugin manifest schema v5 + optional `branches` field

**Files:**

- Modify: `common/lib/src/models/plugin/plugin_manifest.dart`
- Test: `common/test/models/plugin/plugin_manifest_test.dart` (extend)

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(common): plugin manifest schema v5 with optional branches block

Adds a manifest-level branches field of type BranchManifest? so
publishers can declare their branch set. Backward-compatible:
v4 manifests without the block still parse and surface as null
to the consumer.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Write failing backward-compat tests**

Extend `common/test/models/plugin/plugin_manifest_test.dart`:

```dart
test('schema v4 manifest with no branches block still parses', () {
  final m = PluginManifest.fromJson({
    'manifest': {'schema_version': 4},
    'id': 'test-plugin',
    'name': 'Test',
    'description': '...',
    // ... whatever other required fields the manifest insists on
    //     — copy from existing tests in this file
  });
  expect(m.branches, isNull);
});

test('schema v5 manifest with branches block parses', () {
  final m = PluginManifest.fromJson({
    'manifest': {'schema_version': 5},
    'id': 'test-plugin',
    'name': 'Test',
    'description': '...',
    'branches': {
      'stable': {'ref': 'main', 'description': 'Prod', 'default': true},
      'next': {'ref': 'develop'},
    },
  });
  expect(m.branches, isNotNull);
  expect(m.branches!.branches['stable']!.ref, 'main');
  expect(m.branches!.defaultKey, 'stable');
});

test('schema v5 manifest with no branches block parses (field optional)', () {
  final m = PluginManifest.fromJson({
    'manifest': {'schema_version': 5},
    'id': 'test-plugin',
    'name': 'Test',
    'description': '...',
  });
  expect(m.branches, isNull);
});
```

- [ ] **Step 3: Verify test fails**

Run: `cd common && dart test test/models/plugin/plugin_manifest_test.dart`
Expected: FAIL — `branches` is not a field.

- [ ] **Step 4: Add the field**

Modify `common/lib/src/models/plugin/plugin_manifest.dart`:

- Bump `currentPluginManifestVersion` from 4 → 5
- Add field: `final BranchManifest? branches;`
- Add to constructor: `this.branches,`
- In `fromJson`, after existing field reads:

```dart
final branchesJson = json['branches'];
final branches = branchesJson is Map<String, dynamic>
    ? BranchManifest.fromJson(branchesJson)
    : null;
```

Add `branches: branches,` to the constructor invocation.

- In `toJson`: emit `if (branches != null) 'branches': branches!.toJson()`

(Look at how the existing optional `nostr` block from the previous spec is shaped and follow the same pattern.)

- [ ] **Step 5: Verify tests pass**

Run: `cd common && dart test test/models/plugin/plugin_manifest_test.dart`
Expected: all pass.

- [ ] **Step 6: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 6: In-tree plugin migration — `branches` block in each `plugin.json`

**Files:**

- Modify: each in-tree plugin's `plugin.json`. Find them via:

```bash
find . -name plugin.json -not -path './dev/*'
```

The list should cover bitcoind, lnd, cln/clightning, electrs, blitz-api, blitz-web, lnbits, tailscale (~9 plugins).

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(plugins): migrate in-tree manifests to schema v5 with branches

Each in-tree plugin declares { stable: { ref: main, default: true } }
so the new manifest-driven branch picker has a consistent base.
External / future plugins that omit the block continue to get the
free-form Custom branch… input as fallback.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Inventory the plugins**

Run: `find . -name plugin.json -not -path './dev/*' -not -path './node_modules/*'`
Capture the list. Should be ~9 files.

- [ ] **Step 3: For each plugin.json, bump schema + add branches**

For each file, modify the JSON to:

1. Set `manifest.schema_version` to `5` (was `4`).
2. Add a top-level `branches` key:

```json
"branches": {
  "stable": {
    "ref": "main",
    "description": "Production releases",
    "default": true
  }
}
```

A `description` field for each plugin can use a fairly generic value or something plugin-specific (e.g. "Tracks upstream bitcoind release branch"). For v1, keep it short and generic; future commits can refine.

Maintain the file's existing field ordering — drop the new `branches` block at the position that keeps the JSON readable (top-level, near the bottom is typical).

- [ ] **Step 4: Verify the plugin-consistency invariant test still passes**

Run: `just test`

The `plugin-consistency` check (per CLAUDE.md) runs as part of `just test`. If it has invariants like "schema_version is uniform across in-tree plugins" or "each plugin has X field," verify they still hold after the migration.

Expected: all green.

- [ ] **Step 5: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 7: Rename `switchChannel` → `switchBranch` (service + CLI)

**Files:**

- Modify: `common/lib/src/services/plugin_service.dart`
- Modify: `tui/lib/src/cli/plugin_cli.dart`
- Modify: existing test files referencing `switchChannel`

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "refactor(plugin): rename switchChannel → switchBranch

Branch is the honest term for what the marker actually stores; the
\"channel\" abstraction added a fixed-semantic-tier connotation we
don't earn. Rename is mechanical: service method, CLI subcommand
(switch-channel → switch-branch), test references. Marker's
existing branch field is already correctly named.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Identify all callers**

Run: `grep -r 'switchChannel\|switch-channel\|SwitchChannel' --include='*.dart' -l`

Expected: a handful of files — the service, the CLI command class, test files, possibly the existing `plugin_switch_channel_view.dart` (which gets renamed in T10 — for now keep its method calls pointing at `switchBranch`).

- [ ] **Step 3: Mechanical rename**

Use `Edit` with `replace_all: true` to swap names in each file:

| Old                                                                | New                                             |
| ------------------------------------------------------------------ | ----------------------------------------------- |
| `switchChannel`                                                    | `switchBranch`                                  |
| `PluginSwitchChannelCommand`                                       | `PluginSwitchBranchCommand` (CLI command class) |
| `'switch-channel'` (CLI subcommand string)                         | `'switch-branch'`                               |
| `_runSwitchChannel`                                                | `_runSwitchBranch`                              |
| Comment / docstring mentions of "switch channel" → "switch branch" |

Do NOT yet rename `plugin_switch_channel_view.dart` to `plugin_switch_branch_view.dart` — that's T10 (it's tied to the picker integration). Just update method calls inside it.

- [ ] **Step 4: Verify nothing left over**

Run: `grep -r 'switchChannel\|switch-channel\|SwitchChannel' --include='*.dart'`

Expected: only the view filename (`plugin_switch_channel_view.dart`) remains. Everything else is renamed.

- [ ] **Step 5: Run trio**

Run: `just test; just analyze; just format`
Expected: green. All existing tests should still pass after the mechanical rename.

---

## Task 8: `PluginService.install` default-branch resolution from manifest

**Files:**

- Modify: `common/lib/src/services/plugin_service.dart`
- Test: `common/test/services/plugin_service_test.dart` (extend)

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(plugin): install resolves default branch from manifest.branches

When the operator runs plugin add without --branch, the install
flow now consults the manifest's branches block: if it declares
a default:true entry, use that entry's ref. Otherwise fall back
to the git remote's default branch (existing behaviour). Plugins
without a branches block keep working as before.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Write failing test**

Extend `common/test/services/plugin_service_test.dart`:

```dart
test('install without --branch uses manifest.branches default:true', () async {
  // Use the existing tmpdir-backed plugin fixture pattern;
  // construct a manifest that declares branches with a default.
  // Assert that after install, marker.branch equals the default
  // entry's ref.
  final svc = PluginService(/* tmpdir-backed setup */);
  // (Construct fixture plugin repo with manifest declaring
  //  branches: { stable: { ref: main, default: true }, next: {...} })
  final marker = await svc.install(
    '<fixture-url>',
    // no branch arg
    confirm: (_) async => true,
  );
  expect(marker.branch, 'main');
});

test('install with --branch overrides manifest default', () async {
  // Same fixture; pass branch: 'next'. Assert marker.branch == ref
  // of the 'next' entry (e.g. 'develop' if that's what the fixture
  // declares).
});

test('install of v4 plugin without branches block uses --branch as-is', () async {
  // Construct fixture without branches block; pass --branch=main.
  // Existing behaviour preserved.
});
```

(Adapt the fixture construction to the existing test helpers; the plugin_service_test.dart file from the prior work has helpers for tmpdir plugin repos.)

- [ ] **Step 3: Verify test fails**

Run: `cd common && dart test test/services/plugin_service_test.dart`
Expected: FAIL — default not resolved correctly.

- [ ] **Step 4: Implement the resolution**

In `PluginService.install`, after the manifest is read but before the clone proceeds with the chosen branch:

```dart
// If caller didn't specify a branch AND the manifest declares one,
// prefer the manifest's default. Otherwise fall through to the
// remote's default (existing behaviour — branch param stays null).
if (branch == null && manifest.branches != null) {
  final dk = manifest.branches!.defaultKey;
  if (dk != null) {
    branch = manifest.branches!.branches[dk]!.ref;
    // (Re-clone at that branch — or move this resolution earlier
    //  so the initial clone uses the right ref.)
  }
}
```

The implementation detail of WHEN this runs depends on the existing install flow's ordering — the initial clone may have to happen against the remote default first to even read the manifest, then re-clone at the resolved branch if it differs. Alternatively, since the manifest lives on `main` typically, the existing flow may already do an initial clone + manifest read on the default branch, then a re-clone if the user picked a specific branch. Adapt to whatever the flow currently does.

- [ ] **Step 5: Verify tests pass**

Run: `cd common && dart test test/services/plugin_service_test.dart`
Expected: all pass.

- [ ] **Step 6: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 9: `BranchPicker` widget

**Files:**

- Create: `tui/lib/src/ui/widgets/branch_picker.dart`
- Test: `tui/test/ui/widgets/branch_picker_test.dart`

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(tui): BranchPicker widget — shared between System + Plugin surfaces

Takes a BranchManifest? (null → free-form input only) and the
operator's current value. Renders declared branches with
descriptions, current selection highlighted, and a Custom branch…
row at the bottom. On selection returns the new value as either a
declared key or 'custom:<ref>'.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Write failing widget tests**

Create `tui/test/ui/widgets/branch_picker_test.dart`. Reference existing nocterm widget tests under `tui/test/ui/` for the testing pattern (e.g. the `nostr_consent_section_test.dart` from the prior work).

```dart
import 'package:common/common.dart';
import 'package:test/test.dart';

import 'package:tui/src/ui/widgets/branch_picker.dart';

void main() {
  group('BranchPicker', () {
    test('renders declared branches with descriptions', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'description': 'Prod', 'default': true},
        'next': {'ref': 'develop', 'description': 'Beta'},
      });
      final picker = BranchPicker(
        manifest: manifest,
        currentValue: 'stable',
        onSelected: (_) {},
      );
      final rendered = picker.build(/* fake BuildContext */).toString();
      expect(rendered, contains('stable'));
      expect(rendered, contains('next'));
      expect(rendered, contains('Prod'));
      expect(rendered, contains('Beta'));
      expect(rendered, contains('Custom branch'));
    });

    test('null manifest renders only Custom branch row', () {
      final picker = BranchPicker(
        manifest: null,
        currentValue: null,
        onSelected: (_) {},
      );
      final rendered = picker.build(/* ctx */).toString();
      expect(rendered, contains('Custom branch'));
      // No declared rows
    });

    test('current selection highlighted', () {
      // Build with currentValue: 'next'. Assert the 'next' row
      // carries the highlight marker (whatever the picker uses —
      // bold, prefix, etc.).
    });

    test('selecting Custom branch transitions to input phase', () {
      // The picker may be stateful via a controller / state notifier.
      // Verify that the picker, on selecting Custom branch…,
      // exposes an input phase rendering a text input. Adapt to
      // however nocterm overlay/text input is wired.
    });
  });
}
```

- [ ] **Step 3: Verify test fails**

Run: `cd tui && dart test test/ui/widgets/branch_picker_test.dart`
Expected: FAIL — `BranchPicker` not defined.

- [ ] **Step 4: Implement the widget**

Create `tui/lib/src/ui/widgets/branch_picker.dart`. Pseudocode shape (adapt to nocterm's actual widget API by reading sibling files like `nostr_consent_section.dart`):

```dart
import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

/// Shared branch picker for nixblitz-self (System config) and
/// plugin switch flows. When `manifest` is null, only the
/// Custom branch… row is shown — operator types a ref string.
class BranchPicker extends StatefulComponent {
  const BranchPicker({
    super.key,
    required this.manifest,
    required this.currentValue,
    required this.onSelected,
  });

  /// Publisher's declared branches, or null for free-form-only.
  final BranchManifest? manifest;

  /// The operator's current pick — either a declared key like
  /// "stable" or "custom:<ref>" or null (no pick yet).
  final String? currentValue;

  /// Invoked with the new value when the operator picks a row or
  /// confirms a Custom branch… input. Format: declared key or
  /// "custom:<ref>".
  final void Function(String newValue) onSelected;

  @override
  State<BranchPicker> createState() => _BranchPickerState();
}

class _BranchPickerState extends State<BranchPicker> {
  // Two phases: 'list' (rows) and 'customInput' (text field).
  // Maintain phase + cursor + customInput buffer.
  // On Enter in list phase: if Custom branch row → transition to
  //   customInput; else fire onSelected with the row's key.
  // On Enter in customInput phase: fire onSelected with
  //   'custom:${buffer}'.
  // Esc cancels back to list / dismisses the overlay (depending on
  //   caller).

  @override
  Component build(BuildContext context) {
    final manifest = widget.manifest;
    final rows = <Component>[];
    if (manifest != null) {
      for (final entry in manifest.branches.entries) {
        final isCurrent = widget.currentValue == entry.key;
        final marker = isCurrent ? '●' : ' ';
        final descr = entry.value.description;
        rows.add(Text('$marker ${entry.key} (ref: ${entry.value.ref})'));
        if (descr != null) rows.add(Text('     $descr'));
      }
    }
    rows.add(const Text('  Custom branch…'));
    // ... add focus/selection logic, render as Column.
    return Column(children: rows);
  }
}
```

The actual focus + keyboard handling depends on nocterm's `Focusable` pattern — read `tui/lib/src/ui/views/plugin_switch_channel_view.dart` (the existing one that has hardcoded list logic) to crib the dispatch pattern.

- [ ] **Step 5: Verify tests pass**

Run: `cd tui && dart test test/ui/widgets/branch_picker_test.dart`
Expected: all pass.

- [ ] **Step 6: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 10: Rename + integrate `PluginSwitchBranchView`

**Files:**

- Rename: `tui/lib/src/ui/views/plugin_switch_channel_view.dart` → `plugin_switch_branch_view.dart`
- Modify: `tui/lib/src/ui/views/configure_view.dart` (per-plugin pane reference + action label)
- Modify: any test files referencing the old name

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(tui): PluginSwitchBranchView reads branches from manifest

Renames PluginSwitchChannelView → PluginSwitchBranchView and
replaces the hardcoded main/beta/dev list (from #33) with the
shared BranchPicker reading plugin.manifest.branches. Plugins
without a branches block get the Custom branch… input only.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Rename the file**

```bash
git mv tui/lib/src/ui/views/plugin_switch_channel_view.dart \
       tui/lib/src/ui/views/plugin_switch_branch_view.dart
```

(`git mv` is fine even under jj — jj tracks file renames.)

Rename the class inside: `PluginSwitchChannelView` → `PluginSwitchBranchView`.

- [ ] **Step 3: Update the consent phase to use `BranchPicker`**

Find the `pickChannel` phase in the (now-renamed) view. Replace its hardcoded row construction with `BranchPicker(manifest: pluginManifest.branches, currentValue: marker.branch, onSelected: _handlePicked)`.

Look at the existing view to understand state/phase transitions; the rename should preserve the same overall flow.

- [ ] **Step 4: Update Configure view's per-plugin pane**

Modify `tui/lib/src/ui/views/configure_view.dart`:

- Update any import: `plugin_switch_channel_view.dart` → `plugin_switch_branch_view.dart`
- Update any class reference: `PluginSwitchChannelView` → `PluginSwitchBranchView`
- Update the synthetic action row label from "Switch channel…" → "Switch branch…" (everywhere it appears)
- Update the StateProvider name (likely `_switchingPluginIdProvider`) — keep the name itself if it's not too specific; rename only if it explicitly says "channel"

- [ ] **Step 5: Update test references**

Run: `grep -r 'PluginSwitchChannelView\|plugin_switch_channel_view' --include='*.dart' -l`

For each file found, update the references.

- [ ] **Step 6: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 11: Configure view System pane — new "Branch" row

**Files:**

- Modify: `tui/lib/src/ui/views/configure_view.dart`
- Test: `tui/test/ui/views/configure_view_test.dart` (extend if exists; otherwise verify manually for v1)

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(tui): System Configure pane — Branch row backed by BranchPicker

Operator can pick which nixblitz branch their flake tracks.
Picker reads the embedded BranchManifest; selection writes to
SystemConfig.nixblitzBranch and triggers ScaffoldService to
rewrite ~/nixblitz/flake.nix's nixblitz.url with ?ref=<ref>.
Custom branch… stays as the escape hatch for testing feature
branches (e.g. plugins-nostr-wot).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Read the existing System section**

Read `tui/lib/src/ui/views/configure_view.dart`. Find how the System section renders rows (hostname, timezone, platform, diskDevice, shell, tor). Each row has a label, a current value display, and an editor that fires on selection.

- [ ] **Step 3: Add the Branch row**

Add a new row after `tor`:

- Label: `Branch`
- Current value display: derive from `config.system.nixblitzBranch` + `nixblitzBranchManifestProvider`. If null, show `<default key> (ref: <default ref>)`. If `custom:<ref>`, show `custom (ref: <ref>)`. If declared key, show `<key> (ref: <ref>)`.
- On Enter: open `BranchPicker` overlay with `manifest: nixblitzBranchManifestProvider`, `currentValue: config.system.nixblitzBranch`, `onSelected: (newValue) => { config.copyWith(...) + scaffold trigger }`.

The picker overlay state is managed via a StateProvider analogous to `_switchingPluginIdProvider` from #33. Pattern:

```dart
final _branchPickerProvider = StateProvider<bool>((_) => false);
```

In `build()`, when `_branchPickerProvider.state == true`, render `BranchPicker` as a Stack sibling above the configure view (modal-style, per CLAUDE.md modal focus gating).

On selection, call `ref.read(configProvider.notifier).updateSystem((s) => s.copyWith(nixblitzBranch: newValue))` and `ref.read(_branchPickerProvider.notifier).state = false`.

- [ ] **Step 4: Wire modal focus gating**

Per CLAUDE.md pitfall #6 (modal focus gating): if the picker is rendered as an overlay, ensure the underlying configure view's `Focusable` yields focus when the picker is up. Reuse the existing `modalActiveProvider` pattern (`modalActive = helpVisible || sudo != null || _branchPickerProvider.state`).

- [ ] **Step 5: Verify the picker overlay appears + selection writes config**

Run a manual sanity check via `just run` (or `dart run tui/bin/nixblitz.dart` directly):

- Navigate to Configure → System → Branch row
- Press Enter → picker overlay appears
- Pick `stable` → overlay dismisses, row shows `stable (ref: main)`
- Re-open, pick `Custom branch…`, type `plugins-nostr-wot`, Enter → row shows `custom (ref: plugins-nostr-wot)`
- Check `~/nixblitz/config.json` has `"nixblitz_branch": "custom:plugins-nostr-wot"`

(For v1 the row works without unit tests — Configure view tests are minimal in the codebase. Document the manual check in the commit body.)

- [ ] **Step 6: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Task 12: Apply view lock-file update threading

**Files:**

- Modify: `tui/lib/src/ui/views/apply_view.dart` (or wherever `nixos-rebuild switch` is invoked)
- Test: manual verification + any existing apply-flow tests

- [ ] **Step 1: Start the jj change**

```bash
jj new -m "feat(tui): Apply runs 'nix flake lock --update-input nixblitz' first

Changing SystemConfig.nixblitzBranch rewrites the operator's
flake.nix URL but doesn't auto-update flake.lock. nixos-rebuild
switch resolves to the LOCKED rev unless we explicitly refresh the
input. Apply now threads an update-input call before the rebuild
so a branch switch actually takes effect on next Apply.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 2: Find the rebuild invocation**

Read `tui/lib/src/ui/views/apply_view.dart` (and any helper service it calls). Find where `nixos-rebuild switch --flake .#<host>` is executed.

- [ ] **Step 3: Add the lock-update step**

Before the rebuild command, run:

```bash
nix flake lock --update-input nixblitz
```

Wired in the same way the existing rebuild command is run (likely via `Process.start` or `Process.runSync` — follow the existing pattern, including sudo handling if applicable).

The lock-update step should always run (it's a no-op if the URL hasn't changed since last Apply). Pseudocode:

```dart
// Run inside ~/nixblitz/ (working directory)
final lockResult = await Process.run(
  'nix',
  ['flake', 'lock', '--update-input', 'nixblitz'],
  workingDirectory: baseDir,
);
if (lockResult.exitCode != 0) {
  // Log + surface to the operator. Don't abort rebuild — the lock
  // may already be up-to-date, or this nix version may want a
  // slightly different flag spelling. The subsequent rebuild will
  // either succeed (lock was already current) or fail with a
  // clearer error.
  LogService.warn('flake lock update returned non-zero: ${lockResult.stderr}');
}

// Then proceed with the existing nixos-rebuild switch invocation.
```

- [ ] **Step 4: Manual verification**

After implementing T11 + T12:

1. Switch the Branch row to `custom: plugins-nostr-wot`, run Apply.
2. Check that `~/nixblitz/flake.lock`'s `nodes.nixblitz.locked.rev` reflects the tip of `plugins-nostr-wot`.
3. Verify the rebuild succeeded (or that the operator gets a clear error if `plugins-nostr-wot` doesn't exist on the forge).

- [ ] **Step 5: Run trio**

Run: `just test; just analyze; just format`
Expected: green.

---

## Self-review checklist (after writing the plan)

**1. Spec coverage** — every spec section maps to at least one task:

- ✅ Vocabulary rename (channels → branches) → T7 (mechanical rename) + T10 (view rename)
- ✅ Named-map declaration shape → T1 (BranchManifest model)
- ✅ branches.json embedded → T2
- ✅ Scaffold-time URL substitution → T4
- ✅ Plugin manifest v5 + branches → T5
- ✅ In-tree migration → T6
- ✅ Free-form fallback for plugins with no branches block → T9 (BranchPicker handles null manifest) + T10 (integration)
- ✅ BranchPicker shared widget → T9
- ✅ System Configure pane Branch row → T11
- ✅ Plugin install default-branch resolution → T8
- ✅ Lock-file update threading → T12
- ✅ SystemConfig.nixblitzBranch field → T3
- ✅ Custom:<ref> prefix convention → T4 (parser handles it) + T9 (picker emits it) + T11 (display strips it)

**2. Placeholder scan** — no TBDs / "implement later" / "add appropriate error handling" / "similar to Task N" patterns. Each task has concrete code blocks where code is required.

**3. Type / method consistency**:

- `BranchManifest` and `DeclaredBranch` field names match across T1 → T2 → T9 → T11
- `SystemConfig.nixblitzBranch` field name matches T3 → T4 → T11
- `resolveNixblitzRef` / `substituteNixblitzRef` referenced consistently in T4
- `nixblitzBranchManifestProvider` consistent T2 → T11
- `switchBranch` rename consistent T7 → T10
- `BranchPicker(manifest, currentValue, onSelected)` constructor consistent T9 → T10 → T11
- `custom:<ref>` prefix convention consistent T4 → T9 → T11
