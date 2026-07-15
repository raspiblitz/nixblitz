import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

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

/// Watchdog isolate that bumps the engine's epoch on an interval.
/// The calling isolate is BLOCKED inside FFI while a guest runs, so a
/// same-isolate timer can never fire — the increment must come from
/// another thread. wasmtime_engine_increment_epoch is documented
/// thread-safe. Always `await ticker.stop()` before disposing the
/// Engine: stop() only completes once the watchdog isolate has
/// actually exited, so there is no window where a straggling timer
/// tick can increment the epoch of a freed engine.
class EpochTicker {
  EpochTicker._(this._isolate, this._stopSend, this._exitPort, this._exited);

  final Isolate _isolate;
  final SendPort _stopSend;
  final ReceivePort _exitPort;
  final Completer<void> _exited;
  bool _stopped = false;

  static Future<EpochTicker> start(
    Engine engine, {
    Duration interval = const Duration(milliseconds: 10),
  }) async {
    // If the watchdog isolate dies before it sends its ready SendPort
    // (e.g. DynamicLibrary.open fails, or symbol lookup throws), a plain
    // `await ready.first` would hang forever. Race ready against the
    // isolate's error/exit signals so start() fails fast instead.
    final ready = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final completer = Completer<SendPort>();

    final readySub = ready.listen((message) {
      if (!completer.isCompleted) completer.complete(message as SendPort);
    });
    final errorSub = errorPort.listen((message) {
      if (!completer.isCompleted) {
        completer.completeError(
          WasmtimeError('EpochTicker watchdog isolate failed: $message'),
        );
      }
    });
    final exitSub = exitPort.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          WasmtimeError(
            'EpochTicker watchdog isolate exited before becoming ready',
          ),
        );
      }
    });

    try {
      final isolate = await Isolate.spawn(
        _run,
        (
          engine.lib.path,
          engine.rawAddress,
          interval.inMilliseconds,
          ready.sendPort,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
      final stopSend = await completer.future;

      // Dedicated exit port that outlives the startup race above: stop()
      // awaits this so it only completes once the watchdog isolate has
      // actually terminated, closing the use-after-free window where a
      // straggling timer tick fires after the caller disposes the engine.
      final lifecycleExitPort = ReceivePort();
      final exited = Completer<void>();
      lifecycleExitPort.listen((_) {
        if (!exited.isCompleted) exited.complete();
      });
      isolate.addOnExitListener(lifecycleExitPort.sendPort);

      return EpochTicker._(isolate, stopSend, lifecycleExitPort, exited);
    } finally {
      await readySub.cancel();
      await errorSub.cancel();
      await exitSub.cancel();
      ready.close();
      errorPort.close();
      exitPort.close();
    }
  }

  static void _run((String, int, int, SendPort) args) {
    final (libPath, engineAddress, intervalMs, ready) = args;
    final dylib = ffi.DynamicLibrary.open(libPath);
    final increment = dylib
        .lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)
        >('wasmtime_engine_increment_epoch');
    final enginePtr = ffi.Pointer<ffi.Void>.fromAddress(engineAddress);
    final control = ReceivePort();
    ready.send(control.sendPort);
    final timer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => increment(enginePtr),
    );
    control.listen((_) {
      timer.cancel();
      control.close();
    });
  }

  /// Idempotent. Completes only once the watchdog isolate has actually
  /// exited — safe to `await ticker.stop(); engine.dispose();` back to
  /// back without a use-after-free window.
  Future<void> stop() async {
    if (_stopped) {
      await _exited.future;
      return;
    }
    _stopped = true;
    _stopSend.send('stop');
    _isolate.kill(priority: Isolate.beforeNextEvent);
    await _exited.future;
    _exitPort.close();
  }
}
