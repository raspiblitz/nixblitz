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
      'wat2wasm',
    );
    final out = Uint8List.fromList(
      vec.ref.data.cast<ffi.Uint8>().asTypedList(vec.ref.size),
    );
    raw.wasm_byte_vec_delete(vec);
    return out;
  } finally {
    calloc.free(vec);
    calloc.free(watBytes);
  }
}

/// A compiled module, tied to its Engine (not to any Store).
class Module implements ffi.Finalizable {
  Module._(this.engine, this._ptr) {
    engine.lib.moduleFinalizer.attach(this, _ptr.cast(), detach: this);
  }

  factory Module.fromWasm(Engine engine, Uint8List wasm) {
    final raw = engine.lib.raw;
    final bytes = calloc<ffi.Uint8>(wasm.length);
    bytes.asTypedList(wasm.length).setAll(0, wasm);
    final out = calloc<ffi.Pointer<wasmtime_module_t>>();
    try {
      checkError(
        raw,
        raw.wasmtime_module_new(engine.ptr, bytes, wasm.length, out),
        'module_new',
      );
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
      checkError(
        raw,
        raw.wasmtime_module_deserialize(engine.ptr, buf, bytes.length, out),
        'module_deserialize',
      );
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
      checkError(
        raw,
        raw.wasmtime_module_deserialize_file(engine.ptr, pathBytes.cast(), out),
        'module_deserialize_file',
      );
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
      checkError(
        raw,
        raw.wasmtime_module_serialize(ptr, vec),
        'module_serialize',
      );
      final out = Uint8List.fromList(
        vec.ref.data.cast<ffi.Uint8>().asTypedList(vec.ref.size),
      );
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
