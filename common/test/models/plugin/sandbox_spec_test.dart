import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  test('parses a full sandbox block', () {
    final s = SandboxSpec.fromJson({
      'bitcoin_rpc': {
        'methods': ['getblockchaininfo', 'getnetworkinfo'],
        'budgets': {'spend_sats_per_day': 1000},
      },
      'limits': {'fuel': 123, 'timeout_seconds': 7},
    });
    expect(s.hasBitcoinRpc, isTrue);
    expect(s.bitcoinRpc!.methods, ['getblockchaininfo', 'getnetworkinfo']);
    expect(s.bitcoinRpc!.spendSatsPerDay, 1000);
    expect(s.limits.fuel, 123);
    expect(s.limits.timeoutSeconds, 7);
  });

  test('defaults: no bitcoin_rpc, default limits', () {
    final s = SandboxSpec.fromJson({});
    expect(s.hasBitcoinRpc, isFalse);
    expect(s.limits.fuel, 500000000);
    expect(s.limits.timeoutSeconds, 10);
  });

  test('spend_sats_per_day defaults to 0 when budgets absent', () {
    final s = SandboxSpec.fromJson({
      'bitcoin_rpc': {
        'methods': ['getblockchaininfo'],
      },
    });
    expect(s.bitcoinRpc!.spendSatsPerDay, 0);
  });

  test('rejects non-string methods', () {
    expect(
      () => SandboxSpec.fromJson({
        'bitcoin_rpc': {
          'methods': [1, 2],
        },
      }),
      throwsFormatException,
    );
  });

  test('rejects negative spend budget', () {
    expect(
      () => SandboxSpec.fromJson({
        'bitcoin_rpc': {
          'methods': ['getblockchaininfo'],
          'budgets': {'spend_sats_per_day': -1},
        },
      }),
      throwsFormatException,
    );
  });

  test('round-trips through toJson', () {
    final json = {
      'bitcoin_rpc': {
        'methods': ['getblockchaininfo'],
        'budgets': {'spend_sats_per_day': 500},
      },
      'limits': {'fuel': 42, 'timeout_seconds': 3},
    };
    expect(SandboxSpec.fromJson(json).toJson(), json);
  });
}
