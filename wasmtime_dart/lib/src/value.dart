import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'generated/raw.dart';

/// Value kinds, matching wasmtime/val.h (v46) and wasm.h valkinds.
enum ValType {
  i32(0, 0),
  i64(1, 1),
  f32(2, 2),
  f64(3, 3),
  v128(4, -1); // no wasm_valkind for v128 → not usable in FuncType

  const ValType(this.native, this.valkind);

  /// wasmtime_valkind_t value (wasmtime_val_t.kind).
  final int native;

  /// wasm_valkind_t value for wasm_valtype_new, -1 if unsupported.
  final int valkind;

  static ValType fromNative(int kind) => switch (kind) {
    0 => i32,
    1 => i64,
    2 => f32,
    3 => f64,
    4 => v128,
    _ => throw ArgumentError('unsupported wasmtime_valkind: $kind'),
  };
}

/// A wasm value. Dart ints are 64-bit signed, so i64 is lossless.
sealed class Val {
  const Val();
  ValType get type;

  void writeTo(ffi.Pointer<wasmtime_val_t> ptr) {
    ptr.ref.kind = type.native;
    switch (this) {
      case ValI32(:final value):
        ptr.ref.of.i32 = value;
      case ValI64(:final value):
        ptr.ref.of.i64 = value;
      case ValF32(:final value):
        ptr.ref.of.f32 = value;
      case ValF64(:final value):
        ptr.ref.of.f64 = value;
      case ValV128(:final value):
        for (var i = 0; i < 16; i++) {
          ptr.ref.of.v128[i] = value[i];
        }
    }
  }

  static Val readFrom(ffi.Pointer<wasmtime_val_t> ptr) =>
      switch (ValType.fromNative(ptr.ref.kind)) {
        ValType.i32 => ValI32(ptr.ref.of.i32),
        ValType.i64 => ValI64(ptr.ref.of.i64),
        ValType.f32 => ValF32(ptr.ref.of.f32),
        ValType.f64 => ValF64(ptr.ref.of.f64),
        ValType.v128 => ValV128(
          Uint8List.fromList([for (var i = 0; i < 16; i++) ptr.ref.of.v128[i]]),
        ),
      };
}

class ValI32 extends Val {
  const ValI32(this.value);
  final int value;
  @override
  ValType get type => ValType.i32;
}

class ValI64 extends Val {
  const ValI64(this.value);
  final int value;
  @override
  ValType get type => ValType.i64;
}

class ValF32 extends Val {
  const ValF32(this.value);
  final double value;
  @override
  ValType get type => ValType.f32;
}

class ValF64 extends Val {
  const ValF64(this.value);
  final double value;
  @override
  ValType get type => ValType.f64;
}

class ValV128 extends Val {
  ValV128(this.value) {
    if (value.length != 16) {
      throw ArgumentError('v128 requires exactly 16 bytes');
    }
  }
  final Uint8List value;
  @override
  ValType get type => ValType.v128;
}

/// A host-defined function signature (numeric types only — v128 params
/// are not expressible through wasm_valtype_new).
class FuncType {
  FuncType({required this.params, required this.results}) {
    for (final t in [...params, ...results]) {
      if (t.valkind < 0) {
        throw ArgumentError('${t.name} is not supported in FuncType');
      }
    }
  }
  final List<ValType> params;
  final List<ValType> results;
}
