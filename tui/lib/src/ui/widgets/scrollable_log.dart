import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/ui_state_provider.dart';

/// A scrollable log display that auto-scrolls to the bottom when new lines
/// arrive, unless the user has scrolled up manually.
///
/// Handles multi-line entries by splitting on newlines.
/// Intended to be used inside an [Expanded] so it fills remaining vertical
/// space.
///
/// When [focused] is true, the widget also handles vim-style search:
///
/// - `/` opens a one-line compose buffer at the bottom of the log.
/// - Typing while composing builds up the query; `Backspace` trims it.
/// - `Enter` commits — the first match at-or-below the current scroll
///   position is brought into view and matches are highlighted inline.
/// - `n` / `Shift+N` cycle through matches (wrap-around).
/// - `Esc` clears the search and the compose buffer.
///
/// Search is intentionally case-insensitive and substring-only; `ScrollableLog`
/// is for human-readable logs, not regex grep.
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

  // Search state. `_query` is the committed term used for both
  // highlighting and n/N navigation. `_input` is the buffer the user
  // is currently typing between `/` and Enter; only `_input` is shown
  // while [_composing] is true. The two stay separate so canceling a
  // half-typed search (Esc) doesn't drop the previously committed
  // query.
  String _query = '';
  String _input = '';
  bool _composing = false;

  // Cached match list — row indices in the flattened-rows view. Rebuilt
  // when the query or the rows change. Kept at this granularity (one
  // entry per matching row, not per match) so n/N skip line-by-line —
  // matches the mental model of "next hit" in a log.
  List<int> _matchRows = const [];
  int _matchIndex = 0;
  String _lastIndexedQuery = '';
  int _lastIndexedRowCount = -1;

  // Tracks the vim `gg` chord: a single `g` arms this; the
  // following `g` jumps to the top; any other key disarms it.
  // No timeout (vim itself doesn't have one — you can think
  // between keys).
  bool _pendingG = false;

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

  /// Rebuild [_matchRows] when either the query or the underlying log
  /// has changed since the last index. Case-insensitive substring scan.
  void _reindexIfNeeded(List<String> rows) {
    if (_query == _lastIndexedQuery && rows.length == _lastIndexedRowCount) {
      return;
    }
    _lastIndexedQuery = _query;
    _lastIndexedRowCount = rows.length;
    if (_query.isEmpty) {
      _matchRows = const [];
      _matchIndex = 0;
      return;
    }
    final needle = _query.toLowerCase();
    final hits = <int>[];
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].toLowerCase().contains(needle)) hits.add(i);
    }
    _matchRows = hits;
    if (_matchIndex >= _matchRows.length) {
      _matchIndex = _matchRows.isEmpty ? 0 : _matchRows.length - 1;
    }
  }

  /// Lines of context to keep visible past the match in the scroll
  /// direction. Without this, ensureVisible parks the match flush
  /// against the top or bottom edge of the viewport, hiding what
  /// comes next — usually the most useful follow-up text. Treat the
  /// match as a `1 + 2*context` line "virtual item" so ensureVisible
  /// pads both sides.
  static const int _contextLines = 3;

  void _scrollToMatch(int index) {
    if (_matchRows.isEmpty) return;
    _matchIndex = index % _matchRows.length;
    if (_matchIndex < 0) _matchIndex += _matchRows.length;
    final row = _matchRows[_matchIndex];
    _scrollController.ensureVisible(
      itemOffset: (row - _contextLines).toDouble(),
      itemExtent: (1 + 2 * _contextLines).toDouble(),
    );
  }

  /// On Enter, jump to the first match at or below where the user is
  /// currently looking, not the very top — closer to vim's behaviour
  /// of searching forward from the cursor.
  void _commitSearch(int rowsLength) {
    setState(() {
      _query = _input;
      _composing = false;
    });
    if (_query.isEmpty || _matchRows.isEmpty) {
      // Re-index on next build catches an empty/no-results query;
      // nothing to scroll to.
      return;
    }
    final firstVisible = _scrollController.offset;
    final fwd = _matchRows.indexWhere((r) => r >= firstVisible.floor());
    _scrollToMatch(fwd >= 0 ? fwd : 0);
  }

  @override
  Component build(BuildContext context) {
    final rows = _flatRows();
    _reindexIfNeeded(rows);

    // Auto-scroll to bottom when new rows arrive. Suppressed while
    // there's an active search so n/N navigation doesn't get yanked
    // off the user's match by a tail update.
    if (rows.length != _lastCount) {
      _lastCount = rows.length;
      if (rows.isNotEmpty && _query.isEmpty && !_composing) {
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

    // Two styles so n/N navigation has a visible cursor: every match
    // gets the muted yellow, the *current* match (the row at
    // _matchIndex) gets a brighter orange so the eye lands on it
    // without consulting the [m/n] counter.
    const inactiveHighlight = TextStyle(
      color: Color.fromRGB(20, 20, 20),
      backgroundColor: Color.fromRGB(220, 200, 80),
    );
    const activeHighlight = TextStyle(
      color: Color.fromRGB(20, 20, 20),
      backgroundColor: Color.fromRGB(247, 147, 26),
      fontWeight: FontWeight.bold,
    );
    final activeRow = _matchRows.isEmpty ? -1 : _matchRows[_matchIndex];

    final listView = ListView.builder(
      lazy: true,
      itemExtent: 1.0,
      controller: _scrollController,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final line = rows[index];
        final color = comp.lineColor?.call(line) ?? comp.textColor;
        final baseStyle = TextStyle(color: color);
        if (_query.isEmpty) {
          return Text(line, style: baseStyle);
        }
        final hl = index == activeRow ? activeHighlight : inactiveHighlight;
        return _highlightedRow(line, baseStyle, hl);
      },
    );

    if (!comp.focused) return listView;

    // Yield focus while a modal popup (sudo prompt / help) is up —
    // the streaming-output panes that wrap us during nixos-rebuild
    // would otherwise eat the keystrokes meant for the password
    // input.
    final modalActive = context.watch(modalActiveProvider);

    final showStatus = _composing || _query.isNotEmpty;

    return Focusable(
      focused: !modalActive,
      onKeyEvent: (event) {
        if (_handleSearchKey(event, rows.length)) return true;
        if (_handleScrollKey(event)) return true;
        return comp.onKeyEvent?.call(event) ?? false;
      },
      child: MouseRegion(
        // Mouse wheel: scroll one row per click. Phone-over-SSH
        // clients that emit wheel events for two-finger scroll get
        // the same surface — feels native compared to holding `j`.
        // onHover fires for every event under the cursor including
        // wheel button events; filter on button type.
        onHover: (event) {
          if (event.button == MouseButton.wheelUp) {
            _scrollController.scrollUp();
          } else if (event.button == MouseButton.wheelDown) {
            _scrollController.scrollDown();
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: listView),
            if (showStatus) _statusBar(),
          ],
        ),
      ),
    );
  }

  /// Render a row that contains the active query as a Row of Text
  /// segments: surrounding text in [base] style, matched substrings in
  /// the highlight style. Case-insensitive matching, but the original
  /// casing of the line is preserved in the rendered output.
  Component _highlightedRow(String line, TextStyle base, TextStyle highlight) {
    final needle = _query.toLowerCase();
    final hay = line.toLowerCase();
    final segments = <Component>[];
    var cursor = 0;
    while (cursor < line.length) {
      final hit = hay.indexOf(needle, cursor);
      if (hit < 0) {
        segments.add(Text(line.substring(cursor), style: base));
        break;
      }
      if (hit > cursor) {
        segments.add(Text(line.substring(cursor, hit), style: base));
      }
      segments.add(
        Text(line.substring(hit, hit + needle.length), style: highlight),
      );
      cursor = hit + needle.length;
    }
    if (segments.isEmpty) {
      return Text(line, style: base);
    }
    return Row(children: segments);
  }

  Component _statusBar() {
    final dim = const TextStyle(color: Color.fromRGB(140, 140, 160));
    final hi = const TextStyle(color: Color.fromRGB(220, 200, 80));
    if (_composing) {
      // Trailing block char acts as a cursor; cheap and works without
      // a real text-field widget. Widening to a full TextField would be
      // overkill for a single-line search.
      return Row(
        children: [
          Text('/', style: hi),
          Text('$_input█', style: dim),
        ],
      );
    }
    final pos = _matchRows.isEmpty
        ? '0/0'
        : '${_matchIndex + 1}/${_matchRows.length}';
    return Row(
      children: [
        Text('[$pos] ', style: dim),
        Text('/$_query', style: hi),
        Text('   n=next  N=prev  Esc=clear', style: dim),
      ],
    );
  }

  /// Returns true if the event was consumed by the search machinery.
  /// Search keys take precedence over scroll keys so that, for example,
  /// `j` in compose mode types a `j` rather than scrolling down.
  bool _handleSearchKey(KeyboardEvent event, int rowsLength) {
    final k = event.logicalKey;

    if (_composing) {
      if (k == LogicalKey.escape) {
        setState(() {
          _composing = false;
          _input = '';
        });
        return true;
      }
      if (k == LogicalKey.enter) {
        _commitSearch(rowsLength);
        return true;
      }
      if (k == LogicalKey.backspace) {
        if (_input.isNotEmpty) {
          setState(() {
            _input = _input.substring(0, _input.length - 1);
          });
        }
        return true;
      }
      // Treat anything else with a printable character as input.
      // Newline / tab characters slip in here as character != null;
      // exclude them so the buffer can't grow weird whitespace.
      final ch = event.character;
      if (ch != null && ch.length == 1 && ch.codeUnitAt(0) >= 0x20) {
        setState(() {
          _input = _input + ch;
        });
        return true;
      }
      // Swallow everything else so scroll keys don't fire mid-compose.
      return true;
    }

    // Not composing — only the few search-control keys are interesting.
    if (k == LogicalKey.slash) {
      setState(() {
        _composing = true;
        _input = _query; // pre-fill so editing a recent search is cheap
      });
      return true;
    }
    if (_query.isNotEmpty && _matchRows.isNotEmpty) {
      // n / Shift+N. Match on `character` rather than logicalKey + shift
      // so we don't have to worry about how the terminal reports the
      // shift state for these keys.
      if (event.character == 'n') {
        setState(() => _scrollToMatch(_matchIndex + 1));
        return true;
      }
      if (event.character == 'N') {
        setState(() => _scrollToMatch(_matchIndex - 1));
        return true;
      }
    }
    if (k == LogicalKey.escape && (_query.isNotEmpty || _composing)) {
      setState(() {
        _query = '';
        _input = '';
        _matchRows = const [];
        _matchIndex = 0;
      });
      return true;
    }
    return false;
  }

  bool _handleScrollKey(KeyboardEvent event) {
    final k = event.logicalKey;

    // Vim `gg` chord: first lower-case g arms `_pendingG`,
    // second jumps to the top. Capital `G` is independent —
    // single keypress to jump to the bottom. Both checks live
    // before the j/k/PgUp/PgDn block so they win on plain `g`
    // / `G` (and a stale `_pendingG` gets cleared by anything
    // else that falls through this handler).
    if (event.character == 'g') {
      if (_pendingG) {
        _pendingG = false;
        _scrollController.scrollToStart();
      } else {
        _pendingG = true;
      }
      return true;
    }
    if (event.character == 'G') {
      _pendingG = false;
      _scrollController.scrollToEnd();
      return true;
    }
    // Anything that isn't `g` disarms the pending state.
    _pendingG = false;

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
