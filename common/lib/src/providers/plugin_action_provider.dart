import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/sudo_session_provider.dart';
import 'package:common/src/services/plugin_action_runner.dart';

/// Stateless runner — one instance is enough for the whole app.
/// Privileged `unit:` actions dispatch through the shared SudoSession,
/// reusing the same auth timestamp the rest of the TUI primes for
/// rebuild / chpasswd / etc.
final pluginActionRunnerProvider = Provider<PluginActionRunner>((ref) {
  return PluginActionRunner(sudoSession: ref.watch(sudoSessionProvider));
});
