# wasmtime_dart Binding Package — Design

**Date:** 2026-07-13
**Status:** Approved
**Scope:** Sub-project 1 of 2. This spec covers only the standalone
`wasmtime_dart` binding package. The plugin-runtime integration (manifest
`wasm:` actions/streamers, permission model, consent UI) is a second spec,
written once this package's API is real.

## Why

NixBlitz wants a lower-trust plugin tier: plugin logic that runs inside a
WASM sandbox with declarative permissions, instead of `bash -c` with the
admin user's full ambient authority. A feasibility spike
(`examples_redesign/wasmtime_dart_spike/`) validated the riskiest parts on
both targets — x86_64 and the Pi 5's 16K-page aarch64 kernel:

- wasmtime C API (v46, from nixpkgs `wasmtime.lib`) driven via `dart:ffi`;
  all stages passed on both architectures, everything substituted from
  cache.nixos.org.
- Dart host functions called from JIT'd wasm work with
  `NativeCallable.isolateLocal` (linker host calls arrive on the calling
  thread).
- Fuel metering stops an infinite guest loop.
- WASI command modules run with file-captured stdout and read-only
  preopens.

This package is the production-quality successor to the spike: the
wasmtime-py architecture (thin wrapper over the official C API) translated
to Dart tooling.

## Goals

- Idiomatic, tested Dart API over the wasmtime C API, covering what a
  plugin runtime needs: modules, instances, typed host functions, WASI,
  fuel + epoch limits, traps, guest memory access, module serialization.
- Zero custom native packaging: the shared library comes from nixpkgs
  (`wasmtime.lib`), headers from `wasmtime.dev`.
- Mechanical version bumps: regenerate bindings, fix analyzer fallout.

## Non-goals (v1)

- Component model, WASI 0.2+, GC references (externref/anyref/structref).
- Async config / custom stdio callbacks (see Threading, below).
- Pooling allocator, shared memories, tables/globals API beyond what
  instantiation needs.
- Any nixblitz awareness: no plugin concepts, no JSON call conventions, no
  isolate sandbox runner. Those belong to the integration spec.
- Windows/macOS support. Loading is generic (`DynamicLibrary.open`), but
  only linux x86_64/aarch64 is tested or claimed.

## Package shape

New workspace member `wasmtime_dart/` (added to the root `pubspec.yaml`
workspace list). Only runtime dependency: `package:ffi`. Native-only —
never imported by website/PWA code.

```
wasmtime_dart/
├── pubspec.yaml
├── ffigen.yaml                        # header path from $WASMTIME_INCLUDE
├── README.md                          # version-bump procedure, threading rules
├── lib/wasmtime_dart.dart             # public exports
├── lib/src/generated/bindings.g.dart  # ffigen output — committed, never edited
├── lib/src/library.dart               # WasmtimeLibrary: locate + open the .so
├── lib/src/engine.dart                # Engine, EngineConfig, EpochTicker
├── lib/src/store.dart                 # Store, Context
├── lib/src/module.dart                # Module (fromWasm/fromWat/serialize)
├── lib/src/linker.dart                # Linker (defineWasi/defineFunc/instantiate)
├── lib/src/instance.dart              # Instance (getFunc/getMemory)
├── lib/src/func.dart                  # Func, host-function trampoline + registry
├── lib/src/value.dart                 # Val, ValType, FuncType
├── lib/src/memory.dart                # Memory (read/write/size/grow)
├── lib/src/wasi.dart                  # WasiConfig builder
├── lib/src/trap.dart                  # WasmtimeError, WasmTrap (+ trap codes)
└── test/                              # WAT-string fixtures, no external toolchain
```

Two layers:

1. **Generated raw layer** — ffigen over `${wasmtime.dev}/include`
   (`wasmtime.h`, `wasi.h`, `wasm.h`). Committed like
   `embedded_templates.g.dart`, with the same drift-guard treatment.
2. **Hand-written idiomatic layer** — one focused file per concept,
   modeled on wasmtime-py's class-per-concept split (~4k lines of proven
   reference to translate).

## API surface

### Loading — `WasmtimeLibrary`

- `WasmtimeLibrary.open(String path)` — explicit path.
- `WasmtimeLibrary.discover()` — `$WASMTIME_DART_LIB`, else SONAME
  `libwasmtime.so`.
- The C API exposes no version symbol. A failed symbol lookup throws
  `WasmtimeError` with a "library version does not match the generated
  bindings (expected wasmtime 46.x)" hint.

### Core — `Engine`, `Store`, `Module`

- `EngineConfig({bool consumeFuel, bool epochInterruption})` → `Engine`.
- `Module.fromWasm(engine, Uint8List)`, `Module.fromWat(engine, String)`
  (via `wasmtime_wat2wasm`).
- `module.serialize() → Uint8List`, `Module.deserialize(engine, bytes)`,
  `Module.deserializeFile(engine, path)` — compile-once caching matters on
  the Pi.
- `Store(engine)`; `store.context` is the handle passed to calls.
- `context.setFuel(int)`, `context.setEpochDeadline(int ticks)`,
  `context.setWasi(WasiConfig)`.

### Values — `Val`, `ValType`, `FuncType`

Sealed `Val` variants: `i32`, `i64`, `f32`, `f64`, `v128` (16 bytes).
Dart ints are 64-bit signed, so i64 round-trips without BigInt.
`FuncType(params: List<ValType>, results: List<ValType>)`.

### Linking and calling — `Linker`, `Func`, `Caller`

- `Linker(engine)`, `linker.defineWasi()`,
  `linker.instantiate(context, module) → Instance`,
  `instance.getFunc(context, name) → Func` (plus `getMemory`).
- `func.call(context, [args]) → List<Val>` — checked variant only;
  the unchecked/raw ABI is out of scope.
- `linker.defineFunc(String module, String name, FuncType type,
List<Val> Function(Caller caller, List<Val> args) fn)`.
- `Caller.getExport(name)` → memory handle, so host functions can read
  guest strings from linear memory.

**Host-function mechanics:** one static
`NativeCallable<...>.isolateLocal` trampoline serves every host function;
the C `env` pointer carries an index into a Dart-side registry
(`Map<int, registered fn>`). A Dart exception thrown inside a host
function never unwinds through C frames — the trampoline catches it and
returns a `wasmtime_trap_new` trap carrying the exception's `toString()`.

### Memory — `Memory`

`readBytes(context, offset, length)` / `writeBytes(context, offset, bytes)`
— bounds-checked against `wasmtime_memory_data_size`; `size`, `sizeBytes`,
`grow`. This is the substrate the integration spec will use for
string/JSON passing.

### Limits — fuel and epochs

- Fuel: engine flag + `setFuel`; exhaustion surfaces as `WasmTrap` with
  the out-of-fuel trap code.
- Epochs: `EpochTicker(engine, interval)` spawns a watchdog isolate that
  receives the engine's raw pointer address and calls
  `wasmtime_engine_increment_epoch` (documented thread-safe) every
  interval; `ticker.stop()` kills it. This is required because the calling
  isolate is blocked inside FFI while the guest runs — a same-isolate
  timer can never fire. Gives callers wall-clock deadlines
  (`setEpochDeadline(n)` + ticker) independent of fuel accounting.

### WASI — `WasiConfig`

Builder mirroring the C API: `argv`, `env`,
`preopenDir(hostPath, guestPath, {DirPerms, FilePerms})` with read-only
support, `stdoutToFile(path)`, `stderrToFile(path)`, `stdinBytes`,
`inheritStdout/Stderr/Stdin`. `context.setWasi(config)` consumes the
config (subsequent use throws).

### Errors — `WasmtimeError`, `WasmTrap`

`WasmtimeError` for API failures (message extracted + native error
freed). `WasmTrap` carries the message and the `wasmtime_trap_code`
enum so callers can distinguish fuel exhaustion / epoch interrupt /
guest faults.

### Lifetimes

Every owning handle (`Engine`, `Store`, `Module`, `Linker`) registers a
`NativeFinalizer` and offers explicit `dispose()` (idempotent) for
deterministic teardown in tests. Documented rules, enforced with
use-after-dispose checks: a disposed handle throws `StateError`; a
`Store` must outlive its instances, funcs, and memories.

## Threading rules (documented in the README)

- Guest calls and host functions run on the calling isolate's thread —
  `isolateLocal` callbacks are correct there.
- wasmtime-wasi invokes custom stdio callbacks from tokio worker threads,
  which aborts the Dart VM. Therefore custom stdio callbacks are not
  exposed; stdio capture is file-based only.
- The only supported cross-thread operation is
  `wasmtime_engine_increment_epoch` (via `EpochTicker`).

## Codegen, Nix, and the dev loop

- `just gen-wasmtime-bindings` — resolves headers via
  `nix build nixpkgs#wasmtime.dev`, exports `$WASMTIME_INCLUDE`, runs
  `dart run ffigen`.
- `just check-wasmtime-bindings` — content-comparison drift guard
  (snapshot → regenerate → compare, file left regenerated on drift),
  same pattern as `check-templates`; wired into `just ci`.
- Dev shell adds `wasmtime.lib` + `wasmtime.dev` and exports
  `WASMTIME_DART_LIB`, so `just test` works without manual setup.
- Ship time: the TUI's Nix wrapper bakes `WASMTIME_DART_LIB` to the store
  path of the same nixpkgs input used for the build (wired in the
  integration cycle; this package only defines the env contract).
- Version bumps (README procedure): bump nixpkgs → regenerate bindings →
  `just test` → fix analyzer/test fallout. Bindings are pinned to the
  nixpkgs wasmtime major (46.x today).

## Testing

`dart test` only; fixtures are WAT strings compiled through the
binding's own `wat2wasm` — no external wasm toolchain. Required coverage:

- Module compile/instantiate/call round-trip; serialize → deserialize →
  call.
- Host functions: i32/i64/f32/f64 and multi-value round-trips; guest
  memory read from a host function via `Caller`; Dart exception → trap
  with message preserved.
- Fuel exhaustion trap code; epoch interrupt via `EpochTicker` (spin
  loop deadline actually fires).
- WASI: argv/env visible to guest; stdout captured to file; read-only
  preopen **enforcement** — a `path_open`-for-write WAT fixture must
  fail against an RO preopen (not merely "config call returned true").
- Lifetimes: use-after-dispose throws `StateError`; double-dispose is a
  no-op.
- Error paths: invalid WAT, missing export, arity/type mismatch on call.

## Risks and mitigations

- **Struct-by-value ABI drift across wasmtime majors** — bindings are
  generated from the exact headers of the pinned version; the drift guard
  keeps generated code honest; the discover() error message names the
  expected major.
- **ffigen output quality over these headers** — unvalidated (the spike
  hand-transcribed). First implementation task is generating and
  compiling the bindings; if ffigen chokes on specific headers, fallback
  is scoping ffigen to the entry headers actually needed.
- **Callback reentrancy** (guest → host → guest) — exercised by a
  dedicated test before the integration cycle relies on it.

## Branch

All work lands on the `wasm-plugins` branch (jj bookmark), based on the
current pending stack (it extends the `ci` recipe introduced there), not
merged to main until the integration direction is confirmed.
