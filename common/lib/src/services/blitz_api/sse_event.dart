/// Minimal text/event-stream parser.
///
/// W3C Server-Sent Events frames are delimited by a blank line. Each
/// field is `name: value` on its own line; `data:` lines accumulate
/// separated by `\n`. Comment lines start with `:` and are ignored.
///
/// This implementation only cares about `event:` and `data:` — enough
/// for blitz-api's broadcast shape, where the payload is a JSON blob
/// on a single `data:` line.
library;

class SseEvent {
  final String event; // "" if unspecified (default per spec: "message")
  final String data;

  const SseEvent({required this.event, required this.data});

  @override
  String toString() => 'SseEvent(event=$event, data=${data.length} bytes)';
}

/// Transforms a stream of UTF-8 decoded chunks into a stream of
/// complete [SseEvent]s. Handles partial chunks and line splits
/// across chunk boundaries.
Stream<SseEvent> parseSseStream(Stream<String> chunks) async* {
  final buf = StringBuffer();

  String event = '';
  final data = StringBuffer();

  void reset() {
    event = '';
    data.clear();
  }

  SseEvent? flushIfReady() {
    if (data.isEmpty && event.isEmpty) return null;
    final ev = SseEvent(event: event, data: data.toString());
    reset();
    return ev;
  }

  await for (final chunk in chunks) {
    buf.write(chunk);
    final text = buf.toString();

    // Extract all complete lines; keep the trailing partial in `buf`.
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\n') {
        var line = text.substring(start, i);
        // Strip a trailing \r for CRLF streams.
        if (line.isNotEmpty && line[line.length - 1] == '\r') {
          line = line.substring(0, line.length - 1);
        }
        start = i + 1;

        if (line.isEmpty) {
          final ev = flushIfReady();
          if (ev != null) yield ev;
          continue;
        }
        if (line.startsWith(':')) continue; // comment

        final colon = line.indexOf(':');
        if (colon == -1) continue;
        final field = line.substring(0, colon);
        // A single leading space after the colon is stripped per spec.
        var value = line.substring(colon + 1);
        if (value.startsWith(' ')) value = value.substring(1);

        switch (field) {
          case 'event':
            event = value;
          case 'data':
            if (data.isNotEmpty) data.write('\n');
            data.write(value);
          // Ignore other fields (id, retry) — we don't use them.
        }
      }
    }

    // Anything left after the last \n is a partial line for next time.
    final leftover = text.substring(start);
    buf.clear();
    buf.write(leftover);
  }
}
