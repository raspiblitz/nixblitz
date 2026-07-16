import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

/// Caches compiled modules as `<sha256-of-wasm>.cwasm` so a plugin's
/// guest is JIT-compiled once, not per action. Keyed by the wasm file's
/// content hash, so a plugin update invalidates automatically.
class ModuleCache {
  ModuleCache(this.dir);
  final String dir;

  Module load(Engine engine, String wasmPath) {
    final bytes = File(wasmPath).readAsBytesSync();
    final hash = sha256.convert(bytes).toString();
    final cachePath = '$dir/$hash.cwasm';
    final cached = File(cachePath);
    if (cached.existsSync()) {
      try {
        return Module.deserializeFile(engine, cachePath);
      } catch (_) {
        // Stale/incompatible cache (e.g. wasmtime bump) — recompile.
      }
    }
    final module = Module.fromWasm(engine, bytes);
    try {
      Directory(dir).createSync(recursive: true);
      File(cachePath).writeAsBytesSync(module.serialize(), flush: true);
    } catch (_) {
      // Cache write is best-effort; the module is still usable.
    }
    return module;
  }
}
