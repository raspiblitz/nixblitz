import 'dart:ffi' as ffi;

import 'engine.dart';
import 'generated/raw.dart';
import 'library.dart';
import 'trap.dart';
import 'wasi.dart';

/// Owns a wasmtime_store_t. Everything created against its [context]
/// (instances, funcs, memories) is only valid while the store lives.
class Store implements ffi.Finalizable {
  Store(this.engine) {
    _ptr = engine.lib.raw.wasmtime_store_new(
      engine.ptr,
      ffi.nullptr,
      ffi.nullptr,
    );
    if (_ptr == ffi.nullptr) {
      throw WasmtimeError('wasmtime_store_new returned null');
    }
    engine.lib.storeFinalizer.attach(this, _ptr.cast(), detach: this);
    context = Context.borrowed(
      engine.lib,
      engine.lib.raw.wasmtime_store_context(_ptr),
    );
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
  void setFuel(int fuel) => checkError(
    lib.raw,
    lib.raw.wasmtime_context_set_fuel(ptr, fuel),
    'set_fuel',
  );

  /// Requires an engine with `epochInterruption: true`. Ticks are
  /// relative to the engine's current epoch.
  void setEpochDeadline(int ticks) =>
      lib.raw.wasmtime_context_set_epoch_deadline(ptr, ticks);

  /// Installs WASI on this store. Pair with Linker.defineWasi().
  /// Consumes [config] — a WasiConfig cannot be reused.
  void setWasi(WasiConfig config) => checkError(
    lib.raw,
    lib.raw.wasmtime_context_set_wasi(ptr, config.buildNative(lib)),
    'set_wasi',
  );
}
