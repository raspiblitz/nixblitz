import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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
        'memory access [$offset, ${offset + length}) out of bounds (size $max)',
      );
    }
  }

  Uint8List readBytes(Context context, int offset, int length) {
    _checkBounds(context, offset, length);
    final data = lib.raw.wasmtime_memory_data(context.ptr, handle);
    return Uint8List.fromList(
      data
          .cast<ffi.Uint8>()
          .asTypedList(sizeBytes(context))
          .sublist(offset, offset + length),
    );
  }

  void writeBytes(Context context, int offset, Uint8List bytes) {
    _checkBounds(context, offset, bytes.length);
    final data = lib.raw.wasmtime_memory_data(context.ptr, handle);
    data
        .cast<ffi.Uint8>()
        .asTypedList(sizeBytes(context))
        .setRange(offset, offset + bytes.length, bytes);
  }

  /// Grows by [deltaPages]; returns the previous size in pages.
  int grow(Context context, int deltaPages) {
    final prevOut = calloc<ffi.Uint64>();
    try {
      checkError(
        lib.raw,
        lib.raw.wasmtime_memory_grow(context.ptr, handle, deltaPages, prevOut),
        'memory_grow',
      );
      return prevOut.value;
    } finally {
      calloc.free(prevOut);
    }
  }
}
