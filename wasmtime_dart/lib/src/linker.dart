import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'engine.dart';
import 'func.dart';
import 'generated/raw.dart';
import 'instance.dart';
import 'module.dart';
import 'store.dart';
import 'trap.dart';
import 'value.dart';

/// Owns a wasmtime_linker_t. defineFunc arrives in the host-function
/// task; this file only grows there, its interface here is final.
class Linker implements ffi.Finalizable {
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
    engine.lib.raw,
    engine.lib.raw.wasmtime_linker_define_wasi(ptr),
    'define_wasi',
  );

  Instance instantiate(Context context, Module module) {
    final raw = engine.lib.raw;
    final instancePtr = calloc<wasmtime_instance_t>();
    final trapOut = calloc<ffi.Pointer<wasm_trap_t>>();
    try {
      checkError(
        raw,
        raw.wasmtime_linker_instantiate(
          ptr,
          context.ptr,
          module.ptr,
          instancePtr,
          trapOut,
        ),
        'linker_instantiate',
      );
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
          hostTrampoline.nativeFunction.cast(),
          ffi.Pointer.fromAddress(id),
          ffi.nullptr,
        ),
        'linker_define_func',
      );
    } finally {
      calloc.free(modBytes);
      calloc.free(nameBytes);
      raw.wasm_functype_delete(functype); // define_func copies the type
    }
  }
}
