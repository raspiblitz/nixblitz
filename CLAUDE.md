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

## Nix Build

Requires a custom nixpkgs fork (`github:fusion44/nixpkgs/dart-workspace-member-filter`) for Dart workspace support. After changing Dart dependencies: `just gen-locks`.
