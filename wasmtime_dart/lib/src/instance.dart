import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'func.dart';
import 'generated/raw.dart';
import 'library.dart';
import 'store.dart';
import 'trap.dart';

/// Frees calloc'd native handle memory when the wrapper is collected.
final nativeAllocFinalizer = Finalizer<ffi.Pointer<ffi.NativeType>>(
  (p) => calloc.free(p.cast()),
);

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
    Context context,
    String name,
    ffi.Pointer<wasmtime_extern_t> item,
  ) {
    final nameBytes = name.toNativeUtf8();
    try {
      return lib.raw.wasmtime_instance_export_get(
        context.ptr,
        handle,
        nameBytes.cast(),
        nameBytes.length,
        item,
      );
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
