# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

NixBlitz is a Dart TUI for installing and managing a Bitcoin/Lightning node on NixOS. Users boot a NixOS ISO, run the TUI, and get a configured node — without touching Nix files.

## Project Structure

```
nixblitz/
├── pubspec.yaml              # Dart workspace root
├── common/                   # Shared business logic (no UI)
│   ├── lib/src/models/       # NixblitzConfig, ServiceStatus, InstallState
│   ├── lib/src/services/     # ConfigService, GitService, SystemService, InstallService, LogService
│   ├── lib/src/providers/    # Riverpod providers
│   └── test/                 # Unit tests
├── tui/                      # Terminal UI (nocterm + Riverpod)
│   ├── bin/nixblitz.dart     # Entry point
│   └── lib/src/ui/           # Views and widgets
├── templates/                # NixOS module templates (also embedded in binary)
├── nix/                      # Nix build files
├── scripts/                  # Lock file generation scripts
└── flake.nix                 # Builds the TUI, provides nix run
```

## Development Commands

```bash
just test              # Run all Dart tests
just analyze           # Dart analyze both packages
just format            # Dart format
just run               # Run TUI locally
just gen-locks         # Regenerate Nix lock files after dart pub get
just vm-boot           # Boot NixOS ISO in QEMU for testing
just vm-ssh-installer  # SSH into live ISO VM
just vm-ssh            # SSH into installed VM
just vm-clean          # Delete disk image
```

Single test: `cd common && dart test test/services/config_service_test.dart`

## Post-task verification

Before reporting a task done or drafting a commit message, run the trio in order:

```bash
just test
just analyze
just format
```

Keeps the working tree in a consistent state across the three quality gates: tests passing, zero analyzer issues, uniform formatting. Skip only for purely discussion / no-code tasks, or when only `docs/` was touched.

Once the trio passes, **print a commit message — don't ask whether the user wants one**. Subject line + concise body focused on the why, no `#N` issue refs, Co-Authored-By footer. Treat the commit message as part of the deliverable, not a follow-up question.

## Architecture

- **`common` package** — all business logic. Only package that calls `Process.start()`/`Process.runSync()`. Models, services, providers.
- **`tui` package** — nocterm + Riverpod UI. Views and widgets only. Never calls system commands directly.
- **`templates/`** — NixOS modules using dendritic auto-discovery pattern. Embedded in binary via `EmbeddedTemplates` class.
- **Config system** — `~/nixblitz/config.json` is the single source of truth. Git-tracked. NixOS modules read it via `builtins.fromJSON`.

## Key Patterns

- **State management**: Riverpod providers. Config, service status, install state all reactive.
- **Logging**: `LogService` writes to `~/nixblitz.log`. Uses synchronous file append (not IOSink streams).
- **TUI framework**: nocterm with nocterm_riverpod integration. `context.watch()` for reactive, `context.read()` for one-shot.
- **Templates**: Embedded in binary as string constants (`EmbeddedTemplates.getAll()`), written to disk by `ScaffoldService`.

## VCS

Uses Jujutsu (`jj`). New files are auto-staged. For Nix builds, new files must be committed (`jj commit -m "msg"`) before `nix build` can see them.

## Nocterm Pitfalls (IMPORTANT)

These are hard-won lessons from debugging. Follow them strictly:

### 1. Never set StateProvider values inside onKeyEvent handlers

Setting a `StateProvider` value triggers an immediate rebuild of the component tree. If you do this inside an `onKeyEvent` callback, the rest of your handler code after the state change **will not execute** — nocterm rebuilds the widget, which discards the current call stack.

**Bad:**

```dart
onKeyEvent: (event) {
  context.read(someProvider.notifier).state = newValue; // triggers rebuild
  doImportantWork(); // NEVER RUNS
  return true;
}
```

**Good — use a plain instance variable for guards:**

```dart
bool _working = false;

onKeyEvent: (event) {
  if (_working) return true;
  _working = true;
  doImportantWork(); // runs fine
  // Only update providers AFTER all sync work is done
  context.read(stepProvider.notifier).state = nextStep;
  return true;
}
```

### 2. Wrap entire handler bodies in try/catch

nocterm's `runApp` creates its own error zone. Uncaught exceptions in key handlers are caught by nocterm's zone, NOT by your `runZonedGuarded` in main. If your `try/catch` doesn't wrap the full body, exceptions before the `try` silently disappear from your log.

**Bad:**

```dart
final config = buildConfig(); // can throw, but unprotected
try {
  writeFiles(config);
} catch (e) {
  LogService.error('failed', e); // never fires if buildConfig() threw
}
```

**Good:**

```dart
try {
  final config = buildConfig();
  writeFiles(config);
} catch (e, st) {
  LogService.error('failed', e, st);
}
```

### 3. Use synchronous I/O in key handlers

`Future.microtask()` and `async` lambdas may never execute inside nocterm key handlers — the Dart event loop doesn't process them while nocterm's rendering loop is active. Use `writeAsStringSync`, `Process.runSync`, etc.

### 4. Avoid IOSink/stream-based file writing

`File.openWrite()` returns an `IOSink` that binds to a stream. This can crash with "StreamSink is bound to a stream" if the sink is reused or the file is opened again. Use `File.writeAsStringSync()` with `FileMode.append` instead.

### 5. const constructors

Not all nocterm widgets support `const` constructors (e.g., `Expanded`, `Center`). If you get a `const_with_non_const` error, remove the `const` keyword.

### 6. Modal popup focus — gate at the Focusable, not at the tree

nocterm dispatches keys depth-first through the element tree. When a
modal popup sits as a `Stack` sibling above the view tree, the
underlying view's own `Focusable`s get visited _first_. If any of
them returns `true` (a view that handles `Esc`, for example), the
modal never sees the key.

**Do NOT** "fix" this with structural workarounds:

- `BlockFocus` / `FocusScope` to halt descent into the view subtree
- Conditional rendering that dismounts the view tree while a modal is up
- Custom dispatch overrides in nocterm itself

These look reasonable but trade subtle bugs (sibling iteration
short-circuits, focus state desync, view state loss on dismount) for
the original problem.

**Do** wire a `modalActiveProvider` (`helpVisible || sudo != null`) and
have every view's outer `Focusable` set `focused: !modalActive`. When
the modal is up, the view's outer Focusable yields focus → the
dispatcher's visit returns `false` from every Focusable in the view
subtree → the Stack iterator continues to the modal sibling →
modal's Focusable handles the key. Same dispatch path the original
code used; just makes the "I don't claim keys right now" state
explicit and per-view.

Inner sub-overlays in a view (e.g. an edit-field popup) only render
during specific states that can't coexist with a modal popup, so
they don't need the gating — but if a view turns out to swallow
modal keys, the fix is to add `focused: !modalActive` on the
specific Focusable, not to restructure the tree.

`ScrollableLog`'s internal Focusable also reads `modalActive` so
streaming-output panes during a rebuild don't eat the sudo prompt's
keys.

## Nix Build

Requires a custom nixpkgs fork (`github:fusion44/nixpkgs/dart-workspace-member-filter`) for Dart workspace support. After changing Dart dependencies: `just gen-locks`.

### Flake input rules

When adding a flake input to either `flake.nix` or `templates/flake.nix`, **always set `inputs.nixpkgs.follows = "nixpkgs"`** unless there's a deliberate, documented reason not to. Skipping this:

- **Bloats the closure.** Each input's pinned nixpkgs is a separate snapshot — operators end up with two, three, four versions of every C library on disk.
- **Breaks downstream overlays.** A flake input that captures `pkgs = nixpkgs.legacyPackages.${system}` from its own pinned nixpkgs won't see your `nixpkgs.overlays` declarations at NixOS module level. The Pi 5's blitz-api / uv jemalloc-sys saga (issue #24 thread) bit us exactly because `blitz-api` had no follows — its uv was captured at blitz-api flake-eval time, and our overlay couldn't reach it. **Always follows.**
- **Reduces binary-cache hit rate.** The combinatorial explosion of pinned-nixpkgs versions means cache.nixos.org / our future Attic cache substitutes fewer paths.

Same rule applies for any other shared input in scope (`disko`, …) — if input A depends on input B and we already pin B, A should follow.

**Documented exceptions** — both have a comment block above the input recording WHY:

- `flake.nix`'s `nixpkgs-unstable` stays separate because the Dart-workspace-member-filter patch lives there.
- `templates/flake.nix`'s `nixos-raspberrypi` does NOT follow nixpkgs. nvmd's CI publishes the Pi 5 vendor kernel + page-size-16k jemalloc to `nixos-raspberrypi.cachix.org` built against THEIR pinned nixpkgs; following ours diverges the derivation hash, forces a multi-hour Pi-local kernel rebuild on every nixpkgs bump, and risks thermal-stressing operator hardware. The cache hit on `nixos-raspberrypi.cachix.org` is dramatically more valuable than the ~400MB of extra nixpkgs in the closure.

Whenever a third exception is genuinely warranted, add it here AND in a comment above the input.
