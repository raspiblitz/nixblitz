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
        'generated bindings (expected wasmtime 46.x)',
      );
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
    Platform.environment['WASMTIME_DART_LIB'] ?? 'libwasmtime.so',
  );

  final String path;
  final ffi.DynamicLibrary dylib;
  final WasmtimeRaw raw;

  ffi.Pointer<ffi.NativeFinalizerFunction> _deleteFn(String symbol) => dylib
      .lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
        symbol,
      );

  late final engineFinalizer = ffi.NativeFinalizer(
    _deleteFn('wasm_engine_delete'),
  );
  late final storeFinalizer = ffi.NativeFinalizer(
    _deleteFn('wasmtime_store_delete'),
  );
  late final moduleFinalizer = ffi.NativeFinalizer(
    _deleteFn('wasmtime_module_delete'),
  );
  late final linkerFinalizer = ffi.NativeFinalizer(
    _deleteFn('wasmtime_linker_delete'),
  );
}
