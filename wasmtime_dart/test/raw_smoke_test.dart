import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:test/test.dart';
import 'package:wasmtime_dart/src/generated/raw.dart';

void main() {
  test('raw bindings: engine round-trip', () {
    final path = Platform.environment['WASMTIME_DART_LIB'];
    expect(
      path,
      isNotNull,
      reason: 'WASMTIME_DART_LIB must be set (see devenv.nix)',
    );
    final raw = WasmtimeRaw(ffi.DynamicLibrary.open(path!));
    final engine = raw.wasm_engine_new();
    expect(engine, isNot(ffi.nullptr));
    raw.wasm_engine_delete(engine);
  });
}
