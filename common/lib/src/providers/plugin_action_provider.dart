import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'package:common/src/providers/sudo_session_provider.dart';
import 'package:common/src/services/plugin_action_runner.dart';
import 'package:common/src/services/wasm/wasm_action_runner.dart';

/// Stateless runner — one instance is enough for the whole app.
/// Privileged `unit:` actions dispatch through the shared SudoSession,
/// reusing the same auth timestamp the rest of the TUI primes for
/// rebuild / chpasswd / etc.
final pluginActionRunnerProvider = Provider<PluginActionRunner>((ref) {
  return PluginActionRunner(sudoSession: ref.watch(sudoSessionProvider));
});

/// Sandbox runtime home + module cache under the nixblitz state dir.
///
/// Native-only and read lazily — only the `wasm:` action path touches
/// this provider, so `command:`/`unit:` flows never construct a
/// [WasmtimeLibrary] (and never need libwasmtime.so on disk).
final wasmActionRunnerProvider = Provider<WasmActionRunner>((ref) {
  final home = Platform.environment['HOME'] ?? '.';
  return WasmActionRunner(
    library: WasmtimeLibrary.discover(),
    cacheDir: '$home/nixblitz/state/sandbox/modules',
  );
});
