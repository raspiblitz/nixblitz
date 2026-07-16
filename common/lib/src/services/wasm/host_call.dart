import '../../models/plugin/sandbox_spec.dart';
import 'bitcoin_rpc_executor.dart';
import 'budget_ledger.dart';
import 'sandbox_policy.dart';

/// The policy-enforcing body behind the `nixblitz.host_call` import.
/// Pure Dart over strings: the runner handles the wasm memory marshaling
/// and passes the request JSON in, the response JSON out.
class HostCallHandler {
  HostCallHandler({
    required this.sandbox,
    required this.ledger,
    required this.executor,
    required this.clock,
  });

  final SandboxSpec sandbox;
  final BudgetLedger ledger;
  final BitcoinRpcExecutor executor;
  final DateTime Function() clock;

  String handle(String requestJson) {
    final HostRequest req;
    try {
      req = HostRequest.parse(requestJson);
    } on HostRequestError catch (e) {
      return HostResponse.err(e.code, e.message);
    }

    if (req.cap != 'bitcoin_rpc') {
      return HostResponse.err(
        'unknown_capability',
        'capability `${req.cap}` is not supported',
      );
    }
    final cap = sandbox.bitcoinRpc;
    if (cap == null) {
      return HostResponse.err(
        'unknown_capability',
        'this plugin was granted no bitcoin_rpc access',
      );
    }

    final now = clock();
    final decision = checkCall(
      cap: cap,
      method: req.method,
      params: req.params,
      spentToday: ledger.spentWithin(now),
    );

    switch (decision) {
      case PolicyDeny(:final code, :final message):
        return HostResponse.err(code, message);
      case PolicyAllow(:final reserveSats):
        String? reservationId;
        if (reserveSats != null && reserveSats > 0) {
          try {
            reservationId = ledger.reserve(now, req.method, reserveSats);
          } on BudgetLedgerException catch (e) {
            return HostResponse.err(
              'budget_exceeded',
              'could not reserve budget (refused): ${e.message}',
            );
          }
        }
        final RpcResult r;
        try {
          r = executor.call(req.method, req.params);
        } catch (e) {
          if (reservationId != null) ledger.cancel(reservationId);
          return HostResponse.err('rpc_failed', 'executor error: $e');
        }
        if (!r.ok) {
          if (reservationId != null) ledger.cancel(reservationId);
          return HostResponse.err('rpc_failed', r.stderr);
        }
        // v1: settle to the reserved amount (the tx result's fee is not
        // parsed yet — a later slice refines actual-spend attribution).
        if (reservationId != null) {
          ledger.settle(reservationId, reserveSats!);
        }
        return HostResponse.ok(r.result);
    }
  }
}
