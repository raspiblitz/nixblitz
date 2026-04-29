import 'dart:async';
import 'dart:typed_data';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';

import 'package:common/src/services/sudo_session.dart';

/// Holds an in-flight password request the UI must surface as a
/// modal. Set by [sudoSessionProvider]'s registered callback when
/// [SudoSession.ensureFresh] needs to prompt; cleared after the
/// completer resolves.
class PendingSudoPrompt {
  PendingSudoPrompt({required this.reason, required this.completer});
  final String reason;
  final Completer<Uint8List?> completer;
}

final pendingSudoPromptProvider = StateProvider<PendingSudoPrompt?>(
  (_) => null,
);

/// Process-wide [SudoSession]. The password callback is wired here
/// (rather than registered separately by the TUI) so any provider
/// reading this gets a fully-bound session.
final sudoSessionProvider = Provider<SudoSession>((ref) {
  final s = SudoSession();
  s.setPasswordCallback((reason) async {
    final completer = Completer<Uint8List?>();
    ref.read(pendingSudoPromptProvider.notifier).state = PendingSudoPrompt(
      reason: reason,
      completer: completer,
    );
    try {
      return await completer.future;
    } finally {
      // Always clear so the UI doesn't keep rendering a stale modal
      // even if the caller never re-prompts.
      ref.read(pendingSudoPromptProvider.notifier).state = null;
    }
  });
  ref.onDispose(() async {
    await s.forget();
  });
  return s;
});
