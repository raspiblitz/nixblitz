import 'dart:convert';
import 'dart:io';

/// Result of one bitcoind RPC via bitcoin-cli.
class RpcResult {
  RpcResult({required this.ok, required this.result, required this.stderr});
  final bool ok;
  final dynamic result; // decoded JSON (or a raw string for non-JSON output)
  final String stderr;
}

/// Runs a bitcoind method. Injected into HostCallHandler so tests use a
/// fake and never touch a node.
abstract class BitcoinRpcExecutor {
  RpcResult call(String method, List<dynamic> params);
}

/// Real executor: shells out to `bitcoin-cli`, which nix-bitcoin wraps
/// with the operator's cookie auth (same path the streamers use). The
/// guest never sees credentials.
class BitcoinCliExecutor implements BitcoinRpcExecutor {
  BitcoinCliExecutor({this.systemPath = '/run/current-system/sw/bin'});
  final String systemPath;

  @override
  RpcResult call(String method, List<dynamic> params) {
    final args = <String>[
      method,
      for (final p in params) p is String ? p : jsonEncode(p),
    ];
    final env = {
      ...Platform.environment,
      'PATH': '$systemPath:${Platform.environment['PATH'] ?? ''}',
    };
    final r = Process.runSync(
      'bitcoin-cli',
      args,
      environment: env,
      includeParentEnvironment: false,
    );
    if (r.exitCode != 0) {
      return RpcResult(
        ok: false,
        result: null,
        stderr: (r.stderr as String).trim(),
      );
    }
    final out = (r.stdout as String).trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(out);
    } catch (_) {
      decoded = out; // some methods return a bare string (e.g. a txid)
    }
    return RpcResult(ok: true, result: decoded, stderr: '');
  }
}
