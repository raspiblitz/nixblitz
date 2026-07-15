import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:wasmtime_dart/src/generated/raw.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

void main() {
  Val roundtrip(Val v) {
    final p = calloc<wasmtime_val_t>();
    try {
      v.writeTo(p);
      return Val.readFrom(p);
    } finally {
      calloc.free(p);
    }
  }

  test('i32/i64/f32/f64 round-trip through wasmtime_val_t', () {
    expect((roundtrip(ValI32(-42)) as ValI32).value, -42);
    expect((roundtrip(ValI64(1 << 62)) as ValI64).value, 1 << 62);
    expect((roundtrip(ValF32(1.5)) as ValF32).value, 1.5);
    expect((roundtrip(ValF64(-2.25)) as ValF64).value, -2.25);
  });

  test('v128 round-trips 16 bytes', () {
    final bytes = Uint8List.fromList(List.generate(16, (i) => i * 3 & 0xff));
    expect((roundtrip(ValV128(bytes)) as ValV128).value, bytes);
  });

  test('v128 requires exactly 16 bytes', () {
    expect(() => ValV128(Uint8List(4)), throwsArgumentError);
  });
}
