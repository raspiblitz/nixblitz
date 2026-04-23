import 'package:nocterm/nocterm.dart';

/// A scrollable log display that auto-scrolls to the bottom when new lines
/// arrive, unless the user has scrolled up manually.
///
/// Handles multi-line entries by splitting on newlines.
/// Intended to be used inside an [Expanded] so it fills remaining vertical
/// space.
/// Signature for per-line color overrides in [ScrollableLog]. Return null
/// to use the widget's default [ScrollableLog.textColor].
typedef LineColorFn = Color? Function(String line);

class ScrollableLog extends StatefulComponent {
  final List<String> lines;
  final Color textColor;

  /// Optional per-line color override (e.g. to color diff +/- lines).
  final LineColorFn? lineColor;

  /// When true, wrap the list in a [Focusable] that handles arrow keys,
  /// j/k, PgUp/PgDn, Home/End for scrolling. Non-scroll keys are handed
  /// to [onKeyEvent] so the parent can react (e.g. `[a] Apply` in the
  /// apply review screen).
  final bool focused;

  /// Called for keys that the scroll handler didn't consume. Only used
  /// when [focused] is true.
  final bool Function(KeyboardEvent event)? onKeyEvent;

  const ScrollableLog({
    super.key,
    required this.lines,
    this.textColor = const Color.fromRGB(180, 180, 200),
    this.lineColor,
    this.focused = false,
    this.onKeyEvent,
  });

  @override
  State<ScrollableLog> createState() => _ScrollableLogState();
}

class _ScrollableLogState extends State<ScrollableLog> {
  final ScrollController _scrollController = ScrollController();
  int _lastCount = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<String> _flatRows() {
    final comp = component;
    final result = <String>[];
    for (final line in comp.lines) {
      if (line.contains('\n')) {
        // Strip a single trailing newline before splitting so "abc\n"
        // becomes ["abc"] instead of ["abc", ""]. Intentional blank lines
        // inside the chunk (e.g., "abc\n\ndef") are preserved.
        final trimmed = line.endsWith('\n')
            ? line.substring(0, line.length - 1)
            : line;
        result.addAll(trimmed.split('\n'));
      } else {
        result.add(line);
      }
    }
    return result;
  }

  @override
  Component build(BuildContext context) {
    final rows = _flatRows();

    // Auto-scroll to bottom when new rows arrive
    if (rows.length != _lastCount) {
      _lastCount = rows.length;
      if (rows.isNotEmpty) {
        _scrollController.ensureVisible(
          itemOffset: (rows.length - 1).toDouble(),
          itemExtent: 1,
        );
      }
    }

    final comp = component;

    if (rows.isEmpty) {
      return const SizedBox();
    }

    final listView = ListView.builder(
      lazy: true,
      itemExtent: 1.0,
      controller: _scrollController,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final line = rows[index];
        final color = comp.lineColor?.call(line) ?? comp.textColor;
        return Text(line, style: TextStyle(color: color));
      },
    );

    if (!comp.focused) return listView;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (_handleScrollKey(event)) return true;
        return comp.onKeyEvent?.call(event) ?? false;
      },
      child: listView,
    );
  }

  bool _handleScrollKey(KeyboardEvent event) {
    final k = event.logicalKey;
    if (k == LogicalKey.arrowUp || k == LogicalKey.keyK) {
      _scrollController.scrollUp();
      return true;
    }
    if (k == LogicalKey.arrowDown || k == LogicalKey.keyJ) {
      _scrollController.scrollDown();
      return true;
    }
    if (k == LogicalKey.pageUp) {
      _scrollController.pageUp();
      return true;
    }
    if (k == LogicalKey.pageDown || k == LogicalKey.space) {
      _scrollController.pageDown();
      return true;
    }
    if (k == LogicalKey.home) {
      _scrollController.scrollToStart();
      return true;
    }
    if (k == LogicalKey.end) {
      _scrollController.scrollToEnd();
      return true;
    }
    return false;
  }
}
