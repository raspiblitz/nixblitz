import 'dart:convert';

import '../../models/plugin/sandbox_spec.dart';

/// bitcoind methods that can move funds. A method NOT in this set is
/// read-only for budget purposes.
const Set<String> spendCapableBitcoinMethods = {
  'sendtoaddress',
  'sendmany',
  'send',
  'sendrawtransaction',
  'fundrawtransaction',
  'walletcreatefundedpsbt',
};

bool isSpendCapable(String method) =>
    spendCapableBitcoinMethods.contains(method);

/// Intended sats a call moves, derived from its params — or null if the
/// cost cannot be attributed from params alone (such methods are not
/// allowlistable in v1; install validation rejects them). Read methods
/// return 0.
int? attributedSpendSats(String method, List<dynamic> params) {
  if (!isSpendCapable(method)) return 0;
  switch (method) {
    case 'sendtoaddress':
      // params: [address, amount(BTC), ...]
      if (params.length >= 2 && params[1] is num) {
        return ((params[1] as num) * 100000000).round();
      }
      return null;
    default:
      return null; // unattributable in v1
  }
}

/// Raised by HostRequest.parse on malformed guest input.
class HostRequestError implements Exception {
  HostRequestError(this.code, this.message);
  final String code;
  final String message;
}

/// A parsed, validated host_call request envelope.
class HostRequest {
  HostRequest(this.v, this.cap, this.method, this.params);
  final int v;
  final String cap;
  final String method;
  final List<dynamic> params;

  static HostRequest parse(String jsonStr) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      throw HostRequestError('bad_request', 'request is not valid JSON');
    }
    if (decoded is! Map) {
      throw HostRequestError('bad_request', 'request must be a JSON object');
    }
    final v = decoded['v'];
    final cap = decoded['cap'];
    final method = decoded['method'];
    final params = decoded['params'] ?? const [];
    if (v is! int) {
      throw HostRequestError('bad_request', 'missing/invalid `v`');
    }
    if (cap is! String || cap.isEmpty) {
      throw HostRequestError('bad_request', 'missing/invalid `cap`');
    }
    if (method is! String || method.isEmpty) {
      throw HostRequestError('bad_request', 'missing/invalid `method`');
    }
    if (params is! List) {
      throw HostRequestError('bad_request', '`params` must be an array');
    }
    return HostRequest(v, cap, method, params);
  }
}

/// Serializers for the response envelope.
class HostResponse {
  static String ok(dynamic result) => jsonEncode({'v': 1, 'ok': result});
  static String err(String code, String message) => jsonEncode({
    'v': 1,
    'err': {'code': code, 'message': message},
  });
}

/// Outcome of the policy gate for one call.
sealed class PolicyDecision {
  const PolicyDecision();
}

class PolicyAllow extends PolicyDecision {
  const PolicyAllow(this.reserveSats);

  /// Sats to reserve on the ledger before executing (null/0 = no spend).
  final int? reserveSats;
}

class PolicyDeny extends PolicyDecision {
  const PolicyDeny(this.code, this.message);
  final String code;
  final String message;
}

/// The allowlist + budget gate. Pure: [spentToday] is supplied by the
/// caller (from the BudgetLedger) so this stays node- and clock-free.
PolicyDecision checkCall({
  required BitcoinRpcCapability cap,
  required String method,
  required List<dynamic> params,
  required int spentToday,
}) {
  if (!cap.methods.contains(method)) {
    return PolicyDeny(
      'method_not_allowed',
      'method `$method` is not in this plugin\'s allowlist',
    );
  }
  if (!isSpendCapable(method)) {
    return const PolicyAllow(0);
  }
  final intended = attributedSpendSats(method, params);
  if (intended == null) {
    return PolicyDeny(
      'method_not_allowed',
      'method `$method` has an unattributable spend and is not permitted',
    );
  }
  if (spentToday + intended > cap.spendSatsPerDay) {
    return PolicyDeny(
      'budget_exceeded',
      'spend of $intended sats would exceed the daily cap '
          '(${cap.spendSatsPerDay}, already spent $spentToday)',
    );
  }
  return PolicyAllow(intended);
}
