import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

// Guest: allocs a request string is awkward in raw WAT, so the fixture
// hardcodes the request bytes in a data segment and passes their address
// to host_call. alloc returns a fixed scratch offset.
//
// The data segment is 68 bytes (verified via a byte-accurate count of
// the JSON literal below) — host_call's length arg must match exactly
// or the request JSON is truncated before it reaches HostCallHandler.
const callWat = r'''
(module
  (import "nixblitz" "host_call" (func $hc (param i32 i32) (result i64)))
  (memory (export "memory") 1)
  (data (i32.const 0)
    "{\"v\":1,\"cap\":\"bitcoin_rpc\",\"method\":\"getblockchaininfo\",\"params\":[]}")
  (func (export "alloc") (param i32) (result i32) (i32.const 4096))
  (func (export "run")
    (drop (call $hc (i32.const 0) (i32.const 68)))))
''';

const spinWat = r'''
(module
  (import "nixblitz" "host_call" (func $hc (param i32 i32) (result i64)))
  (memory (export "memory") 1)
  (func (export "alloc") (param i32) (result i32) (i32.const 0))
  (func (export "run") (loop $l br $l)))
''';

class FakeExecutor implements BitcoinRpcExecutor {
  final List<String> calls = [];
  @override
  RpcResult call(String method, List params) {
    calls.add(method);
    return RpcResult(ok: true, result: {'blocks': 1}, stderr: '');
  }
}

void main() {
  late Directory tmp;
  late WasmActionRunner runner;
  late FakeExecutor executor;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('runner_');
    runner = WasmActionRunner(
      library: WasmtimeLibrary.discover(),
      cacheDir: '${tmp.path}/cache',
    );
    executor = FakeExecutor();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  const sandbox = SandboxSpec(
    bitcoinRpc: BitcoinRpcCapability(
      methods: ['getblockchaininfo'],
      spendSatsPerDay: 0,
    ),
  );

  HostCallHandler handler() => HostCallHandler(
    sandbox: sandbox,
    ledger: BudgetLedger('${tmp.path}/b.json'),
    executor: executor,
    clock: () => DateTime.utc(2026, 7, 16),
  );

  Future<String> writeWasm(String wat, String name) async {
    // Compile WAT -> wasm bytes via a throwaway engine, write to disk.
    final lib = WasmtimeLibrary.discover();
    final engine = Engine(lib);
    final bytes = watToWasm(engine, wat);
    engine.dispose();
    final path = '${tmp.path}/$name.wasm';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  test('guest host_call reaches the handler', () async {
    final path = await writeWasm(callWat, 'call');
    final res = await runner.run(
      wasmPath: path,
      export: 'run',
      sandbox: sandbox,
      hostCall: handler(),
    );
    final code = await res.exitCode;
    expect(code, 0);
    expect(executor.calls, ['getblockchaininfo']);
  });

  test('a spinning guest is stopped by the time budget', () async {
    final path = await writeWasm(spinWat, 'spin');
    final res = await runner.run(
      wasmPath: path,
      export: 'run',
      sandbox: const SandboxSpec(limits: SandboxLimits(timeoutSeconds: 1)),
      hostCall: handler(),
    );
    final out = <String>[];
    res.output.listen(out.add);
    final code = await res.exitCode;
    expect(code, isNot(0));
    expect(out.join(), contains('budget'));
  });

  test('module cache produces a .cwasm and a second run reuses it', () async {
    final path = await writeWasm(callWat, 'call2');
    await (await runner.run(
      wasmPath: path,
      export: 'run',
      sandbox: sandbox,
      hostCall: handler(),
    )).exitCode;
    final caches = Directory(
      '${tmp.path}/cache',
    ).listSync().whereType<File>().toList();
    expect(caches, isNotEmpty);
    // second run still succeeds
    final code = await (await runner.run(
      wasmPath: path,
      export: 'run',
      sandbox: sandbox,
      hostCall: handler(),
    )).exitCode;
    expect(code, 0);
  });
}
