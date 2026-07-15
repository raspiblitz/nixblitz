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
      throw ArgumentError('expected ${params.length} args, got ${args.length}');
    }
    for (var i = 0; i < args.length; i++) {
      if (args[i].type != params[i]) {
        throw ArgumentError(
          'arg $i: expected ${params[i].name}, got ${args[i].type.name}',
        );
      }
    }
    final argsPtr = calloc<wasmtime_val_t>(args.isEmpty ? 1 : args.length);
    final resultsPtr = calloc<wasmtime_val_t>(
      results.isEmpty ? 1 : results.length,
    );
    final trapOut = calloc<ffi.Pointer<wasm_trap_t>>();
    try {
      for (var i = 0; i < args.length; i++) {
        args[i].writeTo(argsPtr + i);
      }
      final error = raw.wasmtime_func_call(
        context.ptr,
        handle,
        argsPtr,
        args.length,
        resultsPtr,
        results.length,
        trapOut,
      );
      _checkCallError(raw, error);
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

/// wasmtime_func_call is documented as returning either a non-null error
/// (API misuse: wrong arity/types/store) XOR a non-null trap (a wasm-level
/// fault), never both. In practice (observed on wasmtime 46.0.1) a trap
/// raised by a *host*-defined import — i.e. the `wasm_trap_t` our
/// trampoline returns from `_hostTrampoline` — surfaces through the
/// error slot instead, wrapped with backtrace context, rather than
/// through `trapOut`. `wasmtime_error_wasm_trace` is the documented way
/// to tell the two apart: a non-empty wasm trace means the error
/// happened during live wasm execution, so it is trap-shaped even
/// though the C API delivered it as a wasmtime_error_t.
void _checkCallError(WasmtimeRaw raw, ffi.Pointer<wasmtime_error_t> error) {
  if (error == ffi.nullptr) return;
  final trace = calloc<wasm_frame_vec_t>();
  raw.wasmtime_error_wasm_trace(error, trace);
  final isTrapShaped = trace.ref.size > 0;
  raw.wasm_frame_vec_delete(trace);
  calloc.free(trace);
  if (!isTrapShaped) {
    checkError(raw, error, 'func_call');
    return;
  }
  final vec = calloc<wasm_byte_vec_t>();
  raw.wasmtime_error_message(error, vec);
  final message = readAndDeleteByteVec(raw, vec);
  calloc.free(vec);
  raw.wasmtime_error_delete(error);
  throw WasmTrap(message, TrapCode.unknown);
}

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
typedef HostCallbackNative =
    ffi.Pointer<wasm_trap_t> Function(
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
        'host function returned ${out.length} values, expected $nresults',
      );
    }
    for (var i = 0; i < nresults; i++) {
      if (out[i].type != entry.type.results[i]) {
        throw StateError(
          'host result $i: expected ${entry.type.results[i].name}, '
          'got ${out[i].type.name}',
        );
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
final hostTrampoline = ffi.NativeCallable<HostCallbackNative>.isolateLocal(
  _hostTrampoline,
)..keepIsolateAlive = false;

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
        _ptr,
        nameBytes.cast(),
        nameBytes.length,
        item,
      );
      // WASMTIME_EXTERN_FUNC == 0.
      if (!found || item.ref.kind != 0) {
        throw WasmtimeError(
          'caller export `$name` not found or not a function',
        );
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
