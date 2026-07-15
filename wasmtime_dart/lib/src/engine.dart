import 'dart:ffi' as ffi;

import 'generated/raw.dart';
import 'library.dart';
import 'trap.dart';

/// Engine-level toggles. Both default off; fuel and epochs each add a
/// small execution overhead.
class EngineConfig {
  const EngineConfig({
    this.consumeFuel = false,
    this.epochInterruption = false,
  });
  final bool consumeFuel;
  final bool epochInterruption;
}

/// Owns a wasm_engine_t. Thread-safe to share per wasmtime docs; in this
/// binding it stays on one isolate except for epoch increments.
class Engine implements ffi.Finalizable {
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
