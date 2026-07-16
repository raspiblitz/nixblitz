/// Declarative sandbox capability block from a plugin manifest's
/// top-level `sandbox` field (schema v5). This is the plugin's ENTIRE
/// requested authority — deny-by-default, shown verbatim at consent.
class SandboxSpec {
  const SandboxSpec({this.bitcoinRpc, this.limits = const SandboxLimits()});

  final BitcoinRpcCapability? bitcoinRpc;
  final SandboxLimits limits;

  bool get hasBitcoinRpc => bitcoinRpc != null;

  factory SandboxSpec.fromJson(Map<String, dynamic> json) {
    final rpcRaw = json['bitcoin_rpc'];
    final rpc = rpcRaw is Map<String, dynamic>
        ? BitcoinRpcCapability.fromJson(rpcRaw)
        : null;
    final limitsRaw = json['limits'];
    final limits = limitsRaw is Map<String, dynamic>
        ? SandboxLimits.fromJson(limitsRaw)
        : const SandboxLimits();
    return SandboxSpec(bitcoinRpc: rpc, limits: limits);
  }

  Map<String, dynamic> toJson() => {
    if (bitcoinRpc != null) 'bitcoin_rpc': bitcoinRpc!.toJson(),
    'limits': limits.toJson(),
  };
}

/// The `bitcoin_rpc` capability: an allowlist of bitcoind methods and a
/// daily spend cap enforced by the policy gate.
class BitcoinRpcCapability {
  const BitcoinRpcCapability({required this.methods, this.spendSatsPerDay = 0});

  final List<String> methods;

  /// Daily spend cap in sats. 0 = the plugin may call no spend-capable
  /// method (and none may appear in [methods]).
  final int spendSatsPerDay;

  factory BitcoinRpcCapability.fromJson(Map<String, dynamic> json) {
    final rawMethods = json['methods'];
    if (rawMethods is! List) {
      throw const FormatException('bitcoin_rpc.methods must be a list');
    }
    final methods = <String>[];
    for (final m in rawMethods) {
      if (m is! String || m.isEmpty) {
        throw FormatException(
          'bitcoin_rpc.methods entries must be non-empty '
          'strings, got ${m.runtimeType}',
        );
      }
      methods.add(m);
    }
    final budgets = json['budgets'];
    var spend = 0;
    if (budgets is Map<String, dynamic>) {
      final raw = budgets['spend_sats_per_day'] ?? 0;
      if (raw is! int || raw < 0) {
        throw FormatException(
          'bitcoin_rpc.budgets.spend_sats_per_day must be a non-negative '
          'integer, got $raw',
        );
      }
      spend = raw;
    }
    return BitcoinRpcCapability(
      methods: List<String>.unmodifiable(methods),
      spendSatsPerDay: spend,
    );
  }

  Map<String, dynamic> toJson() => {
    'methods': methods,
    'budgets': {'spend_sats_per_day': spendSatsPerDay},
  };
}

/// Execution limits the guest requests; the runner clamps each to a
/// host-side maximum before applying.
class SandboxLimits {
  const SandboxLimits({this.fuel = 500000000, this.timeoutSeconds = 10});

  final int fuel;
  final int timeoutSeconds;

  factory SandboxLimits.fromJson(Map<String, dynamic> json) {
    final fuel = json['fuel'] ?? 500000000;
    final timeout = json['timeout_seconds'] ?? 10;
    if (fuel is! int || fuel <= 0) {
      throw FormatException('sandbox.limits.fuel must be positive, got $fuel');
    }
    if (timeout is! int || timeout <= 0) {
      throw FormatException(
        'sandbox.limits.timeout_seconds must be positive, got $timeout',
      );
    }
    return SandboxLimits(fuel: fuel, timeoutSeconds: timeout);
  }

  Map<String, dynamic> toJson() => {
    'fuel': fuel,
    'timeout_seconds': timeoutSeconds,
  };
}
