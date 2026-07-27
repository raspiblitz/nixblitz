import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/viewport_provider.dart';
import 'popup_chrome.dart';
import 'scrollable_log.dart';

/// Full transcript of the most recent `nixblitz check` run — opened
/// via `[o]` from the System → Updates panel. Exists because the
/// panel's inline "Last check" block is a static, non-scrollable
/// `Text` that either hides a long nix error below the fold or (for
/// a successful run) shows nothing at all about the work the check
/// actually did. This popup shows the whole bounded transcript
/// (`CheckResult.transcript`) in a scrollable, searchable log —
/// useful on both success ("see the work it's doing") and failure
/// (the error line is often buried under hundreds of lines of nix
/// output that never made it past the inline summary).
class UpdateCheckLogPopup extends StatelessComponent {
  final List<String> transcript;
  final VoidCallback onClose;

  const UpdateCheckLogPopup({required this.transcript, required this.onClose});

  @override
  Component build(BuildContext context) {
    final viewportWidth = context.watch(viewportSizeProvider).width;
    final viewportHeight = context.watch(viewportSizeProvider).height;
    final width = math.min(100, math.max(30, viewportWidth - 6));
    final height = math.min(30, math.max(10, viewportHeight - 6));

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape) {
          onClose();
          return true;
        }
        return false;
      },
      child: Center(
        child: PopupChrome(
          width: width.toDouble(),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: SizedBox(
            height: height.toDouble(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Update check — full log',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: kPopupAccent,
                  ),
                ),
                const Divider(),
                Expanded(
                  child: transcript.isEmpty
                      ? const Center(
                          child: Text(
                            'No log recorded for the last check.',
                            style: TextStyle(color: kPopupDim),
                          ),
                        )
                      : ScrollableLog(
                          lines: transcript,
                          textColor: kPopupBody,
                          focused: true,
                          ignoreModalGate: true,
                          onKeyEvent: (event) {
                            if (event.logicalKey == LogicalKey.escape) {
                              onClose();
                              return true;
                            }
                            return false;
                          },
                        ),
                ),
                const Divider(),
                const Text(
                  '↑/↓ j/k scroll   / search   Esc close',
                  style: TextStyle(color: kPopupDim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
