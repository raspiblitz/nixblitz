import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const memWat = '''
(module
  (memory (export "memory") 1)
  (data (i32.const 8) "hi wasm")
  (func (export "peek") (param i32) (result i32)
    local.get 0
    i32.load8_u))
''';

const logWat = '''
(module
  (import "env" "log" (func \$log (param i32 i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "hello")
  (func (export "run")
    i32.const 16
    i32.const 5
    call \$log))
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

  Instance inst(String wat) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m);
  }

  test('readBytes sees the data segment', () {
    final mem = inst(memWat).getMemory(store.context, 'memory');
    expect(utf8.decode(mem.readBytes(store.context, 8, 7)), 'hi wasm');
  });

  test('writeBytes is visible to the guest', () {
    final i = inst(memWat);
    final mem = i.getMemory(store.context, 'memory');
    mem.writeBytes(store.context, 100, Uint8List.fromList([7]));
    final peek = i.getFunc(store.context, 'peek');
    expect((peek.call(store.context, [ValI32(100)]).single as ValI32).value, 7);
  });

  test('out-of-bounds read throws RangeError', () {
    final mem = inst(memWat).getMemory(store.context, 'memory');
    expect(() => mem.readBytes(store.context, 65536 - 2, 4), throwsRangeError);
  });

  test('grow adds pages and returns the previous size', () {
    final mem = inst(memWat).getMemory(store.context, 'memory');
    expect(mem.grow(store.context, 1), 1);
    expect(mem.sizePages(store.context), 2);
  });

  test('host function reads a guest string via Caller.getMemory', () {
    String? seen;
    linker.defineFunc(
      'env',
      'log',
      FuncType(params: [ValType.i32, ValType.i32], results: []),
      (caller, args) {
        final mem = caller.getMemory('memory');
        seen = utf8.decode(
          mem.readBytes(
            caller.context,
            (args[0] as ValI32).value,
            (args[1] as ValI32).value,
          ),
        );
        return [];
      },
    );
    inst(logWat).getFunc(store.context, 'run').call(store.context);
    expect(seen, 'hello');
  });
}
