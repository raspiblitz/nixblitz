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

  test('denies a negative spend amount (fail-open closure)', () {
    // Without the fix, `spentToday + intended > cap` is false for a
    // negative `intended`, so this would be allowed and reserve a
    // NEGATIVE ledger entry — fail-open if the process dies before the
    // reservation is cancelled/settled.
    final d = checkCall(
      cap: spendCap,
      method: 'sendtoaddress',
      params: ['bc1..', -10.0],
      spentToday: 0,
    );
    expect(d, isA<PolicyDeny>());
    expect((d as PolicyDeny).code, 'method_not_allowed');
  });

  test('denies a zero spend amount', () {
    final d = checkCall(
      cap: spendCap,
      method: 'sendtoaddress',
      params: ['bc1..', 0.0],
      spentToday: 0,
    );
    expect(d, isA<PolicyDeny>());
  });

  test('denies an absurdly large spend amount without throwing', () {
    // A guest-supplied 1e300 BTC amount must be denied; checkCall must
    // never let an UnsupportedError (or any exception) escape.
    final d = checkCall(
      cap: spendCap,
      method: 'sendtoaddress',
      params: ['bc1..', 1e300],
      spentToday: 0,
    );
    expect(d, isA<PolicyDeny>());
  });

  test('attributedSpendSats returns null (not throws) for huge amounts', () {
    expect(attributedSpendSats('sendtoaddress', ['bc1..', 1e300]), isNull);
    expect(
      attributedSpendSats('sendtoaddress', ['bc1..', double.infinity]),
      isNull,
    );
    expect(attributedSpendSats('sendtoaddress', ['bc1..', double.nan]), isNull);
  });

  test('a huge integer amount cannot int-wrap past the cap', () {
    // A JSON integer literal (not a double) large enough that
    // `amount * 1e8` would overflow int64 and wrap to a small positive
    // value must be rejected as unattributable, not silently accepted.
    expect(attributedSpendSats('sendtoaddress', ['bc1..', 1 << 62]), isNull);
    expect(attributedSpendSats('sendtoaddress', ['bc1..', 21000001]), isNull);
    // Exactly MAX_MONEY BTC is the boundary — still attributable.
    expect(
      attributedSpendSats('sendtoaddress', ['bc1..', 21000000]),
      21000000 * 100000000,
    );
  });

  test('a normal positive spend within budget is still allowed', () {
    final d = checkCall(
      cap: spendCap,
      method: 'sendtoaddress',
      params: ['bc1..', 0.000001], // 100 sats
      spentToday: 0,
    );
    expect(d, isA<PolicyAllow>());
    expect((d as PolicyAllow).reserveSats, 100);
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
