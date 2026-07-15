import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const useAddWat = '''
(module
  (import "env" "mul_add" (func \$ma (param i32 i32) (result i32)))
  (func (export "run") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    call \$ma))
''';

const mixHostWat = '''
(module
  (import "env" "mix" (func \$m (param i64 f64) (result i64)))
  (func (export "run") (param i64 f64) (result i64)
    local.get 0
    local.get 1
    call \$m))
''';

const splitWat = '''
(module
  (import "env" "split" (func \$s (param i32) (result i32 i32)))
  (func (export "sum") (param i32) (result i32)
    local.get 0
    call \$s
    i32.add))
''';

const reentrantWat = '''
(module
  (import "env" "h" (func \$h (param i32) (result i32)))
  (func (export "double") (param i32) (result i32)
    local.get 0
    i32.const 2
    i32.mul)
  (func (export "run") (param i32) (result i32)
    local.get 0
    call \$h))
''';

void main() {
  late Engine engine;
  late Store store;
  late Linker linker;
  setUp(() {
    engine = Engine(testLib());
    store = Store(engine);
    linker = Linker(engine);
  });
  tearDown(() {
    linker.dispose();
    store.dispose();
    engine.dispose();
  });

  Func instFunc(String wat, String name) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m).getFunc(store.context, name);
  }

  test('i32 host function round-trip', () {
    linker.defineFunc(
      'env',
      'mul_add',
      FuncType(params: [ValType.i32, ValType.i32], results: [ValType.i32]),
      (caller, args) => [
        ValI32((args[0] as ValI32).value * 10 + (args[1] as ValI32).value),
      ],
    );
    final run = instFunc(useAddWat, 'run');
    expect(
      (run.call(store.context, [ValI32(4), ValI32(5)]).single as ValI32).value,
      45,
    );
  });

  test('i64/f64 host function round-trip', () {
    linker.defineFunc(
      'env',
      'mix',
      FuncType(params: [ValType.i64, ValType.f64], results: [ValType.i64]),
      (caller, args) => [
        ValI64((args[0] as ValI64).value + (args[1] as ValF64).value.toInt()),
      ],
    );
    final run = instFunc(mixHostWat, 'run');
    expect(
      (run.call(store.context, [ValI64(1 << 40), ValF64(2.0)]).single as ValI64)
          .value,
      (1 << 40) + 2,
    );
  });

  test('multi-value host results', () {
    linker.defineFunc(
      'env',
      'split',
      FuncType(params: [ValType.i32], results: [ValType.i32, ValType.i32]),
      (caller, args) => [args[0], ValI32(1)],
    );
    final sum = instFunc(splitWat, 'sum');
    expect((sum.call(store.context, [ValI32(41)]).single as ValI32).value, 42);
  });

  test('Dart exception becomes a WasmTrap with the message', () {
    linker.defineFunc(
      'env',
      'mul_add',
      FuncType(params: [ValType.i32, ValType.i32], results: [ValType.i32]),
      (caller, args) => throw StateError('boom from dart'),
    );
    final run = instFunc(useAddWat, 'run');
    expect(
      () => run.call(store.context, [ValI32(1), ValI32(2)]),
      throwsA(
        isA<WasmTrap>().having(
          (t) => t.message,
          'message',
          contains('boom from dart'),
        ),
      ),
    );
  });

  test('reentrancy: host function calls back into the guest', () {
    linker.defineFunc(
      'env',
      'h',
      FuncType(params: [ValType.i32], results: [ValType.i32]),
      (caller, args) {
        final dbl = caller.getFunc('double');
        final doubled = dbl.call(caller.context, [args[0]]).single as ValI32;
        return [ValI32(doubled.value + 1)];
      },
    );
    final run = instFunc(reentrantWat, 'run');
    expect((run.call(store.context, [ValI32(5)]).single as ValI32).value, 11);
  });
}
