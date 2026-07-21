import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';

import '../../providers/viewport_provider.dart';
import 'popup_chrome.dart';

/// Confirm-style popup nudging the operator to apply pending changes.
/// Surfaced after an action that produces pending changes (plugin
/// install complete, leaving Configure with edits). `[y]` routes to
/// the Apply review screen; `[n]` / Esc dismisses. See
/// docs/superpowers/specs/2026-05-19-apply-now-prompt-design.md.
class ApplyNowPopup extends StatelessComponent {
  final String? headline;
  final int pendingCount;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ApplyNowPopup({
    super.key,
    this.headline,
    required this.pendingCount,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Component build(BuildContext context) {
    final width = math.min(
      56,
      math.max(20, context.watch(viewportSizeProvider).width - 4),
    );
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyY) {
            onConfirm();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyN ||
              event.logicalKey == LogicalKey.escape) {
            onCancel();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Apply-now popup key handler failed', e, st);
          return true;
        }
      },
      child: Center(
        child: PopupChrome(
          width: width.toDouble(),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Apply now?',
                style: TextStyle(
                  color: kPopupAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (headline != null)
                Text(headline!, style: const TextStyle(color: kPopupBody)),
              Text(
                applyNowPendingSummary(pendingCount),
                style: const TextStyle(color: kPopupBody),
              ),
              const SizedBox(height: 1),
              const Text(
                'Applying runs `nixos-rebuild switch` (~2-5 min).',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
              const SizedBox(height: 1),
              const Text(
                '[y] Apply now   [n] Keep working',
                style: TextStyle(color: kPopupDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Terse one-line pending summary for the popup body. Top-level pure
/// function so it's unit-testable without the nocterm widget.
String applyNowPendingSummary(int pendingCount) {
  if (pendingCount <= 0) return 'You have pending changes.';
  if (pendingCount == 1) return '1 pending change.';
  return '$pendingCount pending changes.';
}
