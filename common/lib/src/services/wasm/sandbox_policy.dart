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

/// Total sats that could ever exist (21M BTC * 1e8). Any attributed spend
/// above this is definitionally bogus — either a guest sending a
/// non-finite/huge amount (e.g. `1e300` BTC) or a unit mismatch. Treating
/// it as unattributable (null) keeps the result honest instead of
/// silently clamping to `double.round()`'s int64-max behavior, which
/// would otherwise smuggle a "valid-looking" but meaningless sats figure
/// through the policy gate.
const int _maxAttributableSats = 21000000 * 100000000;

/// Intended sats a call moves, derived from its params — or null if the
/// cost cannot be attributed from params alone (such methods are not
/// allowlistable in v1; install validation rejects them). Read methods
/// return 0.
///
/// Returns null (unattributable → denied by the caller) rather than
/// throwing or silently clamping when the computed amount is non-finite
/// or absurdly large (e.g. a guest-supplied `1e300` BTC amount). Guards
/// both `NaN`/infinity (which `.round()` rejects with `UnsupportedError`)
/// and merely-huge-but-finite doubles that `.round()` would otherwise
/// happily clamp to `int64` max.
int? attributedSpendSats(String method, List<dynamic> params) {
  if (!isSpendCapable(method)) return 0;
  switch (method) {
    case 'sendtoaddress':
      // params: [address, amount(BTC), ...]
      if (params.length >= 2 && params[1] is num) {
        final amount = params[1] as num;
        // Bound the BTC amount BEFORE multiplying — a huge JSON integer
        // literal would int-overflow (wrap) in `amount * 100000000` on the
        // VM, possibly wrapping to a small positive value that slips the
        // cap. Anything past MAX_MONEY is unattributable (bitcoind would
        // reject it anyway).
        if (!amount.isFinite || amount.abs() > 21000000) return null;
        final sats = amount * 100000000;
        if (!sats.isFinite || sats.abs() > _maxAttributableSats) return null;
        return sats.round();
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
  // A non-positive intended spend (guest passes a negative or zero
  // amount) must never reach the reserve step below. `spentToday +
  // intended > cap` is FALSE for a negative `intended`, so without this
  // guard the call would be allowed and the ledger would reserve a
  // NEGATIVE entry. If the process dies between reserve and cancel/settle
  // (§3e), that negative reservation inflates the remaining daily
  // budget on every subsequent read — a fail-OPEN hole in an otherwise
  // fail-closed design.
  if (intended <= 0) {
    return const PolicyDeny(
      'method_not_allowed',
      'spend amount must be positive',
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
