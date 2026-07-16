import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

class FakeExecutor implements BitcoinRpcExecutor {
  FakeExecutor(this._results);
  final Map<String, RpcResult> _results;
  final List<String> calls = [];
  @override
  RpcResult call(String method, List params) {
    calls.add(method);
    return _results[method] ??
        RpcResult(ok: false, result: null, stderr: 'no fake for $method');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('hostcall_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  DateTime clock() => DateTime.utc(2026, 7, 16, 12);

  HostCallHandler handler(SandboxSpec sandbox, FakeExecutor ex) =>
      HostCallHandler(
        sandbox: sandbox,
        ledger: BudgetLedger('${tmp.path}/b.json'),
        executor: ex,
        clock: clock,
      );

  const readSandbox = SandboxSpec(
    bitcoinRpc: BitcoinRpcCapability(
      methods: ['getblockchaininfo'],
      spendSatsPerDay: 0,
    ),
  );

  test('allowed read method returns ok with the rpc result', () {
    final ex = FakeExecutor({
      'getblockchaininfo': RpcResult(
        ok: true,
        result: {'blocks': 42},
        stderr: '',
      ),
    });
    final resp = handler(readSandbox, ex).handle(
      '{"v":1,"cap":"bitcoin_rpc","method":"getblockchaininfo","params":[]}',
    );
    expect(resp, '{"v":1,"ok":{"blocks":42}}');
    expect(ex.calls, ['getblockchaininfo']);
  });

  test('non-allowlisted method is refused and never executed', () {
    final ex = FakeExecutor({});
    final resp = handler(
      readSandbox,
      ex,
    ).handle('{"v":1,"cap":"bitcoin_rpc","method":"stop","params":[]}');
    expect(resp, contains('method_not_allowed'));
    expect(ex.calls, isEmpty);
  });

  test('unknown capability is refused', () {
    final resp = handler(
      readSandbox,
      FakeExecutor({}),
    ).handle('{"v":1,"cap":"lightning","method":"x","params":[]}');
    expect(resp, contains('unknown_capability'));
  });

  test('rpc failure surfaces rpc_failed with stderr', () {
    final ex = FakeExecutor({
      'getblockchaininfo': RpcResult(
        ok: false,
        result: null,
        stderr: 'connection refused',
      ),
    });
    final resp = handler(readSandbox, ex).handle(
      '{"v":1,"cap":"bitcoin_rpc","method":"getblockchaininfo","params":[]}',
    );
    expect(resp, contains('rpc_failed'));
    expect(resp, contains('connection refused'));
  });

  test('a spend within budget executes and is accounted', () {
    const spendSandbox = SandboxSpec(
      bitcoinRpc: BitcoinRpcCapability(
        methods: ['sendtoaddress'],
        spendSatsPerDay: 1000,
      ),
    );
    final ex = FakeExecutor({
      'sendtoaddress': RpcResult(ok: true, result: 'txid', stderr: ''),
    });
    final h = handler(spendSandbox, ex);
    final resp = h.handle(
      '{"v":1,"cap":"bitcoin_rpc","method":"sendtoaddress",'
      '"params":["bc1..",0.000005]}',
    );
    expect(resp, contains('txid'));
    expect(ex.calls, ['sendtoaddress']);
  });

  test('a spend over budget is refused and never executed', () {
    const spendSandbox = SandboxSpec(
      bitcoinRpc: BitcoinRpcCapability(
        methods: ['sendtoaddress'],
        spendSatsPerDay: 100,
      ),
    );
    final ex = FakeExecutor({});
    final resp = handler(spendSandbox, ex).handle(
      '{"v":1,"cap":"bitcoin_rpc","method":"sendtoaddress",'
      '"params":["bc1..",0.00001]}',
    ); // 1000 sats > 100
    expect(resp, contains('budget_exceeded'));
    expect(ex.calls, isEmpty);
  });

  test('malformed request json returns bad_request', () {
    final resp = handler(readSandbox, FakeExecutor({})).handle('garbage');
    expect(resp, contains('bad_request'));
  });
}
