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

  group('runChecked (async)', () {
    test('returns ok with captured stdout on success', () async {
      final r = await runChecked('printf', ['hello']);
      expect(r.ok, true);
      expect(r.stdout, 'hello');
    });

    test(
      'returns the non-zero exit code without throwing by default',
      () async {
        final r = await runChecked('false', const []);
        expect(r.ok, false);
        expect(r.exitCode, isNonZero);
      },
    );

    test('throws a ProcessException on failure when throwOnError is set', () {
      expect(
        runChecked('false', const [], throwOnError: true),
        throwsA(isA<ProcessException>()),
      );
    });
  });

  group('writeExecutableScriptSync', () {
    test('writes the content and marks the file executable', () {
      final dir = Directory.systemTemp.createTempSync('nixblitz_pr_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/script.sh';

      writeExecutableScriptSync(path, '#!/bin/sh\necho hi\n');

      expect(File(path).readAsStringSync(), '#!/bin/sh\necho hi\n');
      // Owner-executable bit set (mode & 0o100).
      final mode = File(path).statSync().mode;
      expect(mode & 0x40, isNonZero, reason: 'owner exec bit should be set');
    });
  });
}
