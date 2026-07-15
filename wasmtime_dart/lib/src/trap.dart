import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'generated/raw.dart';

/// A wasmtime API error (config, compile, link, ... failures).
class WasmtimeError implements Exception {
  WasmtimeError(this.message);
  final String message;
  @override
  String toString() => 'WasmtimeError: $message';
}

/// Trap codes from wasmtime/trap.h (v46). Values are part of the C ABI
/// for the pinned major; re-check the header on a wasmtime bump.
enum TrapCode {
  stackOverflow(0),
  memoryOutOfBounds(1),
  heapMisaligned(2),
  tableOutOfBounds(3),
  indirectCallToNull(4),
  badSignature(5),
  integerOverflow(6),
  integerDivisionByZero(7),
  badConversionToInteger(8),
  unreachable(9),
  interrupt(10),
  outOfFuel(11),
  unknown(-1);

  const TrapCode(this.native);
  final int native;

  static TrapCode fromNative(int code) => TrapCode.values.firstWhere(
    (c) => c.native == code,
    orElse: () => TrapCode.unknown,
  );
}

/// A wasm trap: guest fault, fuel exhaustion, or epoch interrupt.
class WasmTrap implements Exception {
  WasmTrap(this.message, this.code);
  final String message;
  final TrapCode code;
  @override
  String toString() => 'WasmTrap(${code.name}): $message';
}

/// Reads a wasm_byte_vec_t's content as UTF-8 and releases the native
/// buffer. The struct allocation itself stays owned by the caller.
String readAndDeleteByteVec(WasmtimeRaw raw, ffi.Pointer<wasm_byte_vec_t> vec) {
  final bytes = vec.ref.data.cast<ffi.Uint8>().asTypedList(vec.ref.size);
  final message = utf8.decode(bytes, allowMalformed: true);
  raw.wasm_byte_vec_delete(vec);
  return message;
}

/// Throws [WasmtimeError] if [error] is non-null (consumes it).
void checkError(
  WasmtimeRaw raw,
  ffi.Pointer<wasmtime_error_t> error,
  String what,
) {
  if (error == ffi.nullptr) return;
  final vec = calloc<wasm_byte_vec_t>();
  raw.wasmtime_error_message(error, vec);
  final message = readAndDeleteByteVec(raw, vec);
  calloc.free(vec);
  raw.wasmtime_error_delete(error);
  throw WasmtimeError('$what: $message');
}

/// Throws [WasmTrap] if [trap] is non-null (consumes it).
void checkTrap(WasmtimeRaw raw, ffi.Pointer<wasm_trap_t> trap) {
  if (trap == ffi.nullptr) return;
  final vec = calloc<wasm_byte_vec_t>();
  raw.wasm_trap_message(trap, vec);
  final message = readAndDeleteByteVec(raw, vec);
  calloc.free(vec);
  final codeOut = calloc<ffi.Uint8>();
  final hasCode = raw.wasmtime_trap_code(trap, codeOut);
  final code = hasCode ? TrapCode.fromNative(codeOut.value) : TrapCode.unknown;
  calloc.free(codeOut);
  raw.wasm_trap_delete(trap);
  throw WasmTrap(message, code);
}
