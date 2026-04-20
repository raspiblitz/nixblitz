// common/test/services/git_service_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:common/src/services/git_service.dart';

void main() {
  group('GitService', () {
    late Directory tempDir;
    late GitService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_git_test_');
      service = GitService(repoDir: tempDir.path);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('init creates a git repository', () async {
      final result = await service.init();
      expect(result, true);
      final gitDir = Directory('${tempDir.path}/.git');
      expect(gitDir.existsSync(), true);
    });

    test('commit stages and commits a file', () async {
      await service.init();
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('hello');
      final result = await service.commit('test.txt', 'initial commit');
      expect(result, true);
      final log = await service.log(count: 1);
      expect(log, contains('initial commit'));
    });

    test('revertLast reverts the most recent commit', () async {
      await service.init();
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('version 1');
      await service.commit('test.txt', 'first');
      await file.writeAsString('version 2');
      await service.commit('test.txt', 'second');
      await service.revertLast();
      final content = await file.readAsString();
      expect(content, 'version 1');
    });
  });
}
