# wasmtime_dart Binding Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tested Dart workspace package `wasmtime_dart/` binding the wasmtime C API (v46) — ffigen raw layer + hand-written idiomatic layer — per `docs/superpowers/specs/2026-07-13-wasmtime-dart-binding-design.md`.

**Architecture:** ffigen generates `lib/src/generated/bindings.g.dart` from the nixpkgs `wasmtime.dev` headers (committed, drift-guarded). A hand-written layer (`Engine`, `Store`, `Module`, `Linker`, `Instance`, `Func`, `Memory`, `WasiConfig`, traps) wraps it, modeled on wasmtime-py. Tests compile WAT-string fixtures through the binding's own `wat2wasm` — no external wasm toolchain.

**Tech Stack:** Dart 3.11 (`dart:ffi`, `NativeCallable`, `NativeFinalizer`), package:ffi, ffigen, nixpkgs `wasmtime.lib`/`wasmtime.dev` (46.0.1), just, devenv, Jujutsu (jj).

## Global Constraints

- VCS is **jj**, not git. New files are auto-tracked; commit with `jj commit -m "<msg>"`. After EVERY commit run `jj bookmark set wasm-plugins -r @-` so the branch tracks the work.
- Every commit message ends with the trailer line: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (blank line before it). Subject + body explain WHY, not a diff roster.
- Package: `name: wasmtime_dart`, `publish_to: none`, `environment: sdk: ^3.11.4`, `resolution: workspace`. Runtime dependency: `ffi` ONLY. Dev deps: `ffigen`, `test`, `lints`.
- Lints: `include: package:lints/recommended.yaml`. `dart analyze` must be clean and `dart format` applied before every commit (run `dart format .` inside `wasmtime_dart/`).
- The package must not import anything from `common/` or `tui/` — it is nixblitz-agnostic.
- `lib/src/generated/bindings.g.dart` is generated — NEVER hand-edited.
- Linux x86_64/aarch64 only; wasmtime pinned at 46.x.
- Tests need `$WASMTIME_DART_LIB` pointing at `libwasmtime.so`. The devenv exports it (Task 1). Manual fallback if the shell is stale:
  `export WASMTIME_DART_LIB=$(nix build nixpkgs#wasmtime.lib --no-link --print-out-paths)/lib/libwasmtime.so`
- All `dart` commands for this package run from `wasmtime_dart/` (`cd wasmtime_dart` first); `just`/`jj` commands run from the repo root.
- **Generated-name adaptation rule:** ffigen preserves C function names exactly (`raw.wasm_engine_new(...)`), and struct/typedef names match the headers (`wasmtime_val_t`, `wasm_byte_vec_t`, ...). If a generated spelling differs from what a task's code shows (e.g. anonymous-struct field wrappers), adapt the call site to the generated name — never edit the generated file. Task 1 Step 7 verifies the key names once so later tasks can rely on them.

## File map

| File                                              | Responsibility                                                         |
| ------------------------------------------------- | ---------------------------------------------------------------------- |
| `wasmtime_dart/pubspec.yaml`                      | package manifest                                                       |
| `wasmtime_dart/analysis_options.yaml`             | lints, excludes generated file                                         |
| `wasmtime_dart/ffigen.yaml`                       | codegen config (headers via `.dart_tool/wasmtime-include` symlink)     |
| `wasmtime_dart/README.md`                         | version-bump procedure, threading rules, env contract                  |
| `wasmtime_dart/lib/wasmtime_dart.dart`            | public exports                                                         |
| `wasmtime_dart/lib/src/generated/bindings.g.dart` | ffigen output (committed)                                              |
| `wasmtime_dart/lib/src/generated/raw.dart`        | re-export shim; the only import path for generated code                |
| `wasmtime_dart/lib/src/library.dart`              | `WasmtimeLibrary` open/discover + finalizer lookups                    |
| `wasmtime_dart/lib/src/trap.dart`                 | `WasmtimeError`, `WasmTrap`, `TrapCode`, native error/trap/vec helpers |
| `wasmtime_dart/lib/src/value.dart`                | `Val`, `ValType`, `FuncType`, native marshaling                        |
| `wasmtime_dart/lib/src/engine.dart`               | `EngineConfig`, `Engine`, `EpochTicker`                                |
| `wasmtime_dart/lib/src/store.dart`                | `Store`, `Context` (fuel/epoch/wasi setters)                           |
| `wasmtime_dart/lib/src/module.dart`               | `Module` fromWat/fromWasm/serialize/deserialize                        |
| `wasmtime_dart/lib/src/linker.dart`               | `Linker` defineWasi/defineFunc/instantiate                             |
| `wasmtime_dart/lib/src/instance.dart`             | `Instance` getFunc/getMemory                                           |
| `wasmtime_dart/lib/src/func.dart`                 | `Func.call`, `Caller`, host-function trampoline + registry             |
| `wasmtime_dart/lib/src/memory.dart`               | `Memory` read/write/size/grow                                          |
| `wasmtime_dart/lib/src/wasi.dart`                 | `WasiConfig` builder, `DirPerms`/`FilePerms`                           |
| `wasmtime_dart/test/*_test.dart`                  | per-concept tests                                                      |
| `wasmtime_dart/test/helpers.dart`                 | shared `testLib()` library singleton                                   |
| `justfile` (modify)                               | gen/check recipes, test/analyze/ci wiring                              |
| `devenv.nix` (modify)                             | wasmtime lib/dev + libclang env                                        |
| `pubspec.yaml` root (modify)                      | add workspace member                                                   |
| `CLAUDE.md` (modify)                              | project-structure line                                                 |

---

### Task 1: Package scaffold, devenv wiring, ffigen generation

**Files:**

- Create: `wasmtime_dart/pubspec.yaml`, `wasmtime_dart/analysis_options.yaml`, `wasmtime_dart/ffigen.yaml`, `wasmtime_dart/lib/src/generated/raw.dart`, `wasmtime_dart/test/raw_smoke_test.dart`
- Modify: `pubspec.yaml` (root), `devenv.nix`, `justfile`
- Generated: `wasmtime_dart/lib/src/generated/bindings.g.dart`

**Interfaces:**

- Consumes: nixpkgs `wasmtime.dev` headers, `wasmtime.lib` shared object.
- Produces: `WasmtimeRaw` class (constructor `WasmtimeRaw(ffi.DynamicLibrary)`) with one method per C function, plus all structs/enums — everything importable via `package:wasmtime_dart/src/generated/raw.dart`. Just recipe `gen-wasmtime-bindings`. Env vars `WASMTIME_DART_LIB`, `WASMTIME_INCLUDE`, `LIBCLANG_PATH` in the dev shell.

- [ ] **Step 1: Create the package manifest and lint config**

`wasmtime_dart/pubspec.yaml`:

```yaml
name: wasmtime_dart
description: Dart bindings for the wasmtime C API — sandboxed WASM/WASI execution.
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.11.4

resolution: workspace

dependencies:
  ffi: ^2.1.0

dev_dependencies:
  ffigen: ^20.0.0
  lints: ^6.1.0
  test: ^1.31.0
```

If `dart pub get` (Step 4) rejects a version floor, fix it with `dart pub add ffi` / `dart pub add --dev ffigen lints test` and keep whatever resolves.

`wasmtime_dart/analysis_options.yaml`:

```yaml
include: package:lints/recommended.yaml

analyzer:
  exclude:
    - lib/src/generated/bindings.g.dart
```

- [ ] **Step 2: Register the workspace member**

In the root `pubspec.yaml`, extend the workspace list:

```yaml
workspace:
  - common
  - tui
  - website
  - wasmtime_dart
```

- [ ] **Step 3: Wire the dev shell**

In `devenv.nix`, add to `packages`:

```nix
    pkgs-unstable.wasmtime.lib
    pkgs-unstable.wasmtime.dev
    pkgs-unstable.libclang.lib
```

and add a top-level `env` attribute (sibling of `packages`):

```nix
  env = {
    WASMTIME_DART_LIB = "${pkgs-unstable.wasmtime.lib}/lib/libwasmtime.so";
    WASMTIME_INCLUDE = "${pkgs-unstable.wasmtime.dev}/include";
    LIBCLANG_PATH = "${pkgs-unstable.libclang.lib}/lib";
  };
```

Then `direnv reload` (or re-enter the shell) and verify: `echo $WASMTIME_DART_LIB` prints a store path ending in `libwasmtime.so`.

- [ ] **Step 4: ffigen config + just recipe**

`wasmtime_dart/ffigen.yaml`:

```yaml
name: WasmtimeRaw
description: Raw bindings over the wasmtime C API. Generated — do not edit.
output: lib/src/generated/bindings.g.dart
headers:
  entry-points:
    - .dart_tool/wasmtime-include/wasmtime.h
compiler-opts:
  - -I.dart_tool/wasmtime-include
functions:
  exclude:
    - "wasmtime_component_.*"
    - ".*_async"
preamble: |
  // Generated by `just gen-wasmtime-bindings`. Do not edit.
  // ignore_for_file: type=lint
comments:
  style: any
  length: brief
```

`justfile` — add after the `gen-completions` recipe, following the repo's comment convention (detail lines, bare `#`, concise line last):

```make
# Resolves the wasmtime C headers from nixpkgs (`wasmtime.dev`), symlinks
# them to a stable path (ffigen.yaml cannot expand env vars), and runs
# ffigen. Rerun after every nixpkgs wasmtime bump; commit the result.
#
# Regenerate wasmtime_dart's raw FFI bindings from the wasmtime C headers
gen-wasmtime-bindings:
  #!/usr/bin/env nu
  let dev = (nix build nixpkgs#wasmtime.dev --no-link --print-out-paths | str trim)
  cd wasmtime_dart
  mkdir .dart_tool
  ^ln -sfn $"($dev)/include" .dart_tool/wasmtime-include
  dart run ffigen --config ffigen.yaml
```

- [ ] **Step 5: Generate**

```bash
cd wasmtime_dart && dart pub get && cd ..
just gen-wasmtime-bindings
```

Expected: ffigen writes `wasmtime_dart/lib/src/generated/bindings.g.dart` (thousands of lines). If ffigen cannot find libclang despite `LIBCLANG_PATH`, add to `ffigen.yaml`: `llvm-path:` with the store path printed by `echo $LIBCLANG_PATH`. If clang errors on builtin headers (`stddef.h` not found), append to `compiler-opts`: `-resource-dir $(clang -print-resource-dir)` — resolve the literal path and paste it.

- [ ] **Step 6: Re-export shim**

`wasmtime_dart/lib/src/generated/raw.dart`:

```dart
// The only import path for generated code. If a generated spelling ever
// changes across wasmtime/ffigen bumps, adapt importers here — never edit
// bindings.g.dart.
export 'bindings.g.dart';
```

- [ ] **Step 7: Smoke test (engine round-trip + key-name verification)**

`wasmtime_dart/test/raw_smoke_test.dart`:

```dart
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:test/test.dart';
import 'package:wasmtime_dart/src/generated/raw.dart';

void main() {
  test('raw bindings: engine round-trip', () {
    final path = Platform.environment['WASMTIME_DART_LIB'];
    expect(path, isNotNull,
        reason: 'WASMTIME_DART_LIB must be set (see devenv.nix)');
    final raw = WasmtimeRaw(ffi.DynamicLibrary.open(path!));
    final engine = raw.wasm_engine_new();
    expect(engine, isNot(ffi.nullptr));
    raw.wasm_engine_delete(engine);
  });
}
```

Run: `cd wasmtime_dart && dart test test/raw_smoke_test.dart`
Expected: PASS. While here, verify these names exist in the generated file (adjust later tasks' spellings if any differ):
`wasmtime_val_t`, `wasmtime_extern_t`, `wasmtime_instance_t`, `wasm_byte_vec_t`, `wasm_valtype_vec_t`, `wasmtime_func_callback_t`, `wasmtime_trap_code_enum` (or equivalent constants), `wasmtime_wat2wasm`, `wasmtime_linker_define_func`, `wasi_config_preopen_dir`, `wasmtime_engine_increment_epoch`.

- [ ] **Step 8: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): scaffold package + ffigen raw bindings

First layer of the wasmtime binding per the 2026-07-13 spec: ffigen
output over the nixpkgs wasmtime.dev headers (46.x), committed like
embedded_templates.g.dart so builds never depend on codegen tooling.
The dev shell now pins libwasmtime.so + headers + libclang so
generation and tests are reproducible.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 2: Library loading + error/trap primitives

**Files:**

- Create: `wasmtime_dart/lib/src/library.dart`, `wasmtime_dart/lib/src/trap.dart`, `wasmtime_dart/lib/wasmtime_dart.dart`, `wasmtime_dart/test/library_test.dart`

**Interfaces:**

- Consumes: `WasmtimeRaw` from Task 1.
- Produces: `WasmtimeLibrary` (`open(String path)`, `discover()`, fields `path`, `dylib`, `raw`, finalizers `engineFinalizer`/`storeFinalizer`/`moduleFinalizer`/`linkerFinalizer`); `WasmtimeError`; `WasmTrap` (fields `message`, `code`); `TrapCode` enum; helpers `checkError(WasmtimeRaw, Pointer<wasmtime_error_t>, String)`, `checkTrap(WasmtimeRaw, Pointer<wasm_trap_t>)`, `readAndDeleteByteVec(WasmtimeRaw, Pointer<wasm_byte_vec_t>)`.

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/library_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

void main() {
  test('discover opens the library from WASMTIME_DART_LIB', () {
    final lib = WasmtimeLibrary.discover();
    expect(lib.path, isNotEmpty);
  });

  test('open with a bad path throws WasmtimeError', () {
    expect(() => WasmtimeLibrary.open('/nonexistent/libwasmtime.so'),
        throwsA(isA<WasmtimeError>()));
  });

  test('open with a non-wasmtime library gives the version hint', () {
    expect(
      () => WasmtimeLibrary.open('libc.so.6'),
      throwsA(isA<WasmtimeError>().having(
          (e) => e.message, 'message', contains('wasmtime 46'))),
    );
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/library_test.dart`
Expected: FAIL — `wasmtime_dart.dart` / `WasmtimeLibrary` don't exist yet.

- [ ] **Step 3: Implement trap.dart**

`wasmtime_dart/lib/src/trap.dart`:

```dart
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'generated/raw.dart';

/// A wasmtime API error (config, compile, link, ... failures).
class WasmtimeError implements Exception {
  WasmtimeError(this.message);
  final String message;
  @override
  String toString() => 'WasmtimeError: $message';
}

/// Trap codes from wasmtime/trap.h (v46). Values are part of the C ABI
/// for the pinned major; re-check the header on a wasmtime bump.
enum TrapCode {
  stackOverflow(0),
  memoryOutOfBounds(1),
  heapMisaligned(2),
  tableOutOfBounds(3),
  indirectCallToNull(4),
  badSignature(5),
  integerOverflow(6),
  integerDivisionByZero(7),
  badConversionToInteger(8),
  unreachable(9),
  interrupt(10),
  outOfFuel(11),
  unknown(-1);

  const TrapCode(this.native);
  final int native;

  static TrapCode fromNative(int code) => TrapCode.values
      .firstWhere((c) => c.native == code, orElse: () => TrapCode.unknown);
}

/// A wasm trap: guest fault, fuel exhaustion, or epoch interrupt.
class WasmTrap implements Exception {
  WasmTrap(this.message, this.code);
  final String message;
  final TrapCode code;
  @override
  String toString() => 'WasmTrap(${code.name}): $message';
}

/// Reads a wasm_byte_vec_t's content as UTF-8 and releases the native
/// buffer. The struct allocation itself stays owned by the caller.
String readAndDeleteByteVec(WasmtimeRaw raw, ffi.Pointer<wasm_byte_vec_t> vec) {
  final bytes = vec.ref.data.cast<ffi.Uint8>().asTypedList(vec.ref.size);
  final message = utf8.decode(bytes, allowMalformed: true);
  raw.wasm_byte_vec_delete(vec);
  return message;
}

/// Throws [WasmtimeError] if [error] is non-null (consumes it).
void checkError(
    WasmtimeRaw raw, ffi.Pointer<wasmtime_error_t> error, String what) {
  if (error == ffi.nullptr) return;
  final vec = calloc<wasm_byte_vec_t>();
  raw.wasmtime_error_message(error, vec);
  final message = readAndDeleteByteVec(raw, vec);
  calloc.free(vec);
  raw.wasmtime_error_delete(error);
  throw WasmtimeError('$what: $message');
}

/// Throws [WasmTrap] if [trap] is non-null (consumes it).
void checkTrap(WasmtimeRaw raw, ffi.Pointer<wasm_trap_t> trap) {
  if (trap == ffi.nullptr) return;
  final vec = calloc<wasm_byte_vec_t>();
  raw.wasm_trap_message(trap, vec);
  final message = readAndDeleteByteVec(raw, vec);
  calloc.free(vec);
  final codeOut = calloc<ffi.Uint8>();
  final hasCode = raw.wasmtime_trap_code(trap, codeOut);
  final code = hasCode ? TrapCode.fromNative(codeOut.value) : TrapCode.unknown;
  calloc.free(codeOut);
  raw.wasm_trap_delete(trap);
  throw WasmTrap(message, code);
}
```

Adaptation notes: the generated `wasm_byte_vec_t.data` may be `Pointer<Char>` or `Pointer<Uint8>` — keep the `.cast<ffi.Uint8>()`. `wasmtime_trap_code`'s out param may be typed `Pointer<wasmtime_trap_code_t>`; allocate the matching integer type.

- [ ] **Step 4: Implement library.dart + public exports**

`wasmtime_dart/lib/src/library.dart`:

```dart
import 'dart:ffi' as ffi;
import 'dart:io';

import 'generated/raw.dart';
import 'trap.dart';

/// An opened libwasmtime.so plus its generated bindings and the
/// NativeFinalizers the owning handle classes attach.
class WasmtimeLibrary {
  WasmtimeLibrary._(this.path, this.dylib) : raw = WasmtimeRaw(dylib) {
    try {
      dylib.lookup('wasmtime_error_message');
    } on ArgumentError {
      throw WasmtimeError(
          '$path does not look like a wasmtime C API library matching the '
          'generated bindings (expected wasmtime 46.x)');
    }
  }

  /// Opens an explicit library path.
  factory WasmtimeLibrary.open(String path) {
    final ffi.DynamicLibrary dylib;
    try {
      dylib = ffi.DynamicLibrary.open(path);
    } on ArgumentError catch (e) {
      throw WasmtimeError('could not open $path: $e');
    }
    return WasmtimeLibrary._(path, dylib);
  }

  /// Resolves via $WASMTIME_DART_LIB, falling back to the SONAME.
  factory WasmtimeLibrary.discover() => WasmtimeLibrary.open(
      Platform.environment['WASMTIME_DART_LIB'] ?? 'libwasmtime.so');

  final String path;
  final ffi.DynamicLibrary dylib;
  final WasmtimeRaw raw;

  ffi.Pointer<ffi.NativeFinalizerFunction> _deleteFn(String symbol) => dylib
      .lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
          symbol);

  late final engineFinalizer = ffi.NativeFinalizer(_deleteFn('wasm_engine_delete'));
  late final storeFinalizer = ffi.NativeFinalizer(_deleteFn('wasmtime_store_delete'));
  late final moduleFinalizer = ffi.NativeFinalizer(_deleteFn('wasmtime_module_delete'));
  late final linkerFinalizer = ffi.NativeFinalizer(_deleteFn('wasmtime_linker_delete'));
}
```

`wasmtime_dart/lib/wasmtime_dart.dart`:

```dart
export 'src/library.dart';
export 'src/trap.dart';
```

- [ ] **Step 5: Run the tests**

Run: `cd wasmtime_dart && dart test test/library_test.dart`
Expected: 3 PASS.

- [ ] **Step 6: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): library loading + error/trap primitives

WasmtimeLibrary verifies a sentinel symbol at open so a version-
mismatched libwasmtime fails with an actionable message instead of a
lookup crash mid-call. Trap codes are transcribed from trap.h and
carried on WasmTrap so callers can tell fuel exhaustion and epoch
interrupts apart from guest faults.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 3: Values and function types

**Files:**

- Create: `wasmtime_dart/lib/src/value.dart`, `wasmtime_dart/test/value_test.dart`
- Modify: `wasmtime_dart/lib/wasmtime_dart.dart` (add `export 'src/value.dart';`)

**Interfaces:**

- Consumes: generated `wasmtime_val_t` struct.
- Produces: `ValType` enum (`i32,i64,f32,f64,v128`; `int native` getter; `static ValType fromNative(int)`); sealed `Val` with subclasses `ValI32(int value)`, `ValI64(int value)`, `ValF32(double value)`, `ValF64(double value)`, `ValV128(Uint8List value)`; `Val.writeTo(Pointer<wasmtime_val_t>)`; `static Val Val.readFrom(Pointer<wasmtime_val_t>)`; `FuncType({required List<ValType> params, required List<ValType> results})`.

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/value_test.dart`:

```dart
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:wasmtime_dart/src/generated/raw.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

void main() {
  Val roundtrip(Val v) {
    final p = calloc<wasmtime_val_t>();
    try {
      v.writeTo(p);
      return Val.readFrom(p);
    } finally {
      calloc.free(p);
    }
  }

  test('i32/i64/f32/f64 round-trip through wasmtime_val_t', () {
    expect((roundtrip(ValI32(-42)) as ValI32).value, -42);
    expect((roundtrip(ValI64(1 << 62)) as ValI64).value, 1 << 62);
    expect((roundtrip(ValF32(1.5)) as ValF32).value, 1.5);
    expect((roundtrip(ValF64(-2.25)) as ValF64).value, -2.25);
  });

  test('v128 round-trips 16 bytes', () {
    final bytes = Uint8List.fromList(List.generate(16, (i) => i * 3 & 0xff));
    expect((roundtrip(ValV128(bytes)) as ValV128).value, bytes);
  });

  test('v128 requires exactly 16 bytes', () {
    expect(() => ValV128(Uint8List(4)), throwsArgumentError);
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/value_test.dart`
Expected: FAIL — `Val` undefined.

- [ ] **Step 3: Implement value.dart**

```dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'generated/raw.dart';

/// Value kinds, matching wasmtime/val.h (v46) and wasm.h valkinds.
enum ValType {
  i32(0, 0),
  i64(1, 1),
  f32(2, 2),
  f64(3, 3),
  v128(4, -1); // no wasm_valkind for v128 → not usable in FuncType

  const ValType(this.native, this.valkind);

  /// wasmtime_valkind_t value (wasmtime_val_t.kind).
  final int native;

  /// wasm_valkind_t value for wasm_valtype_new, -1 if unsupported.
  final int valkind;

  static ValType fromNative(int kind) => switch (kind) {
        0 => i32,
        1 => i64,
        2 => f32,
        3 => f64,
        4 => v128,
        _ => throw ArgumentError('unsupported wasmtime_valkind: $kind'),
      };
}

/// A wasm value. Dart ints are 64-bit signed, so i64 is lossless.
sealed class Val {
  const Val();
  ValType get type;

  void writeTo(ffi.Pointer<wasmtime_val_t> ptr) {
    ptr.ref.kind = type.native;
    switch (this) {
      case ValI32(:final value):
        ptr.ref.of.i32 = value;
      case ValI64(:final value):
        ptr.ref.of.i64 = value;
      case ValF32(:final value):
        ptr.ref.of.f32 = value;
      case ValF64(:final value):
        ptr.ref.of.f64 = value;
      case ValV128(:final value):
        for (var i = 0; i < 16; i++) {
          ptr.ref.of.v128[i] = value[i];
        }
    }
  }

  static Val readFrom(ffi.Pointer<wasmtime_val_t> ptr) =>
      switch (ValType.fromNative(ptr.ref.kind)) {
        ValType.i32 => ValI32(ptr.ref.of.i32),
        ValType.i64 => ValI64(ptr.ref.of.i64),
        ValType.f32 => ValF32(ptr.ref.of.f32),
        ValType.f64 => ValF64(ptr.ref.of.f64),
        ValType.v128 => ValV128(
            Uint8List.fromList([for (var i = 0; i < 16; i++) ptr.ref.of.v128[i]])),
      };
}

class ValI32 extends Val {
  const ValI32(this.value);
  final int value;
  @override
  ValType get type => ValType.i32;
}

class ValI64 extends Val {
  const ValI64(this.value);
  final int value;
  @override
  ValType get type => ValType.i64;
}

class ValF32 extends Val {
  const ValF32(this.value);
  final double value;
  @override
  ValType get type => ValType.f32;
}

class ValF64 extends Val {
  const ValF64(this.value);
  final double value;
  @override
  ValType get type => ValType.f64;
}

class ValV128 extends Val {
  ValV128(this.value) {
    if (value.length != 16) {
      throw ArgumentError('v128 requires exactly 16 bytes');
    }
  }
  final Uint8List value;
  @override
  ValType get type => ValType.v128;
}

/// A host-defined function signature (numeric types only — v128 params
/// are not expressible through wasm_valtype_new).
class FuncType {
  FuncType({required this.params, required this.results}) {
    for (final t in [...params, ...results]) {
      if (t.valkind < 0) {
        throw ArgumentError('${t.name} is not supported in FuncType');
      }
    }
  }
  final List<ValType> params;
  final List<ValType> results;
}
```

Adaptation note: if the generated `v128` field is an `Array<Uint8>` under a different accessor (e.g. a wrapper struct), adapt the two v128 loops.

- [ ] **Step 4: Run the tests**

Run: `cd wasmtime_dart && dart test test/value_test.dart`
Expected: 3 PASS.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): Val/ValType/FuncType marshaling

Sealed Val variants write to and read from wasmtime_val_t directly.
v128 is carried as 16 bytes but rejected in FuncType because wasm.h
has no valkind for it — guest v128 exports still work, host-defined
v128 params don't (documented limitation).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 4: Engine and Store

**Files:**

- Create: `wasmtime_dart/lib/src/engine.dart`, `wasmtime_dart/lib/src/store.dart`, `wasmtime_dart/test/helpers.dart`, `wasmtime_dart/test/engine_store_test.dart`
- Modify: `wasmtime_dart/lib/wasmtime_dart.dart` (add `export 'src/engine.dart'; export 'src/store.dart';`)

**Interfaces:**

- Consumes: `WasmtimeLibrary`, `checkError`.
- Produces: `EngineConfig({bool consumeFuel = false, bool epochInterruption = false})`; `Engine(WasmtimeLibrary lib, {EngineConfig? config})` with `lib`, `ptr` (throws `StateError` after dispose), `rawAddress`, `incrementEpoch()`, `dispose()`; `Store(Engine engine)` with `context` (`Context`), `dispose()`; `Context` with `ptr`, `lib`, `setFuel(int)`, `setEpochDeadline(int)`. Test helper `testLib()`.

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/helpers.dart`:

```dart
import 'package:wasmtime_dart/wasmtime_dart.dart';

WasmtimeLibrary? _lib;

/// Shared library instance for all tests (resolved via WASMTIME_DART_LIB).
WasmtimeLibrary testLib() => _lib ??= WasmtimeLibrary.discover();
```

`wasmtime_dart/test/engine_store_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

void main() {
  test('engine + store round-trip', () {
    final engine = Engine(testLib());
    final store = Store(engine);
    expect(store.context.ptr.address, isNonZero);
    store.dispose();
    engine.dispose();
  });

  test('setFuel works on a fuel-metered engine', () {
    final engine =
        Engine(testLib(), config: EngineConfig(consumeFuel: true));
    final store = Store(engine);
    store.context.setFuel(1000); // must not throw
    store.dispose();
    engine.dispose();
  });

  test('setFuel on a non-fueled engine throws WasmtimeError', () {
    final engine = Engine(testLib());
    final store = Store(engine);
    expect(() => store.context.setFuel(1000), throwsA(isA<WasmtimeError>()));
    store.dispose();
    engine.dispose();
  });

  test('dispose is idempotent; use-after-dispose throws StateError', () {
    final engine = Engine(testLib());
    engine.dispose();
    engine.dispose(); // no-op
    expect(() => engine.ptr, throwsStateError);
    expect(() => Store(engine), throwsStateError);
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/engine_store_test.dart`
Expected: FAIL — `Engine` undefined.

- [ ] **Step 3: Implement engine.dart and store.dart**

`wasmtime_dart/lib/src/engine.dart` (EpochTicker is added in Task 10; this file starts with just the engine):

```dart
import 'dart:ffi' as ffi;

import 'generated/raw.dart';
import 'library.dart';
import 'trap.dart';

/// Engine-level toggles. Both default off; fuel and epochs each add a
/// small execution overhead.
class EngineConfig {
  const EngineConfig({this.consumeFuel = false, this.epochInterruption = false});
  final bool consumeFuel;
  final bool epochInterruption;
}

/// Owns a wasm_engine_t. Thread-safe to share per wasmtime docs; in this
/// binding it stays on one isolate except for epoch increments.
class Engine {
  Engine(this.lib, {EngineConfig config = const EngineConfig()}) {
    final raw = lib.raw;
    final cfg = raw.wasm_config_new();
    if (config.consumeFuel) raw.wasmtime_config_consume_fuel_set(cfg, true);
    if (config.epochInterruption) {
      raw.wasmtime_config_epoch_interruption_set(cfg, true);
    }
    _ptr = raw.wasm_engine_new_with_config(cfg); // consumes cfg
    if (_ptr == ffi.nullptr) {
      throw WasmtimeError('wasm_engine_new_with_config returned null');
    }
    lib.engineFinalizer.attach(this, _ptr.cast(), detach: this);
  }

  final WasmtimeLibrary lib;
  late final ffi.Pointer<wasm_engine_t> _ptr;
  bool _disposed = false;

  ffi.Pointer<wasm_engine_t> get ptr {
    if (_disposed) throw StateError('Engine used after dispose()');
    return _ptr;
  }

  /// Address for cross-isolate epoch ticking (Task 10).
  int get rawAddress => ptr.address;

  void incrementEpoch() => lib.raw.wasmtime_engine_increment_epoch(ptr);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    lib.engineFinalizer.detach(this);
    lib.raw.wasm_engine_delete(_ptr);
  }
}
```

`wasmtime_dart/lib/src/store.dart`:

```dart
import 'dart:ffi' as ffi;

import 'engine.dart';
import 'generated/raw.dart';
import 'library.dart';
import 'trap.dart';

/// Owns a wasmtime_store_t. Everything created against its [context]
/// (instances, funcs, memories) is only valid while the store lives.
class Store {
  Store(this.engine) {
    _ptr = engine.lib.raw
        .wasmtime_store_new(engine.ptr, ffi.nullptr, ffi.nullptr);
    if (_ptr == ffi.nullptr) {
      throw WasmtimeError('wasmtime_store_new returned null');
    }
    engine.lib.storeFinalizer.attach(this, _ptr.cast(), detach: this);
    context =
        Context.borrowed(engine.lib, engine.lib.raw.wasmtime_store_context(_ptr));
  }

  final Engine engine;
  late final ffi.Pointer<wasmtime_store_t> _ptr;
  late final Context context;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    engine.lib.storeFinalizer.detach(this);
    engine.lib.raw.wasmtime_store_delete(_ptr);
  }
}

/// Borrowed store context — NOT owned; lifetime == its Store.
class Context {
  Context.borrowed(this.lib, this.ptr);

  final WasmtimeLibrary lib;
  final ffi.Pointer<wasmtime_context_t> ptr;

  /// Requires an engine with `consumeFuel: true`.
  void setFuel(int fuel) =>
      checkError(lib.raw, lib.raw.wasmtime_context_set_fuel(ptr, fuel), 'set_fuel');

  /// Requires an engine with `epochInterruption: true`. Ticks are
  /// relative to the engine's current epoch.
  void setEpochDeadline(int ticks) =>
      lib.raw.wasmtime_context_set_epoch_deadline(ptr, ticks);
}
```

- [ ] **Step 4: Run the tests**

Run: `cd wasmtime_dart && dart test test/engine_store_test.dart`
Expected: 4 PASS.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): Engine and Store with dispose semantics

Owning handles pair a NativeFinalizer (leak safety net) with explicit
dispose() (deterministic teardown for tests); use-after-dispose is a
StateError instead of a native crash. Context is deliberately a
borrowed view — its lifetime is the Store's, matching the C API.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 5: Module compile / serialize

**Files:**

- Create: `wasmtime_dart/lib/src/module.dart`, `wasmtime_dart/test/module_test.dart`
- Modify: `wasmtime_dart/lib/wasmtime_dart.dart` (add `export 'src/module.dart';`)

**Interfaces:**

- Consumes: `Engine`, `checkError`, `readAndDeleteByteVec`.
- Produces: `Module.fromWasm(Engine, Uint8List)`, `Module.fromWat(Engine, String)`, `module.serialize() → Uint8List`, `Module.deserialize(Engine, Uint8List)`, `Module.deserializeFile(Engine, String path)`, `module.ptr`, `module.dispose()`. Also `watToWasm(Engine, String) → Uint8List` (used by fromWat, exposed for tests).

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/module_test.dart`:

```dart
import 'dart:io';

import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const addWat = '''
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
''';

void main() {
  late Engine engine;
  setUp(() => engine = Engine(testLib()));
  tearDown(() => engine.dispose());

  test('fromWat compiles a valid module', () {
    final m = Module.fromWat(engine, addWat);
    expect(m.ptr.address, isNonZero);
    m.dispose();
  });

  test('invalid WAT throws WasmtimeError with a message', () {
    expect(
      () => Module.fromWat(engine, '(module (this is not wat'),
      throwsA(isA<WasmtimeError>()
          .having((e) => e.message, 'message', isNotEmpty)),
    );
  });

  test('serialize → deserialize round-trip', () {
    final m = Module.fromWat(engine, addWat);
    final bytes = m.serialize();
    expect(bytes, isNotEmpty);
    final m2 = Module.deserialize(engine, bytes);
    expect(m2.ptr.address, isNonZero);
    m.dispose();
    m2.dispose();
  });

  test('deserializeFile loads a serialized module from disk', () {
    final m = Module.fromWat(engine, addWat);
    final f = File('${Directory.systemTemp.path}/wasmtime_dart_mod_test.bin')
      ..writeAsBytesSync(m.serialize());
    final m2 = Module.deserializeFile(engine, f.path);
    expect(m2.ptr.address, isNonZero);
    m.dispose();
    m2.dispose();
    f.deleteSync();
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/module_test.dart`
Expected: FAIL — `Module` undefined.

- [ ] **Step 3: Implement module.dart**

```dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engine.dart';
import 'generated/raw.dart';
import 'trap.dart';

/// Converts WebAssembly text format to binary (wasmtime_wat2wasm).
Uint8List watToWasm(Engine engine, String wat) {
  final raw = engine.lib.raw;
  final watBytes = wat.toNativeUtf8();
  final vec = calloc<wasm_byte_vec_t>();
  try {
    checkError(
        raw,
        raw.wasmtime_wat2wasm(watBytes.cast(), watBytes.length, vec),
        'wat2wasm');
    final out = Uint8List.fromList(
        vec.ref.data.cast<ffi.Uint8>().asTypedList(vec.ref.size));
    raw.wasm_byte_vec_delete(vec);
    return out;
  } finally {
    calloc.free(vec);
    calloc.free(watBytes);
  }
}

/// A compiled module, tied to its Engine (not to any Store).
class Module {
  Module._(this.engine, this._ptr) {
    engine.lib.moduleFinalizer.attach(this, _ptr.cast(), detach: this);
  }

  factory Module.fromWasm(Engine engine, Uint8List wasm) {
    final raw = engine.lib.raw;
    final bytes = calloc<ffi.Uint8>(wasm.length);
    bytes.asTypedList(wasm.length).setAll(0, wasm);
    final out = calloc<ffi.Pointer<wasmtime_module_t>>();
    try {
      checkError(raw,
          raw.wasmtime_module_new(engine.ptr, bytes, wasm.length, out),
          'module_new');
      return Module._(engine, out.value);
    } finally {
      calloc.free(bytes);
      calloc.free(out);
    }
  }

  factory Module.fromWat(Engine engine, String wat) =>
      Module.fromWasm(engine, watToWasm(engine, wat));

  factory Module.deserialize(Engine engine, Uint8List bytes) {
    final raw = engine.lib.raw;
    final buf = calloc<ffi.Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    final out = calloc<ffi.Pointer<wasmtime_module_t>>();
    try {
      checkError(raw,
          raw.wasmtime_module_deserialize(engine.ptr, buf, bytes.length, out),
          'module_deserialize');
      return Module._(engine, out.value);
    } finally {
      calloc.free(buf);
      calloc.free(out);
    }
  }

  factory Module.deserializeFile(Engine engine, String path) {
    final raw = engine.lib.raw;
    final pathBytes = path.toNativeUtf8();
    final out = calloc<ffi.Pointer<wasmtime_module_t>>();
    try {
      checkError(raw,
          raw.wasmtime_module_deserialize_file(engine.ptr, pathBytes.cast(), out),
          'module_deserialize_file');
      return Module._(engine, out.value);
    } finally {
      calloc.free(pathBytes);
      calloc.free(out);
    }
  }

  final Engine engine;
  final ffi.Pointer<wasmtime_module_t> _ptr;
  bool _disposed = false;

  ffi.Pointer<wasmtime_module_t> get ptr {
    if (_disposed) throw StateError('Module used after dispose()');
    return _ptr;
  }

  /// Compile-once caching: persist the result and load it back with
  /// [Module.deserialize]/[Module.deserializeFile] (same wasmtime + CPU).
  Uint8List serialize() {
    final raw = engine.lib.raw;
    final vec = calloc<wasm_byte_vec_t>();
    try {
      checkError(raw, raw.wasmtime_module_serialize(ptr, vec), 'module_serialize');
      final out = Uint8List.fromList(
          vec.ref.data.cast<ffi.Uint8>().asTypedList(vec.ref.size));
      raw.wasm_byte_vec_delete(vec);
      return out;
    } finally {
      calloc.free(vec);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    engine.lib.moduleFinalizer.detach(this);
    engine.lib.raw.wasmtime_module_delete(_ptr);
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd wasmtime_dart && dart test test/module_test.dart`
Expected: 4 PASS.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): Module compile + serialize round-trip

fromWat goes through the library's own wat2wasm so tests never need an
external wasm toolchain. serialize/deserialize(File) exist for the
compile-once cache the Pi will want — JIT-compiling a plugin on every
action would dominate its runtime there.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 6: Linker, Instance, and checked function calls

**Files:**

- Create: `wasmtime_dart/lib/src/linker.dart`, `wasmtime_dart/lib/src/instance.dart`, `wasmtime_dart/lib/src/func.dart`, `wasmtime_dart/test/call_test.dart`
- Modify: `wasmtime_dart/lib/wasmtime_dart.dart` (add exports for the three new files)

**Interfaces:**

- Consumes: `Engine`, `Context`, `Module`, `Val`/`ValType`, `checkError`/`checkTrap`.
- Produces: `Linker(Engine)` with `defineWasi()`, `instantiate(Context, Module) → Instance`, `dispose()`; `Instance.getFunc(Context, String name) → Func` (throws `WasmtimeError` if missing/not a func); `Func.call(Context, [List<Val> args]) → List<Val>` (checked: `ArgumentError` on arity/type mismatch, `WasmTrap` on trap).
- Key implementation rule: by-value C handles (`wasmtime_instance_t`, `wasmtime_func_t`) are kept in **calloc'd native memory owned by the Dart wrapper** (freed by a `Finalizer`), and copied out of externs with struct assignment (`dst.ref = src`) — never by reading `__private` fields, whose generated names may vary.

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/call_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const addWat = '''
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
''';

const mixWat = '''
(module
  (func (export "mix") (param i64 f64) (result i64)
    local.get 0
    local.get 1
    i64.trunc_f64_s
    i64.add))
''';

const boomWat = '(module (func (export "boom") unreachable))';

void main() {
  late Engine engine;
  late Store store;
  late Linker linker;
  setUp(() {
    engine = Engine(testLib());
    store = Store(engine);
    linker = Linker(engine);
  });
  tearDown(() {
    linker.dispose();
    store.dispose();
    engine.dispose();
  });

  Instance inst(String wat) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m);
  }

  test('i32 add', () {
    final add = inst(addWat).getFunc(store.context, 'add');
    final out = add.call(store.context, [ValI32(20), ValI32(22)]);
    expect((out.single as ValI32).value, 42);
  });

  test('i64/f64 params and i64 result', () {
    final mix = inst(mixWat).getFunc(store.context, 'mix');
    final out = mix.call(store.context, [ValI64(5), ValF64(2.0)]);
    expect((out.single as ValI64).value, 7);
  });

  test('deserialized module is callable', () {
    final m = Module.fromWat(engine, addWat);
    final m2 = Module.deserialize(engine, m.serialize());
    final add = linker.instantiate(store.context, m2).getFunc(store.context, 'add');
    expect((add.call(store.context, [ValI32(1), ValI32(2)]).single as ValI32).value, 3);
    m.dispose();
    m2.dispose();
  });

  test('missing export throws WasmtimeError', () {
    expect(() => inst(addWat).getFunc(store.context, 'nope'),
        throwsA(isA<WasmtimeError>()));
  });

  test('wrong arity and wrong type throw ArgumentError', () {
    final add = inst(addWat).getFunc(store.context, 'add');
    expect(() => add.call(store.context, [ValI32(1)]), throwsArgumentError);
    expect(() => add.call(store.context, [ValI32(1), ValF64(2.0)]),
        throwsArgumentError);
  });

  test('unreachable traps with TrapCode.unreachable', () {
    final boom = inst(boomWat).getFunc(store.context, 'boom');
    expect(
      () => boom.call(store.context),
      throwsA(isA<WasmTrap>()
          .having((t) => t.code, 'code', TrapCode.unreachable)),
    );
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/call_test.dart`
Expected: FAIL — `Linker` undefined.

- [ ] **Step 3: Implement linker.dart, instance.dart, func.dart**

`wasmtime_dart/lib/src/linker.dart`:

```dart
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'engine.dart';
import 'func.dart';
import 'generated/raw.dart';
import 'instance.dart';
import 'module.dart';
import 'store.dart';
import 'trap.dart';

/// Owns a wasmtime_linker_t. defineFunc arrives in the host-function
/// task; this file only grows there, its interface here is final.
class Linker {
  Linker(this.engine) {
    _ptr = engine.lib.raw.wasmtime_linker_new(engine.ptr);
    engine.lib.linkerFinalizer.attach(this, _ptr.cast(), detach: this);
  }

  final Engine engine;
  late final ffi.Pointer<wasmtime_linker_t> _ptr;
  bool _disposed = false;

  ffi.Pointer<wasmtime_linker_t> get ptr {
    if (_disposed) throw StateError('Linker used after dispose()');
    return _ptr;
  }

  /// Adds the WASI Preview1 import surface (pair with Context.setWasi).
  void defineWasi() => checkError(
      engine.lib.raw, engine.lib.raw.wasmtime_linker_define_wasi(ptr), 'define_wasi');

  Instance instantiate(Context context, Module module) {
    final raw = engine.lib.raw;
    final instancePtr = calloc<wasmtime_instance_t>();
    final trapOut = calloc<ffi.Pointer<wasm_trap_t>>();
    try {
      checkError(
          raw,
          raw.wasmtime_linker_instantiate(
              ptr, context.ptr, module.ptr, instancePtr, trapOut),
          'linker_instantiate');
      checkTrap(raw, trapOut.value);
    } catch (_) {
      calloc.free(instancePtr);
      rethrow;
    } finally {
      calloc.free(trapOut);
    }
    return Instance.owned(engine.lib, instancePtr);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    engine.lib.linkerFinalizer.detach(this);
    engine.lib.raw.wasmtime_linker_delete(_ptr);
  }
}
```

`wasmtime_dart/lib/src/instance.dart`:

```dart
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'func.dart';
import 'generated/raw.dart';
import 'library.dart';
import 'store.dart';
import 'trap.dart';

/// Frees calloc'd native handle memory when the wrapper is collected.
final nativeAllocFinalizer =
    Finalizer<ffi.Pointer<ffi.NativeType>>((p) => calloc.free(p.cast()));

/// A by-value wasmtime_instance_t kept in Dart-owned native memory.
/// Valid only while its Store lives.
class Instance {
  Instance.owned(this.lib, this.handle) {
    nativeAllocFinalizer.attach(this, handle);
  }

  final WasmtimeLibrary lib;
  final ffi.Pointer<wasmtime_instance_t> handle;

  /// Looks up export [name]; returns the raw extern in [item]. Caller
  /// owns [item]'s allocation.
  bool exportGet(
      Context context, String name, ffi.Pointer<wasmtime_extern_t> item) {
    final nameBytes = name.toNativeUtf8();
    try {
      return lib.raw.wasmtime_instance_export_get(
          context.ptr, handle, nameBytes.cast(), nameBytes.length, item);
    } finally {
      calloc.free(nameBytes);
    }
  }

  Func getFunc(Context context, String name) {
    final item = calloc<wasmtime_extern_t>();
    try {
      // WASMTIME_EXTERN_FUNC == 0 (wasmtime/extern.h).
      if (!exportGet(context, name, item) || item.ref.kind != 0) {
        throw WasmtimeError('export `$name` not found or not a function');
      }
      final funcPtr = calloc<wasmtime_func_t>();
      funcPtr.ref = item.ref.of.func; // struct copy, no private-field access
      return Func.owned(lib, funcPtr);
    } finally {
      calloc.free(item);
    }
  }
}
```

`wasmtime_dart/lib/src/func.dart`:

```dart
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'generated/raw.dart';
import 'instance.dart';
import 'library.dart';
import 'store.dart';
import 'trap.dart';
import 'value.dart';

/// A by-value wasmtime_func_t kept in Dart-owned native memory.
class Func {
  Func.owned(this.lib, this.handle) {
    nativeAllocFinalizer.attach(this, handle);
  }

  final WasmtimeLibrary lib;
  final ffi.Pointer<wasmtime_func_t> handle;

  /// Reads (params, results) types; frees the owned functype.
  (List<ValType>, List<ValType>) signature(Context context) {
    final raw = lib.raw;
    final ty = raw.wasmtime_func_type(context.ptr, handle);
    List<ValType> readVec(ffi.Pointer<wasm_valtype_vec_t> vec) => [
          for (var i = 0; i < vec.ref.size; i++)
            ValType.fromNative(raw.wasm_valtype_kind(vec.ref.data[i])),
        ];
    try {
      return (
        readVec(raw.wasm_functype_params(ty)),
        readVec(raw.wasm_functype_results(ty)),
      );
    } finally {
      raw.wasm_functype_delete(ty);
    }
  }

  /// Checked call: validates arity and types against the wasm signature.
  List<Val> call(Context context, [List<Val> args = const []]) {
    final raw = lib.raw;
    final (params, results) = signature(context);
    if (args.length != params.length) {
      throw ArgumentError(
          'expected ${params.length} args, got ${args.length}');
    }
    for (var i = 0; i < args.length; i++) {
      if (args[i].type != params[i]) {
        throw ArgumentError(
            'arg $i: expected ${params[i].name}, got ${args[i].type.name}');
      }
    }
    final argsPtr = calloc<wasmtime_val_t>(args.isEmpty ? 1 : args.length);
    final resultsPtr =
        calloc<wasmtime_val_t>(results.isEmpty ? 1 : results.length);
    final trapOut = calloc<ffi.Pointer<wasm_trap_t>>();
    try {
      for (var i = 0; i < args.length; i++) {
        args[i].writeTo(argsPtr + i);
      }
      checkError(
          raw,
          raw.wasmtime_func_call(context.ptr, handle, argsPtr, args.length,
              resultsPtr, results.length, trapOut),
          'func_call');
      checkTrap(raw, trapOut.value);
      return [
        for (var i = 0; i < results.length; i++) Val.readFrom(resultsPtr + i),
      ];
    } finally {
      calloc.free(argsPtr);
      calloc.free(resultsPtr);
      calloc.free(trapOut);
    }
  }
}
```

Adaptation notes: `wasm_valtype_vec_t.data[i]` indexes a `Pointer<Pointer<wasm_valtype_t>>`; if ffigen typed it differently, adjust the index expression. `unreachable` maps to `TrapCode.unreachable` (9).

- [ ] **Step 4: Run the tests**

Run: `cd wasmtime_dart && dart test test/call_test.dart`
Expected: 7 PASS.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): Linker/Instance and checked Func.call

By-value C handles live in Dart-owned calloc'd memory and are copied
out of externs with struct assignment, so the wrapper never touches
__private fields whose generated names could drift. Calls are checked
against the wasm signature — a mis-typed call is an ArgumentError at
the boundary, not memory corruption inside the JIT.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 7: Host functions (defineFunc, Caller, exception→trap, reentrancy)

**Files:**

- Create: `wasmtime_dart/test/host_func_test.dart`
- Modify: `wasmtime_dart/lib/src/func.dart` (trampoline, registry, `Caller`), `wasmtime_dart/lib/src/linker.dart` (`defineFunc`)

**Interfaces:**

- Consumes: `Linker`, `Func`, `FuncType`, `Val`, `checkError`.
- Produces: `typedef HostFunc = List<Val> Function(Caller caller, List<Val> args)`; `Linker.defineFunc(String module, String name, FuncType type, HostFunc fn)`; `Caller` with `context → Context` and `getFunc(String name) → Func`.
- Threading contract (from the spike): host functions are invoked on the calling isolate's thread — one static `NativeCallable.isolateLocal` trampoline serves all registrations; the C `env` pointer carries a registry index.

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/host_func_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const useAddWat = '''
(module
  (import "env" "mul_add" (func \$ma (param i32 i32) (result i32)))
  (func (export "run") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    call \$ma))
''';

const mixHostWat = '''
(module
  (import "env" "mix" (func \$m (param i64 f64) (result i64)))
  (func (export "run") (param i64 f64) (result i64)
    local.get 0
    local.get 1
    call \$m))
''';

const splitWat = '''
(module
  (import "env" "split" (func \$s (param i32) (result i32 i32)))
  (func (export "sum") (param i32) (result i32)
    local.get 0
    call \$s
    i32.add))
''';

const reentrantWat = '''
(module
  (import "env" "h" (func \$h (param i32) (result i32)))
  (func (export "double") (param i32) (result i32)
    local.get 0
    i32.const 2
    i32.mul)
  (func (export "run") (param i32) (result i32)
    local.get 0
    call \$h))
''';

void main() {
  late Engine engine;
  late Store store;
  late Linker linker;
  setUp(() {
    engine = Engine(testLib());
    store = Store(engine);
    linker = Linker(engine);
  });
  tearDown(() {
    linker.dispose();
    store.dispose();
    engine.dispose();
  });

  Func instFunc(String wat, String name) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m).getFunc(store.context, name);
  }

  test('i32 host function round-trip', () {
    linker.defineFunc(
      'env', 'mul_add',
      FuncType(params: [ValType.i32, ValType.i32], results: [ValType.i32]),
      (caller, args) =>
          [ValI32((args[0] as ValI32).value * 10 + (args[1] as ValI32).value)],
    );
    final run = instFunc(useAddWat, 'run');
    expect((run.call(store.context, [ValI32(4), ValI32(5)]).single as ValI32).value, 45);
  });

  test('i64/f64 host function round-trip', () {
    linker.defineFunc(
      'env', 'mix',
      FuncType(params: [ValType.i64, ValType.f64], results: [ValType.i64]),
      (caller, args) => [
        ValI64((args[0] as ValI64).value + (args[1] as ValF64).value.toInt())
      ],
    );
    final run = instFunc(mixHostWat, 'run');
    expect((run.call(store.context, [ValI64(1 << 40), ValF64(2.0)]).single as ValI64).value,
        (1 << 40) + 2);
  });

  test('multi-value host results', () {
    linker.defineFunc(
      'env', 'split',
      FuncType(params: [ValType.i32], results: [ValType.i32, ValType.i32]),
      (caller, args) => [args[0], ValI32(1)],
    );
    final sum = instFunc(splitWat, 'sum');
    expect((sum.call(store.context, [ValI32(41)]).single as ValI32).value, 42);
  });

  test('Dart exception becomes a WasmTrap with the message', () {
    linker.defineFunc(
      'env', 'mul_add',
      FuncType(params: [ValType.i32, ValType.i32], results: [ValType.i32]),
      (caller, args) => throw StateError('boom from dart'),
    );
    final run = instFunc(useAddWat, 'run');
    expect(
      () => run.call(store.context, [ValI32(1), ValI32(2)]),
      throwsA(isA<WasmTrap>()
          .having((t) => t.message, 'message', contains('boom from dart'))),
    );
  });

  test('reentrancy: host function calls back into the guest', () {
    linker.defineFunc(
      'env', 'h',
      FuncType(params: [ValType.i32], results: [ValType.i32]),
      (caller, args) {
        final dbl = caller.getFunc('double');
        final doubled = dbl.call(caller.context, [args[0]]).single as ValI32;
        return [ValI32(doubled.value + 1)];
      },
    );
    final run = instFunc(reentrantWat, 'run');
    expect((run.call(store.context, [ValI32(5)]).single as ValI32).value, 11);
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/host_func_test.dart`
Expected: FAIL — `defineFunc` undefined.

- [ ] **Step 3: Add the trampoline, registry, and Caller to func.dart**

Append to `wasmtime_dart/lib/src/func.dart` (new imports: `dart:convert` for utf8 is NOT needed; add `value.dart` already imported):

```dart
/// A Dart-implemented wasm import. Runs on the calling isolate's thread.
/// Return exactly the declared result values; throw to trap the guest.
typedef HostFunc = List<Val> Function(Caller caller, List<Val> args);

/// Registered host function state, keyed by the C env pointer's address.
class HostFuncRegistry {
  static final Map<int, HostFuncEntry> entries = {};
  static int _nextId = 1;

  static int register(HostFuncEntry entry) {
    final id = _nextId++;
    entries[id] = entry;
    return id;
  }
}

class HostFuncEntry {
  HostFuncEntry(this.lib, this.type, this.fn);
  final WasmtimeLibrary lib;
  final FuncType type;
  final HostFunc fn;
}

/// wasmtime_func_callback_t.
typedef HostCallbackNative = ffi.Pointer<wasm_trap_t> Function(
  ffi.Pointer<ffi.Void> env,
  ffi.Pointer<wasmtime_caller_t> caller,
  ffi.Pointer<wasmtime_val_t> args,
  ffi.UintPtr nargs,
  ffi.Pointer<wasmtime_val_t> results,
  ffi.UintPtr nresults,
);

ffi.Pointer<wasm_trap_t> _hostTrampoline(
  ffi.Pointer<ffi.Void> env,
  ffi.Pointer<wasmtime_caller_t> caller,
  ffi.Pointer<wasmtime_val_t> args,
  int nargs,
  ffi.Pointer<wasmtime_val_t> results,
  int nresults,
) {
  final entry = HostFuncRegistry.entries[env.address]!;
  try {
    final argVals = [for (var i = 0; i < nargs; i++) Val.readFrom(args + i)];
    final out = entry.fn(Caller._(entry.lib, caller), argVals);
    if (out.length != nresults) {
      throw StateError(
          'host function returned ${out.length} values, expected $nresults');
    }
    for (var i = 0; i < nresults; i++) {
      if (out[i].type != entry.type.results[i]) {
        throw StateError(
            'host result $i: expected ${entry.type.results[i].name}, '
            'got ${out[i].type.name}');
      }
      out[i].writeTo(results + i);
    }
    return ffi.nullptr;
  } catch (e) {
    final raw = entry.lib.raw;
    final msg = 'host function trapped: $e'.toNativeUtf8();
    final trap = raw.wasmtime_trap_new(msg.cast(), msg.length);
    calloc.free(msg);
    return trap;
  }
}

/// One trampoline serves every host function (env selects the entry).
final hostTrampoline =
    ffi.NativeCallable<HostCallbackNative>.isolateLocal(_hostTrampoline)
      ..keepIsolateAlive = false;

/// Borrowed view of the calling store during a host call. Only valid
/// inside the host function invocation.
class Caller {
  Caller._(this.lib, this._ptr);

  final WasmtimeLibrary lib;
  final ffi.Pointer<wasmtime_caller_t> _ptr;

  Context get context =>
      Context.borrowed(lib, lib.raw.wasmtime_caller_context(_ptr));

  /// Looks up one of the calling instance's exports as a function.
  Func getFunc(String name) {
    final nameBytes = name.toNativeUtf8();
    final item = calloc<wasmtime_extern_t>();
    try {
      final found = lib.raw.wasmtime_caller_export_get(
          _ptr, nameBytes.cast(), nameBytes.length, item);
      // WASMTIME_EXTERN_FUNC == 0.
      if (!found || item.ref.kind != 0) {
        throw WasmtimeError('caller export `$name` not found or not a function');
      }
      final funcPtr = calloc<wasmtime_func_t>();
      funcPtr.ref = item.ref.of.func;
      return Func.owned(lib, funcPtr);
    } finally {
      calloc.free(nameBytes);
      calloc.free(item);
    }
  }
}
```

- [ ] **Step 4: Add defineFunc to linker.dart**

Append inside `class Linker` (new import: `value.dart`):

```dart
  /// Defines a Dart host function under `module`.`name`. The FuncType
  /// must match the guest's import declaration exactly.
  void defineFunc(String module, String name, FuncType type, HostFunc fn) {
    final raw = engine.lib.raw;

    ffi.Pointer<wasm_valtype_vec_t> vecOf(List<ValType> types) {
      final vec = calloc<wasm_valtype_vec_t>();
      if (types.isEmpty) {
        raw.wasm_valtype_vec_new_empty(vec);
        return vec;
      }
      final items = calloc<ffi.Pointer<wasm_valtype_t>>(types.length);
      for (var i = 0; i < types.length; i++) {
        items[i] = raw.wasm_valtype_new(types[i].valkind);
      }
      raw.wasm_valtype_vec_new(vec, types.length, items);
      calloc.free(items);
      return vec;
    }

    final params = vecOf(type.params);
    final results = vecOf(type.results);
    final functype = raw.wasm_functype_new(params, results);
    calloc.free(params);
    calloc.free(results);

    final id = HostFuncRegistry.register(HostFuncEntry(engine.lib, type, fn));
    final modBytes = module.toNativeUtf8();
    final nameBytes = name.toNativeUtf8();
    try {
      checkError(
          raw,
          raw.wasmtime_linker_define_func(
              ptr,
              modBytes.cast(),
              modBytes.length,
              nameBytes.cast(),
              nameBytes.length,
              functype,
              hostTrampoline.nativeFunction,
              ffi.Pointer.fromAddress(id),
              ffi.nullptr),
          'linker_define_func');
    } finally {
      calloc.free(modBytes);
      calloc.free(nameBytes);
      raw.wasm_functype_delete(functype); // define_func copies the type
    }
  }
```

Adaptation notes: if the generated `wasmtime_linker_define_func` expects the callback as a plain `Pointer<NativeFunction<...generated typedef...>>`, cast: `hostTrampoline.nativeFunction.cast()`. If `wasm_functype_new` consumes its vec args differently than shown (it takes ownership of the _contents_), keep the `calloc.free(params/results)` — that frees only the vec structs we allocated.

- [ ] **Step 5: Run the tests**

Run: `cd wasmtime_dart && dart test test/host_func_test.dart`
Expected: 5 PASS (including reentrancy).

- [ ] **Step 6: Run the whole suite, analyze, format, commit**

```bash
cd wasmtime_dart && dart test && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): Dart host functions with trap-safe trampoline

One isolateLocal NativeCallable serves every registration; the C env
pointer indexes a Dart-side registry. Exceptions never unwind through
C frames — they become wasmtime traps carrying the message. Caller
exposes the calling instance's exports, which the reentrancy test
(guest -> host -> guest) locks in for future host APIs.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 8: Guest memory access

**Files:**

- Create: `wasmtime_dart/lib/src/memory.dart`, `wasmtime_dart/test/memory_test.dart`
- Modify: `wasmtime_dart/lib/src/instance.dart` (add `getMemory`), `wasmtime_dart/lib/src/func.dart` (add `Caller.getMemory`), `wasmtime_dart/lib/wasmtime_dart.dart` (export)

**Interfaces:**

- Consumes: `Instance.exportGet`, `Context`, `nativeAllocFinalizer`.
- Produces: `Memory` with `sizePages(Context)`, `sizeBytes(Context)`, `readBytes(Context, int offset, int length) → Uint8List`, `writeBytes(Context, int offset, Uint8List bytes)`, `grow(Context, int deltaPages) → int` (previous size); `Instance.getMemory(Context, String name) → Memory`; `Caller.getMemory(String name) → Memory`. Out-of-bounds access throws `RangeError`.

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/memory_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const memWat = '''
(module
  (memory (export "memory") 1)
  (data (i32.const 8) "hi wasm")
  (func (export "peek") (param i32) (result i32)
    local.get 0
    i32.load8_u))
''';

const logWat = '''
(module
  (import "env" "log" (func \$log (param i32 i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "hello")
  (func (export "run")
    i32.const 16
    i32.const 5
    call \$log))
''';

void main() {
  late Engine engine;
  late Store store;
  late Linker linker;
  setUp(() {
    engine = Engine(testLib());
    store = Store(engine);
    linker = Linker(engine);
  });
  tearDown(() {
    linker.dispose();
    store.dispose();
    engine.dispose();
  });

  Instance inst(String wat) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m);
  }

  test('readBytes sees the data segment', () {
    final mem = inst(memWat).getMemory(store.context, 'memory');
    expect(utf8.decode(mem.readBytes(store.context, 8, 7)), 'hi wasm');
  });

  test('writeBytes is visible to the guest', () {
    final i = inst(memWat);
    final mem = i.getMemory(store.context, 'memory');
    mem.writeBytes(store.context, 100, Uint8List.fromList([7]));
    final peek = i.getFunc(store.context, 'peek');
    expect((peek.call(store.context, [ValI32(100)]).single as ValI32).value, 7);
  });

  test('out-of-bounds read throws RangeError', () {
    final mem = inst(memWat).getMemory(store.context, 'memory');
    expect(() => mem.readBytes(store.context, 65536 - 2, 4), throwsRangeError);
  });

  test('grow adds pages and returns the previous size', () {
    final mem = inst(memWat).getMemory(store.context, 'memory');
    expect(mem.grow(store.context, 1), 1);
    expect(mem.sizePages(store.context), 2);
  });

  test('host function reads a guest string via Caller.getMemory', () {
    String? seen;
    linker.defineFunc(
      'env', 'log',
      FuncType(params: [ValType.i32, ValType.i32], results: []),
      (caller, args) {
        final mem = caller.getMemory('memory');
        seen = utf8.decode(mem.readBytes(caller.context,
            (args[0] as ValI32).value, (args[1] as ValI32).value));
        return [];
      },
    );
    inst(logWat).getFunc(store.context, 'run').call(store.context);
    expect(seen, 'hello');
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/memory_test.dart`
Expected: FAIL — `getMemory` undefined.

- [ ] **Step 3: Implement memory.dart**

```dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'generated/raw.dart';
import 'instance.dart';
import 'library.dart';
import 'store.dart';
import 'trap.dart';

/// A by-value wasmtime_memory_t in Dart-owned native memory. Reads and
/// writes are bounds-checked against the CURRENT data size — the data
/// pointer is never cached because growth can move it.
class Memory {
  Memory.owned(this.lib, this.handle) {
    nativeAllocFinalizer.attach(this, handle);
  }

  final WasmtimeLibrary lib;
  final ffi.Pointer<wasmtime_memory_t> handle;

  int sizePages(Context context) =>
      lib.raw.wasmtime_memory_size(context.ptr, handle);

  int sizeBytes(Context context) =>
      lib.raw.wasmtime_memory_data_size(context.ptr, handle);

  void _checkBounds(Context context, int offset, int length) {
    final max = sizeBytes(context);
    if (offset < 0 || length < 0 || offset + length > max) {
      throw RangeError(
          'memory access [$offset, ${offset + length}) out of bounds (size $max)');
    }
  }

  Uint8List readBytes(Context context, int offset, int length) {
    _checkBounds(context, offset, length);
    final data = lib.raw.wasmtime_memory_data(context.ptr, handle);
    return Uint8List.fromList(
        data.cast<ffi.Uint8>().asTypedList(sizeBytes(context))
            .sublist(offset, offset + length));
  }

  void writeBytes(Context context, int offset, Uint8List bytes) {
    _checkBounds(context, offset, bytes.length);
    final data = lib.raw.wasmtime_memory_data(context.ptr, handle);
    data.cast<ffi.Uint8>().asTypedList(sizeBytes(context))
        .setRange(offset, offset + bytes.length, bytes);
  }

  /// Grows by [deltaPages]; returns the previous size in pages.
  int grow(Context context, int deltaPages) {
    final prevOut = calloc<ffi.Uint64>();
    try {
      checkError(lib.raw,
          lib.raw.wasmtime_memory_grow(context.ptr, handle, deltaPages, prevOut),
          'memory_grow');
      return prevOut.value;
    } finally {
      calloc.free(prevOut);
    }
  }
}
```

(Add `import 'package:ffi/ffi.dart';` for calloc.)

Add to `Instance` in instance.dart:

```dart
  Memory getMemory(Context context, String name) {
    final item = calloc<wasmtime_extern_t>();
    try {
      // WASMTIME_EXTERN_MEMORY == 3 (wasmtime/extern.h).
      if (!exportGet(context, name, item) || item.ref.kind != 3) {
        throw WasmtimeError('export `$name` not found or not a memory');
      }
      final memPtr = calloc<wasmtime_memory_t>();
      memPtr.ref = item.ref.of.memory;
      return Memory.owned(lib, memPtr);
    } finally {
      calloc.free(item);
    }
  }
```

Add to `Caller` in func.dart (same shape, via `wasmtime_caller_export_get`):

```dart
  Memory getMemory(String name) {
    final nameBytes = name.toNativeUtf8();
    final item = calloc<wasmtime_extern_t>();
    try {
      final found = lib.raw.wasmtime_caller_export_get(
          _ptr, nameBytes.cast(), nameBytes.length, item);
      if (!found || item.ref.kind != 3) {
        throw WasmtimeError('caller export `$name` not found or not a memory');
      }
      final memPtr = calloc<wasmtime_memory_t>();
      memPtr.ref = item.ref.of.memory;
      return Memory.owned(lib, memPtr);
    } finally {
      calloc.free(nameBytes);
      calloc.free(item);
    }
  }
```

- [ ] **Step 4: Run the tests**

Run: `cd wasmtime_dart && dart test test/memory_test.dart`
Expected: 5 PASS.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): bounds-checked guest memory access

Memory re-resolves the data pointer and size on every access instead
of caching them — growth can reallocate the backing region, and a
stale pointer would be a use-after-free the type system can't see.
This is the substrate the plugin runtime will use to pass strings.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 9: WASI configuration

**Files:**

- Create: `wasmtime_dart/lib/src/wasi.dart`, `wasmtime_dart/test/wasi_test.dart`
- Modify: `wasmtime_dart/lib/src/store.dart` (add `Context.setWasi`), `wasmtime_dart/lib/wasmtime_dart.dart` (export)

**Interfaces:**

- Consumes: `Context`, `checkError`.
- Produces: `DirPerms{read,write,readWrite}` / `FilePerms{read,write,readWrite}` (bit values 1/2/3); `PreopenDir(String hostPath, String guestPath, {DirPerms dirPerms = .readWrite, FilePerms filePerms = .readWrite})`; `WasiConfig({List<String> args, Map<String,String> env, List<PreopenDir> preopens, String? stdoutFile, String? stderrFile, Uint8List? stdinBytes, bool inheritStdout, bool inheritStderr, bool inheritStdin})` — consumed exactly once; `Context.setWasi(WasiConfig)` (second use throws `StateError`).

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/wasi_test.dart`:

```dart
import 'dart:io';

import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const helloWat = '''
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func \$fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "hello from sandboxed WASI!\\n")
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 16))
    (i32.store (i32.const 4) (i32.const 27))
    (drop (call \$fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))))
''';

/// Writes environ_count as a little-endian u32 to stdout.
const envCountWat = '''
(module
  (import "wasi_snapshot_preview1" "environ_sizes_get"
    (func \$esg (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func \$fdw (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call \$esg (i32.const 0) (i32.const 4)))
    (i32.store (i32.const 8) (i32.const 0))
    (i32.store (i32.const 12) (i32.const 4))
    (drop (call \$fdw (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 16)))))
''';

/// Writes args_count as a little-endian u32 to stdout.
const argCountWat = '''
(module
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func \$asg (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func \$fdw (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call \$asg (i32.const 0) (i32.const 4)))
    (i32.store (i32.const 8) (i32.const 0))
    (i32.store (i32.const 12) (i32.const 4))
    (drop (call \$fdw (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 16)))))
''';

/// try_create opens "out.txt" with O_CREAT against preopen fd 3;
/// returns the raw errno (0 = success).
const pathOpenWat = '''
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func \$po (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "out.txt")
  (func (export "try_create") (result i32)
    (call \$po
      (i32.const 3)              ;; first preopen
      (i32.const 0)              ;; dirflags
      (i32.const 0) (i32.const 7) ;; path "out.txt"
      (i32.const 1)              ;; oflags: CREAT
      (i64.const 0x440)          ;; rights: fd_write | path_create_file
      (i64.const 0)
      (i32.const 0)
      (i32.const 64))))          ;; opened-fd out ptr
''';

void main() {
  late Engine engine;
  late Store store;
  late Linker linker;
  setUp(() {
    engine = Engine(testLib());
    store = Store(engine);
    linker = Linker(engine)..defineWasi();
  });
  tearDown(() {
    linker.dispose();
    store.dispose();
    engine.dispose();
  });

  File tmpFile(String name) =>
      File('${Directory.systemTemp.path}/wasmtime_dart_$name');

  Instance inst(String wat) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m);
  }

  test('hello world with stdout captured to a file', () {
    final out = tmpFile('stdout.txt');
    store.context.setWasi(WasiConfig(args: ['t'], stdoutFile: out.path));
    inst(helloWat).getFunc(store.context, '_start').call(store.context);
    expect(out.readAsStringSync(), 'hello from sandboxed WASI!\n');
    out.deleteSync();
  });

  test('guest sees the configured env vars', () {
    final out = tmpFile('envcount.bin');
    store.context.setWasi(WasiConfig(
        args: ['t'], env: {'A': '1', 'B': '2'}, stdoutFile: out.path));
    inst(envCountWat).getFunc(store.context, '_start').call(store.context);
    expect(out.readAsBytesSync(), [2, 0, 0, 0]);
    out.deleteSync();
  });

  test('guest sees the configured argv', () {
    final out = tmpFile('argcount.bin');
    store.context
        .setWasi(WasiConfig(args: ['a', 'b', 'c'], stdoutFile: out.path));
    inst(argCountWat).getFunc(store.context, '_start').call(store.context);
    expect(out.readAsBytesSync(), [3, 0, 0, 0]);
    out.deleteSync();
  });

  test('read-only preopen rejects file creation; read-write allows it', () {
    int tryCreate(DirPerms dp, FilePerms fp, Directory dir) {
      final e = Engine(testLib());
      final s = Store(e);
      final l = Linker(e)..defineWasi();
      s.context.setWasi(WasiConfig(args: [
        't'
      ], preopens: [
        PreopenDir(dir.path, '/data', dirPerms: dp, filePerms: fp)
      ]));
      final m = Module.fromWat(e, pathOpenWat);
      final errno = (l
              .instantiate(s.context, m)
              .getFunc(s.context, 'try_create')
              .call(s.context)
              .single as ValI32)
          .value;
      m.dispose();
      l.dispose();
      s.dispose();
      e.dispose();
      return errno;
    }

    final roDir = Directory.systemTemp.createTempSync('wasmtime_dart_ro_');
    final rwDir = Directory.systemTemp.createTempSync('wasmtime_dart_rw_');
    addTearDown(() {
      roDir.deleteSync(recursive: true);
      rwDir.deleteSync(recursive: true);
    });

    expect(tryCreate(DirPerms.read, FilePerms.read, roDir), isNot(0),
        reason: 'RO preopen must refuse O_CREAT');
    expect(File('${roDir.path}/out.txt').existsSync(), isFalse);
    expect(tryCreate(DirPerms.readWrite, FilePerms.readWrite, rwDir), 0);
    expect(File('${rwDir.path}/out.txt').existsSync(), isTrue);
  });

  test('a WasiConfig cannot be used twice', () {
    final cfg = WasiConfig(args: ['t']);
    store.context.setWasi(cfg);
    final store2 = Store(engine);
    addTearDown(store2.dispose);
    expect(() => store2.context.setWasi(cfg), throwsStateError);
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/wasi_test.dart`
Expected: FAIL — `WasiConfig` undefined.

- [ ] **Step 3: Implement wasi.dart + Context.setWasi**

`wasmtime_dart/lib/src/wasi.dart`:

```dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'generated/raw.dart';
import 'library.dart';
import 'trap.dart';

/// wasi_dir_perms flags (wasi.h): READ = 1, WRITE = 2.
enum DirPerms {
  read(1),
  write(2),
  readWrite(3);

  const DirPerms(this.native);
  final int native;
}

/// wasi_file_perms flags (wasi.h): READ = 1, WRITE = 2.
enum FilePerms {
  read(1),
  write(2),
  readWrite(3);

  const FilePerms(this.native);
  final int native;
}

/// One host directory exposed to the guest at [guestPath].
class PreopenDir {
  const PreopenDir(this.hostPath, this.guestPath,
      {this.dirPerms = DirPerms.readWrite,
      this.filePerms = FilePerms.readWrite});
  final String hostPath;
  final String guestPath;
  final DirPerms dirPerms;
  final FilePerms filePerms;
}

/// WASI Preview1 configuration. Consumed exactly once by
/// Context.setWasi — the C config is destroyed by wasmtime on use.
/// Custom stdio callbacks are deliberately not exposed: wasmtime-wasi
/// invokes them from tokio worker threads, where Dart isolateLocal
/// callbacks abort the VM. Capture stdio through files.
class WasiConfig {
  WasiConfig({
    this.args = const [],
    this.env = const {},
    this.preopens = const [],
    this.stdoutFile,
    this.stderrFile,
    this.stdinBytes,
    this.inheritStdout = false,
    this.inheritStderr = false,
    this.inheritStdin = false,
  });

  final List<String> args;
  final Map<String, String> env;
  final List<PreopenDir> preopens;
  final String? stdoutFile;
  final String? stderrFile;
  final Uint8List? stdinBytes;
  final bool inheritStdout;
  final bool inheritStderr;
  final bool inheritStdin;
  bool consumed = false;

  /// Builds the native config. Internal — called by Context.setWasi.
  ffi.Pointer<wasi_config_t> buildNative(WasmtimeLibrary lib) {
    if (consumed) {
      throw StateError('WasiConfig was already consumed by setWasi');
    }
    consumed = true;
    final raw = lib.raw;
    final cfg = raw.wasi_config_new();
    final allocs = <ffi.Pointer<ffi.NativeType>>[];
    ffi.Pointer<ffi.Uint8> dup(String s) {
      final p = s.toNativeUtf8();
      allocs.add(p);
      return p.cast();
    }

    try {
      if (args.isNotEmpty) {
        final argv = calloc<ffi.Pointer<ffi.Uint8>>(args.length);
        allocs.add(argv);
        for (var i = 0; i < args.length; i++) {
          argv[i] = dup(args[i]);
        }
        if (!raw.wasi_config_set_argv(cfg, args.length, argv)) {
          throw WasmtimeError('wasi_config_set_argv failed');
        }
      }
      if (env.isNotEmpty) {
        final names = calloc<ffi.Pointer<ffi.Uint8>>(env.length);
        final values = calloc<ffi.Pointer<ffi.Uint8>>(env.length);
        allocs.addAll([names, values]);
        var i = 0;
        for (final MapEntry(:key, :value) in env.entries) {
          names[i] = dup(key);
          values[i] = dup(value);
          i++;
        }
        if (!raw.wasi_config_set_env(cfg, env.length, names, values)) {
          throw WasmtimeError('wasi_config_set_env failed');
        }
      }
      for (final p in preopens) {
        if (!raw.wasi_config_preopen_dir(cfg, dup(p.hostPath).cast(),
            dup(p.guestPath).cast(), p.dirPerms.native, p.filePerms.native)) {
          throw WasmtimeError(
              'wasi_config_preopen_dir(${p.hostPath}) failed — does it exist?');
        }
      }
      if (stdoutFile != null &&
          !raw.wasi_config_set_stdout_file(cfg, dup(stdoutFile!).cast())) {
        throw WasmtimeError('wasi_config_set_stdout_file failed');
      }
      if (stderrFile != null &&
          !raw.wasi_config_set_stderr_file(cfg, dup(stderrFile!).cast())) {
        throw WasmtimeError('wasi_config_set_stderr_file failed');
      }
      if (stdinBytes != null) {
        final vec = calloc<wasm_byte_vec_t>();
        allocs.add(vec);
        final buf = calloc<ffi.Uint8>(stdinBytes!.length);
        allocs.add(buf);
        buf.asTypedList(stdinBytes!.length).setAll(0, stdinBytes!);
        raw.wasm_byte_vec_new(vec, stdinBytes!.length, buf.cast());
        raw.wasi_config_set_stdin_bytes(cfg, vec); // consumes vec contents
      }
      if (inheritStdout) raw.wasi_config_inherit_stdout(cfg);
      if (inheritStderr) raw.wasi_config_inherit_stderr(cfg);
      if (inheritStdin) raw.wasi_config_inherit_stdin(cfg);
      return cfg;
    } catch (_) {
      raw.wasi_config_delete(cfg);
      rethrow;
    } finally {
      for (final p in allocs) {
        calloc.free(p);
      }
    }
  }
}
```

Add to `Context` in store.dart (new import: `wasi.dart`):

```dart
  /// Installs WASI on this store. Pair with Linker.defineWasi().
  /// Consumes [config] — a WasiConfig cannot be reused.
  void setWasi(WasiConfig config) => checkError(lib.raw,
      lib.raw.wasmtime_context_set_wasi(ptr, config.buildNative(lib)), 'set_wasi');
```

- [ ] **Step 4: Run the tests**

Run: `cd wasmtime_dart && dart test test/wasi_test.dart`
Expected: 5 PASS. The read-only test is the important one — it asserts _enforcement_ (guest `path_open` fails and no file appears on the host), not just that the config call succeeded.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): WasiConfig with enforced read-only preopens

The RO test drives a real guest path_open(O_CREAT) against an RO
preopen and asserts refusal on the guest side plus no file on the
host side — the capability model is verified behavior, not a config
flag we hope works. Custom stdio callbacks stay unexposed (tokio
worker threads would abort the Dart VM); files are the capture path.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

### Task 10: Fuel exhaustion and epoch deadlines (EpochTicker)

**Files:**

- Create: `wasmtime_dart/test/limits_test.dart`
- Modify: `wasmtime_dart/lib/src/engine.dart` (add `EpochTicker`)

**Interfaces:**

- Consumes: `Engine` (`rawAddress`, `lib.path`), `Context.setFuel`/`setEpochDeadline`, `TrapCode`.
- Produces: `EpochTicker.start(Engine engine, {Duration interval = const Duration(milliseconds: 10)}) → Future<EpochTicker>`; `ticker.stop()`. Contract: `stop()` MUST be called before `engine.dispose()` — the watchdog holds the engine's raw address.

- [ ] **Step 1: Write the failing test**

`wasmtime_dart/test/limits_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const spinWat = '''
(module
  (func (export "spin")
    (loop \$l br \$l)))
''';

void main() {
  test('fuel exhaustion traps with TrapCode.outOfFuel', () {
    final engine = Engine(testLib(), config: EngineConfig(consumeFuel: true));
    final store = Store(engine);
    final linker = Linker(engine);
    final m = Module.fromWat(engine, spinWat);
    store.context.setFuel(100000);
    final spin =
        linker.instantiate(store.context, m).getFunc(store.context, 'spin');
    expect(
      () => spin.call(store.context),
      throwsA(isA<WasmTrap>().having((t) => t.code, 'code', TrapCode.outOfFuel)),
    );
    m.dispose();
    linker.dispose();
    store.dispose();
    engine.dispose();
  });

  test('epoch deadline interrupts a spinning guest', () async {
    final engine =
        Engine(testLib(), config: EngineConfig(epochInterruption: true));
    final store = Store(engine);
    final linker = Linker(engine);
    final m = Module.fromWat(engine, spinWat);
    final spin =
        linker.instantiate(store.context, m).getFunc(store.context, 'spin');
    store.context.setEpochDeadline(2);
    final ticker = await EpochTicker.start(engine,
        interval: const Duration(milliseconds: 5));
    try {
      expect(
        () => spin.call(store.context),
        throwsA(
            isA<WasmTrap>().having((t) => t.code, 'code', TrapCode.interrupt)),
      );
    } finally {
      ticker.stop();
      m.dispose();
      linker.dispose();
      store.dispose();
      engine.dispose();
    }
  });
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd wasmtime_dart && dart test test/limits_test.dart`
Expected: the fuel test may already PASS (Task 4 wired setFuel); the epoch test FAILs — `EpochTicker` undefined.

- [ ] **Step 3: Add EpochTicker to engine.dart**

New imports at the top of `engine.dart`: `dart:async`, `dart:isolate`.

```dart
/// Watchdog isolate that bumps the engine's epoch on an interval.
/// The calling isolate is BLOCKED inside FFI while a guest runs, so a
/// same-isolate timer can never fire — the increment must come from
/// another thread. wasmtime_engine_increment_epoch is documented
/// thread-safe. Always stop() before disposing the Engine.
class EpochTicker {
  EpochTicker._(this._isolate, this._stopSend);

  final Isolate _isolate;
  final SendPort _stopSend;
  bool _stopped = false;

  static Future<EpochTicker> start(Engine engine,
      {Duration interval = const Duration(milliseconds: 10)}) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _run,
      (engine.lib.path, engine.rawAddress, interval.inMilliseconds,
          ready.sendPort),
    );
    final stopSend = await ready.first as SendPort;
    ready.close();
    return EpochTicker._(isolate, stopSend);
  }

  static void _run((String, int, int, SendPort) args) {
    final (libPath, engineAddress, intervalMs, ready) = args;
    final dylib = ffi.DynamicLibrary.open(libPath);
    final increment = dylib.lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)>('wasmtime_engine_increment_epoch');
    final enginePtr = ffi.Pointer<ffi.Void>.fromAddress(engineAddress);
    final control = ReceivePort();
    ready.send(control.sendPort);
    final timer = Timer.periodic(
        Duration(milliseconds: intervalMs), (_) => increment(enginePtr));
    control.listen((_) {
      timer.cancel();
      control.close();
    });
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _stopSend.send('stop');
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd wasmtime_dart && dart test test/limits_test.dart`
Expected: 2 PASS. The epoch test is the marquee proof: a blocked FFI call interrupted from a watchdog isolate — the "kill a runaway plugin after N seconds" primitive.

- [ ] **Step 5: Analyze, format, commit**

```bash
cd wasmtime_dart && dart analyze && dart format . && cd ..
jj commit -m "feat(wasmtime_dart): fuel traps + EpochTicker wall-clock deadlines

Fuel bounds instruction count; epochs bound wall-clock time. The
increment must come from a watchdog isolate because the calling
isolate is blocked inside the FFI call while the guest runs — the
epoch test interrupts a real infinite loop, which is the primitive
the plugin runtime needs to kill runaway actions.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

### Task 11: Drift guard, workspace gates, README, CLAUDE.md

**Files:**

- Create: `wasmtime_dart/README.md`
- Modify: `justfile` (`check-wasmtime-bindings`, `test`, `analyze`, `ci`), `CLAUDE.md` (project structure)

**Interfaces:**

- Consumes: `gen-wasmtime-bindings` recipe (Task 1).
- Produces: `just check-wasmtime-bindings`; `just test` / `just analyze` / `just ci` cover `wasmtime_dart`.

- [ ] **Step 1: Add the drift guard recipe**

In `justfile`, after `check-templates`:

```make
# Guards against editing ffigen.yaml or bumping wasmtime without
# regenerating. Snapshots the generated file, regenerates, compares
# content; on drift the file is left regenerated so you can review +
# commit it (same pattern as check-templates).
#
# Fail if wasmtime_dart's generated bindings are stale
check-wasmtime-bindings:
  #!/usr/bin/env nu
  let f = "wasmtime_dart/lib/src/generated/bindings.g.dart"
  let before = (open --raw $f)
  just gen-wasmtime-bindings
  if ($before != (open --raw $f)) {
    print $"($f) was stale — regenerated in place; review and commit it."
    exit 1
  }
  print "wasmtime_dart bindings are in sync."
```

- [ ] **Step 2: Wire test / analyze / ci**

In the `test` recipe, add `wasmtime_dart` to BOTH branches (trace and default), after the tui block:

```nu
    cd ../wasmtime_dart
    dart test
    cd ..
```

(The existing lines `cd ..` before `bash tests/scripts/check-plugin-consistency.sh` become `cd ..` from `wasmtime_dart` — keep the script call intact.)

In `analyze`:

```nu
  cd ../wasmtime_dart; dart analyze
```

(after the website line).

In `ci`, add after `just check-templates`:

```nu
  just check-wasmtime-bindings
```

and extend the format-check chain:

```nu
  cd ../wasmtime_dart; dart format --output=none --set-exit-if-changed .
```

(before the final `cd ..`).

- [ ] **Step 3: Package README**

`wasmtime_dart/README.md`:

```markdown
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
  watchdog isolate). Always `ticker.stop()` before `engine.dispose()`.

## Bumping wasmtime

1. Advance nixpkgs so `wasmtime.lib`/`wasmtime.dev` move together.
2. `just gen-wasmtime-bindings`
3. `cd wasmtime_dart && dart test` — fix analyzer/test fallout; re-check
   the literal constants transcribed from headers (TrapCode values,
   extern kinds 0/3, valkinds) against the new headers.
4. Commit the regenerated bindings with the version bump.

Bindings are pinned to the nixpkgs wasmtime major (46.x today); a
mismatched library fails at open with a version hint.
```

- [ ] **Step 4: CLAUDE.md project structure**

In `CLAUDE.md`'s Project Structure tree, add after the `common/` block:

```
├── wasmtime_dart/            # Dart bindings for the wasmtime C API (WASM plugin sandbox)
```

- [ ] **Step 5: Full gate**

```bash
just ci
```

Expected: tests (common + tui + wasmtime_dart) pass, analyzers clean, template AND bindings drift guards green, format check green. If `check-plugin-consistency.sh` or other pre-existing pieces fail for unrelated reasons, report it — do not "fix" unrelated code in this task.

- [ ] **Step 6: Commit**

```bash
jj commit -m "chore(wasmtime_dart): drift guard + workspace gates + README

check-wasmtime-bindings mirrors check-templates so a wasmtime bump or
ffigen.yaml edit can't ship stale generated code. just test/analyze/ci
now cover the new package; the README carries the env contract,
threading rules, and the version-bump procedure.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
jj bookmark set wasm-plugins -r @-
```

---

## Execution notes

- Task order is strict: 1 → 11 (each builds on the previous interfaces).
- If ffigen output (Task 1) deviates from the names later tasks use, fix
  the call sites per the Generated-name adaptation rule — the interfaces
  (class/method names of the idiomatic layer) must not change.
- The full suite (`cd wasmtime_dart && dart test`) should run in seconds;
  if a test hangs, suspect a WASI/stdio misconfiguration or a missing
  `EpochTicker.stop()` keeping the isolate alive.
