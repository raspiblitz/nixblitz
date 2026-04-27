// common/test/services/git_service_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:common/src/services/git_service.dart';

import '../test_helpers/git_isolation.dart';

void main() {
  group('GitService', () {
    late Directory tempDir;
    late GitService service;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nixblitz_git_test_');
      // Hermetic GitService: ignores the developer's ~/.gitconfig,
      // disables commit signing, and avoids askpass spawns. See
      // ../test_helpers/git_isolation.dart for the env + -c shape.
      service = hermeticGitService(tempDir.path);
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

    test('status returns empty for a clean tree', () async {
      await service.init();
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('hello');
      await service.commit('test.txt', 'initial');
      final lines = await service.status();
      expect(lines, isEmpty);
    });

    test('status lists dirty and untracked files', () async {
      await service.init();
      final tracked = File('${tempDir.path}/tracked.txt');
      await tracked.writeAsString('original');
      await service.commit('tracked.txt', 'initial');

      await tracked.writeAsString('modified');
      await File('${tempDir.path}/new.txt').writeAsString('fresh');

      final lines = await service.status();
      expect(lines, hasLength(2));
      expect(lines.any((l) => l.contains('tracked.txt')), true);
      expect(lines.any((l) => l.contains('new.txt')), true);
    });

    test('diff shows working-tree changes against HEAD', () async {
      await service.init();
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('line one\n');
      await service.commit('test.txt', 'initial');

      await file.writeAsString('line one\nline two\n');
      final diff = await service.diff();
      expect(diff, contains('+line two'));
    });

    test('commitAll stages new and modified files and commits them', () async {
      await service.init();
      final tracked = File('${tempDir.path}/tracked.txt');
      await tracked.writeAsString('v1');
      await service.commit('tracked.txt', 'initial');

      await tracked.writeAsString('v2');
      await File('${tempDir.path}/new.txt').writeAsString('fresh');

      final result = await service.commitAll('batch apply');
      expect(result, true);
      final log = await service.log(count: 1);
      expect(log, contains('batch apply'));
      final lines = await service.status();
      expect(lines, isEmpty);
    });

    test('commitAll returns false when nothing has changed', () async {
      await service.init();
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('stable');
      await service.commit('test.txt', 'initial');

      final result = await service.commitAll('nothing');
      expect(result, false);
    });

    test('discardAll restores tracked files to HEAD', () async {
      await service.init();
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('original');
      await service.commit('test.txt', 'initial');

      await file.writeAsString('tampered');
      final result = await service.discardAll();
      expect(result, true);
      final content = await file.readAsString();
      expect(content, 'original');
    });

    test('commitPaths only stages the listed paths', () async {
      await service.init();
      // Initial commit so HEAD exists.
      await File('${tempDir.path}/seed.txt').writeAsString('seed');
      await service.commit('seed.txt', 'seed');

      // Two unrelated changes; only one should land in the commit.
      await File('${tempDir.path}/wanted.txt').writeAsString('keep me');
      await File('${tempDir.path}/leftover.txt').writeAsString('skip me');

      final ok =
          await service.commitPaths(['wanted.txt'], 'scoped commit');
      expect(ok, true);

      // wanted.txt landed, leftover.txt is still pending.
      final lines = await service.status();
      expect(lines.any((l) => l.contains('wanted.txt')), false);
      expect(lines.any((l) => l.contains('leftover.txt')), true);

      final log = await service.log(count: 1);
      expect(log, contains('scoped commit'));
    });

    test('commitPaths returns false when none of the paths changed',
        () async {
      await service.init();
      await File('${tempDir.path}/seed.txt').writeAsString('seed');
      await service.commit('seed.txt', 'seed');

      final ok = await service.commitPaths(['seed.txt'], 'no-op');
      expect(ok, false);
    });

    test('commitPaths returns false on empty path list', () async {
      await service.init();
      final ok = await service.commitPaths(const [], 'whatever');
      expect(ok, false);
    });

    test('headRef returns null on a virgin repo, then a SHA', () async {
      await service.init();
      // No commits yet.
      expect(await service.headRef(), isNull);

      await File('${tempDir.path}/x.txt').writeAsString('x');
      await service.commit('x.txt', 'first');

      final h1 = await service.headRef();
      expect(h1, isNotNull);
      expect(h1!.length, 40); // git's full SHA-1

      await File('${tempDir.path}/x.txt').writeAsString('x2');
      await service.commit('x.txt', 'second');

      final h2 = await service.headRef();
      expect(h2, isNotNull);
      expect(h2, isNot(h1)); // moved
    });
  });
}
