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

const mixWat = '''
(module
  (func (export "mix") (param i64 f64) (result i64)
    local.get 0
    local.get 1
    i64.trunc_f64_s
    i64.add))
''';

const boomWat = '(module (func (export "boom") unreachable))';

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

  Instance inst(String wat) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m);
  }

  test('i32 add', () {
    final add = inst(addWat).getFunc(store.context, 'add');
    final out = add.call(store.context, [ValI32(20), ValI32(22)]);
    expect((out.single as ValI32).value, 42);
  });

  test('i64/f64 params and i64 result', () {
    final mix = inst(mixWat).getFunc(store.context, 'mix');
    final out = mix.call(store.context, [ValI64(5), ValF64(2.0)]);
    expect((out.single as ValI64).value, 7);
  });

  test('deserialized module is callable', () {
    final m = Module.fromWat(engine, addWat);
    final m2 = Module.deserialize(engine, m.serialize());
    final add = linker
        .instantiate(store.context, m2)
        .getFunc(store.context, 'add');
    expect(
      (add.call(store.context, [ValI32(1), ValI32(2)]).single as ValI32).value,
      3,
    );
    m.dispose();
    m2.dispose();
  });

  test('missing export throws WasmtimeError', () {
    expect(
      () => inst(addWat).getFunc(store.context, 'nope'),
      throwsA(isA<WasmtimeError>()),
    );
  });

  test('wrong arity and wrong type throw ArgumentError', () {
    final add = inst(addWat).getFunc(store.context, 'add');
    expect(() => add.call(store.context, [ValI32(1)]), throwsArgumentError);
    expect(
      () => add.call(store.context, [ValI32(1), ValF64(2.0)]),
      throwsArgumentError,
    );
  });

  test('unreachable traps with TrapCode.unreachable', () {
    final boom = inst(boomWat).getFunc(store.context, 'boom');
    expect(
      () => boom.call(store.context),
      throwsA(
        isA<WasmTrap>().having((t) => t.code, 'code', TrapCode.unreachable),
      ),
    );
  });
}
