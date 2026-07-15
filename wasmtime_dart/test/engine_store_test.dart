import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

void main() {
  test('engine + store round-trip', () {
    final engine = Engine(testLib());
    final store = Store(engine);
    expect(store.context.ptr.address, isNonZero);
    store.dispose();
    engine.dispose();
  });

  test('setFuel works on a fuel-metered engine', () {
    final engine = Engine(testLib(), config: EngineConfig(consumeFuel: true));
    final store = Store(engine);
    store.context.setFuel(1000); // must not throw
    store.dispose();
    engine.dispose();
  });

  test('setFuel on a non-fueled engine throws WasmtimeError', () {
    final engine = Engine(testLib());
    final store = Store(engine);
    expect(() => store.context.setFuel(1000), throwsA(isA<WasmtimeError>()));
    store.dispose();
    engine.dispose();
  });

  test('dispose is idempotent; use-after-dispose throws StateError', () {
    final engine = Engine(testLib());
    engine.dispose();
    engine.dispose(); // no-op
    expect(() => engine.ptr, throwsStateError);
    expect(() => Store(engine), throwsStateError);
  });
}
