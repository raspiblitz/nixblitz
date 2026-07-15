import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const spinWat = '''
(module
  (func (export "spin")
    (loop \$l br \$l)))
''';

void main() {
  test('fuel exhaustion traps with TrapCode.outOfFuel', () {
    final engine = Engine(testLib(), config: EngineConfig(consumeFuel: true));
    final store = Store(engine);
    final linker = Linker(engine);
    final m = Module.fromWat(engine, spinWat);
    store.context.setFuel(100000);
    try {
      final spin = linker
          .instantiate(store.context, m)
          .getFunc(store.context, 'spin');
      expect(
        () => spin.call(store.context),
        throwsA(
          isA<WasmTrap>().having((t) => t.code, 'code', TrapCode.outOfFuel),
        ),
      );
    } finally {
      m.dispose();
      linker.dispose();
      store.dispose();
      engine.dispose();
    }
  });

  test('epoch deadline interrupts a spinning guest', () async {
    final engine = Engine(
      testLib(),
      config: EngineConfig(epochInterruption: true),
    );
    final store = Store(engine);
    final linker = Linker(engine);
    final m = Module.fromWat(engine, spinWat);
    final spin = linker
        .instantiate(store.context, m)
        .getFunc(store.context, 'spin');
    store.context.setEpochDeadline(2);
    final ticker = await EpochTicker.start(
      engine,
      interval: const Duration(milliseconds: 5),
    );
    try {
      expect(
        () => spin.call(store.context),
        throwsA(
          isA<WasmTrap>().having((t) => t.code, 'code', TrapCode.interrupt),
        ),
      );
    } finally {
      await ticker.stop();
      m.dispose();
      linker.dispose();
      store.dispose();
      engine.dispose();
    }
  });
}
