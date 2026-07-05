@TestOn('linux')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:common/src/services/process_runner.dart';

void main() {
  group('runCheckedSync', () {
    test('returns ok with captured stdout on success', () {
      final r = runCheckedSync('printf', ['hello']);
      expect(r.ok, true);
      expect(r.exitCode, 0);
      expect(r.stdout, 'hello');
    });

    test('returns the non-zero exit code without throwing by default', () {
      final r = runCheckedSync('false', const []);
      expect(r.ok, false);
      expect(r.exitCode, isNonZero);
    });

    test('throws a ProcessException on failure when throwOnError is set', () {
      expect(
        () => runCheckedSync('false', const [], throwOnError: true),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
