import 'dart:async';
import 'dart:math' as math;

import 'package:common/common.dart' show LogService;
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/viewport_provider.dart';
import 'popup_chrome.dart';
import 'scrollable_log.dart';

/// Live LND journal viewer for the wizard's seed-wait step ([l]).
/// Poll-based on purpose: each 2 s tick runs a short-lived
/// `journalctl -n 150` via the injected [fetchJournal] — no
/// `journalctl -f` stream to manage, nothing to tear down beyond the
/// timer. Fetch errors become the popup's content; the wizard is never
/// affected.
class LndJournalPopup extends StatefulComponent {
  const LndJournalPopup({required this.fetchJournal, required this.onClose});

  final Future<String> Function() fetchJournal;
  final VoidCallback onClose;

  @override
  State<LndJournalPopup> createState() => _LndJournalPopupState();
}

class _LndJournalPopupState extends State<LndJournalPopup> {
  List<String> _lines = const ['Loading LND journal…'];
  Timer? _timer;
  bool _fetching = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final out = await component.fetchJournal();
      if (_disposed) return;
      setState(() {
        _lines = out.split('\n');
      });
    } catch (e, st) {
      LogService.error('LndJournalPopup: journal fetch failed', e, st);
      if (_disposed) return;
      setState(() {
        _lines = ['Journal fetch failed: $e'];
      });
    } finally {
      _fetching = false;
    }
  }

  @override
  Component build(BuildContext context) {
    final viewportWidth = context.watch(viewportSizeProvider).width;
    final viewportHeight = context.watch(viewportSizeProvider).height;
    final width = math.min(100, math.max(30, viewportWidth - 6));
    final height = math.min(30, math.max(10, viewportHeight - 6));

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            component.onClose();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('LndJournalPopup key handler failed', e, st);
          return true;
        }
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
                  'LND journal (refreshes every 2s)',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: kPopupAccent,
                  ),
                ),
                const Divider(),
                Expanded(
                  child: ScrollableLog(
                    lines: _lines,
                    textColor: kPopupBody,
                    focused: true,
                    ignoreModalGate: true,
                    onKeyEvent: (event) {
                      if (event.logicalKey == LogicalKey.escape) {
                        component.onClose();
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
