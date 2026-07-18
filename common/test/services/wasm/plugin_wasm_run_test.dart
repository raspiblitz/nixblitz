import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

// Guest: calls host_call(getblockchaininfo) then prints a flat tile
// JSON object to stdout. Hardcoded request bytes in a data segment;
// alloc returns a fixed scratch offset (host writes the response there).
const tileWat = r'''
(module
  (import "nixblitz" "host_call" (func $hc (param i32 i32) (result i64)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fdw (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0)
    "{\"v\":1,\"cap\":\"bitcoin_rpc\",\"method\":\"getblockchaininfo\",\"params\":[]}")
  (data (i32.const 200) "{\"Network\":\"regtest\"}")
  (func (export "alloc") (param i32) (result i32) (i32.const 4096))
  (func (export "tile")
    (drop (call $hc (i32.const 0) (i32.const 68)))
    ;; iov at 300: base=200 len=21
    (i32.store (i32.const 300) (i32.const 200))
    (i32.store (i32.const 304) (i32.const 21))
    (drop (call $fdw (i32.const 1) (i32.const 300) (i32.const 1) (i32.const 320)))))
''';

class FakeExecutor implements BitcoinRpcExecutor {
  final List<String> calls = [];
  @override
  RpcResult call(String method, List params) {
    calls.add(method);
    return RpcResult(ok: true, result: {'blocks': 5}, stderr: '');
  }
}

void main() {
  late Directory tmp;
  late WasmActionRunner runner;
  late FakeExecutor executor;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pwr_');
    runner = WasmActionRunner(
      library: WasmtimeLibrary.discover(),
      cacheDir: '${tmp.path}/cache',
    );
    executor = FakeExecutor();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  PluginManifest mf() => PluginManifest.fromJson({
    'manifest': {'schema_version': 5, 'name': 'T'},
    'id': 'tplugin',
    'actions': {
      'a': {
        'label': 'a',
        'wasm': {'module': 't.wasm'},
      },
    },
    'sandbox': {
      'bitcoin_rpc': {
        'methods': ['getblockchaininfo'],
      },
    },
  });

  test('quiet run returns pure guest stdout + wires the handler', () async {
    // Compile the WAT to a .wasm on disk.
    final engine = Engine(WasmtimeLibrary.discover());
    final bytes = watToWasm(engine, tileWat);
    engine.dispose();
    File('${tmp.path}/t.wasm').writeAsBytesSync(bytes);

    final run = await runPluginWasm(
      runner: runner,
      manifest: mf(),
      pluginDir: tmp.path,
      moduleRelPath: 't.wasm',
      export: 'tile',
      stateDir: '${tmp.path}/state',
      executor: executor,
      quiet: true,
    );
    final out = await run.output.join();
    final code = await run.exitCode;
    expect(code, 0);
    expect(executor.calls, ['getblockchaininfo']);
    // No "> wasm action" header; stdout is the flat JSON the guest emitted.
    expect(out.trim(), '{"Network":"regtest"}');
  });
}
