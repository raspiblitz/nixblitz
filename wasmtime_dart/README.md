# wasmtime_dart

Dart bindings for the [wasmtime](https://wasmtime.dev) C API — sandboxed
WASM/WASI execution for NixBlitz's plugin runtime (but nixblitz-agnostic;
no plugin concepts live here). Design:
`docs/superpowers/specs/2026-07-13-wasmtime-dart-binding-design.md`.

## Layout

- `lib/src/generated/bindings.g.dart` — ffigen output over the nixpkgs
  `wasmtime.dev` headers. Committed; regenerate with
  `just gen-wasmtime-bindings`; guarded by `just check-wasmtime-bindings`.
  Never edit by hand.
- `lib/src/*.dart` — hand-written idiomatic layer (Engine, Store, Module,
  Linker, Instance, Func, Memory, WasiConfig, traps).

## Environment contract

- `WASMTIME_DART_LIB` — absolute path to `libwasmtime.so`.
  `WasmtimeLibrary.discover()` reads it, falling back to the SONAME.
  The devenv exports it; the shipped TUI wrapper must bake it.
- `WASMTIME_INCLUDE` / `LIBCLANG_PATH` — codegen only (devenv exports).

## Threading rules

- Guest calls and host functions run on the calling isolate's thread.
- Custom WASI stdio callbacks are NOT exposed: wasmtime-wasi invokes
  them from tokio worker threads, which aborts the Dart VM. Capture
  stdio via files (`WasiConfig.stdoutFile` / `stderrFile`).
- The only supported cross-thread call is
  `wasmtime_engine_increment_epoch`, wrapped by `EpochTicker` (a
  watchdog isolate). Always `await ticker.stop()` before
  `engine.dispose()` — `stop()` only completes once the watchdog
  isolate has actually exited, so there is no window where a
  straggling timer tick can increment the epoch of a freed engine.

## Bumping wasmtime

1. Advance nixpkgs so `wasmtime.lib`/`wasmtime.dev` move together.
2. `just gen-wasmtime-bindings`
3. `cd wasmtime_dart && dart test` — fix analyzer/test fallout; re-check
   the literal constants transcribed from headers (TrapCode values,
   extern kinds 0/3, valkinds) against the new headers.
4. Commit the regenerated bindings with the version bump.

Bindings are pinned to the nixpkgs wasmtime major (46.x today); a
mismatched library fails at open with a version hint.
