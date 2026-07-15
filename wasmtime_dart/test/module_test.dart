import 'dart:io';

import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const addWat = '''
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
''';

void main() {
  late Engine engine;
  setUp(() => engine = Engine(testLib()));
  tearDown(() => engine.dispose());

  test('fromWat compiles a valid module', () {
    final m = Module.fromWat(engine, addWat);
    expect(m.ptr.address, isNonZero);
    m.dispose();
  });

  test('invalid WAT throws WasmtimeError with a message', () {
    expect(
      () => Module.fromWat(engine, '(module (this is not wat'),
      throwsA(
        isA<WasmtimeError>().having((e) => e.message, 'message', isNotEmpty),
      ),
    );
  });

  test('serialize → deserialize round-trip', () {
    final m = Module.fromWat(engine, addWat);
    final bytes = m.serialize();
    expect(bytes, isNotEmpty);
    final m2 = Module.deserialize(engine, bytes);
    expect(m2.ptr.address, isNonZero);
    m.dispose();
    m2.dispose();
  });

  test('deserializeFile loads a serialized module from disk', () {
    final m = Module.fromWat(engine, addWat);
    final f = File('${Directory.systemTemp.path}/wasmtime_dart_mod_test.bin')
      ..writeAsBytesSync(m.serialize());
    final m2 = Module.deserializeFile(engine, f.path);
    expect(m2.ptr.address, isNonZero);
    m.dispose();
    m2.dispose();
    f.deleteSync();
  });
}
