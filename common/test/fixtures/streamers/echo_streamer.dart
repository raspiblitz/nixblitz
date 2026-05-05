// Emits a fixed sequence of JSON-line events then exits cleanly.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  for (var i = 0; i < 3; i++) {
    stdout.writeln(
      jsonEncode({
        'tile': 'fix',
        'data': {'n': i},
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    await Future.delayed(const Duration(milliseconds: 20));
  }
  // One malformed line to exercise the parser's drop path.
  stdout.writeln('this is not json');
  exit(0);
}
