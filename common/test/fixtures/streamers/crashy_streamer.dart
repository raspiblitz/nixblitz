// Emits one event then exits with code 1 — exercises restart logic.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  stdout.writeln(
    jsonEncode({
      'tile': 'fix',
      'data': {'attempt': int.parse(Platform.environment['ATTEMPT'] ?? '0')},
      'ts': DateTime.now().millisecondsSinceEpoch,
    }),
  );
  await Future.delayed(const Duration(milliseconds: 20));
  exit(1);
}
