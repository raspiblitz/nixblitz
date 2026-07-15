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
      checkError(
        raw,
        raw.wasmtime_func_call(
          context.ptr,
          handle,
          argsPtr,
          args.length,
          resultsPtr,
          results.length,
          trapOut,
        ),
        'func_call',
      );
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
