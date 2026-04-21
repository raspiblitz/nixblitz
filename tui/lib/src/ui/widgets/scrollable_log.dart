import 'package:nocterm/nocterm.dart';

/// A scrollable log display that auto-scrolls to the bottom when new lines
/// arrive, unless the user has scrolled up manually.
///
/// Handles multi-line entries by splitting on newlines.
/// Intended to be used inside an [Expanded] so it fills remaining vertical
/// space.
class ScrollableLog extends StatefulComponent {
  final List<String> lines;
  final Color textColor;

  const ScrollableLog({
    super.key,
    required this.lines,
    this.textColor = const Color.fromRGB(180, 180, 200),
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
        result.addAll(line.split('\n'));
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

    return ListView.builder(
      lazy: true,
      itemExtent: 1.0,
      controller: _scrollController,
      itemCount: rows.length,
      itemBuilder: (context, index) => Text(
        rows[index],
        style: TextStyle(color: comp.textColor),
      ),
    );
  }
}
