import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/viewport_provider.dart';
import 'password_input.dart';
import 'popup_chrome.dart';

/// Watches [pendingSudoPromptProvider] and renders a centered,
/// bordered password modal whenever a [SudoSession.ensureFresh]
/// call is awaiting a password. Resolves the underlying completer
/// on submit (with the typed bytes) or on cancel (with null).
///
/// Place inside the app shell's [Stack] *after* the regular content
/// and any other overlays so the modal grabs focus.
class PasswordOverlay extends StatelessComponent {
  const PasswordOverlay({super.key});

  @override
  Component build(BuildContext context) {
    final pending = context.watch(pendingSudoPromptProvider);
    if (pending == null) return const SizedBox.shrink();

    // Shrink to fit narrow terminals — sudo on a phone-over-SSH
    // session needs the input fully visible.
    final viewportWidth = context.watch(viewportSizeProvider).width;
    final width = math.min(64, math.max(20, viewportWidth - 4));

    return Center(
      child: PopupChrome(
        width: width.toDouble(),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: PasswordInput(
          title: pending.reason,
          subtitle:
              'sudo wants your admin password. '
              'Enter to submit, Esc to cancel.',
          minLength: 1,
          requireConfirmation: false,
          onSubmit: (password) {
            if (pending.completer.isCompleted) return;
            final bytes = Uint8List.fromList(utf8.encode(password));
            pending.completer.complete(bytes);
          },
          onCancel: () {
            if (pending.completer.isCompleted) return;
            pending.completer.complete(null);
          },
        ),
      ),
    );
  }
}
