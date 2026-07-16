import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  const readCap = BitcoinRpcCapability(
    methods: ['getblockchaininfo'],
    spendSatsPerDay: 0,
  );
  const spendCap = BitcoinRpcCapability(
    methods: ['sendtoaddress'],
    spendSatsPerDay: 1000,
  );

  test('spend-capable classification', () {
    expect(isSpendCapable('sendtoaddress'), isTrue);
    expect(isSpendCapable('getblockchaininfo'), isFalse);
  });

  test('attributes sendtoaddress amount (BTC->sats)', () {
    expect(attributedSpendSats('sendtoaddress', ['bc1..', 0.0001]), 10000);
    expect(attributedSpendSats('getblockchaininfo', []), 0);
  });

  test('allows an allowlisted read method', () {
    final d = checkCall(
      cap: readCap,
      method: 'getblockchaininfo',
      params: [],
      spentToday: 0,
    );
    expect(d, isA<PolicyAllow>());
    expect((d as PolicyAllow).reserveSats, anyOf(isNull, 0));
  });

  test('denies a non-allowlisted method', () {
    final d = checkCall(
      cap: readCap,
      method: 'stop',
      params: [],
      spentToday: 0,
    );
    expect((d as PolicyDeny).code, 'method_not_allowed');
  });

  test('allows a spend within budget and reserves it', () {
    final d = checkCall(
      cap: spendCap,
      method: 'sendtoaddress',
      params: ['bc1..', 0.000005], // 500 sats
      spentToday: 0,
    );
    expect((d as PolicyAllow).reserveSats, 500);
  });

  test('denies a spend that exceeds the remaining budget', () {
    final d = checkCall(
      cap: spendCap,
      method: 'sendtoaddress',
      params: ['bc1..', 0.00001], // 1000 sats
      spentToday: 600,
    ); // only 400 left
    expect((d as PolicyDeny).code, 'budget_exceeded');
  });

  test('HostRequest.parse rejects malformed json', () {
    expect(
      () => HostRequest.parse('not json'),
      throwsA(isA<HostRequestError>()),
    );
  });

  test('HostResponse.ok/err serialize with version', () {
    expect(HostResponse.ok({'a': 1}), '{"v":1,"ok":{"a":1}}');
    expect(
      HostResponse.err('rpc_failed', 'boom'),
      '{"v":1,"err":{"code":"rpc_failed","message":"boom"}}',
    );
  });
}
