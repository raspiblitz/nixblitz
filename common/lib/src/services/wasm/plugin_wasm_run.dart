import '../../models/plugin/plugin_manifest.dart';
import '../../models/plugin/sandbox_spec.dart';
import 'bitcoin_rpc_executor.dart';
import 'budget_ledger.dart';
import 'host_call.dart';
import 'wasm_action_runner.dart';

/// Builds the sandbox [HostCallHandler] for [manifest] and runs its wasm
/// [export] via [runner]. Returns the runner's (output, exitCode): the
/// action view streams `output` to its pane; the tile poller drains it.
///
/// [moduleRelPath] is the plugin-dir-relative `.wasm` path (from the
/// action's or tile's `wasm.module`). [stateDir] is the sandbox state
/// root (`$HOME/nixblitz/state/sandbox`); the per-plugin budget ledger
/// lives at `<stateDir>/budgets/<id>.json`. [executor] defaults to the
/// real bitcoin-cli executor; tests inject a fake.
Future<({Stream<String> output, Future<int> exitCode})> runPluginWasm({
  required WasmActionRunner runner,
  required PluginManifest manifest,
  required String pluginDir,
  required String moduleRelPath,
  required String export,
  required String stateDir,
  BitcoinRpcExecutor? executor,
  bool quiet = false,
}) {
  final sandbox = manifest.sandbox ?? const SandboxSpec();
  final handler = HostCallHandler(
    sandbox: sandbox,
    ledger: BudgetLedger('$stateDir/budgets/${manifest.id}.json'),
    executor: executor ?? BitcoinCliExecutor(),
    clock: DateTime.now,
  );
  return runner.run(
    wasmPath: '$pluginDir/$moduleRelPath',
    export: export,
    sandbox: sandbox,
    hostCall: handler,
    quiet: quiet,
  );
}
