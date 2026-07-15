import 'package:wasmtime_dart/wasmtime_dart.dart';

WasmtimeLibrary? _lib;

/// Shared library instance for all tests (resolved via WASMTIME_DART_LIB).
WasmtimeLibrary testLib() => _lib ??= WasmtimeLibrary.discover();
