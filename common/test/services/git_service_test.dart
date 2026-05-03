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

      final ok = await service.commitPaths(['wanted.txt'], 'scoped commit');
      expect(ok, true);

      // wanted.txt landed, leftover.txt is still pending.
      final lines = await service.status();
      expect(lines.any((l) => l.contains('wanted.txt')), false);
      expect(lines.any((l) => l.contains('leftover.txt')), true);

      final log = await service.log(count: 1);
      expect(log, contains('scoped commit'));
    });

    test('commitPaths returns false when none of the paths changed', () async {
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

    test(
      'verifyCommit on unsigned HEAD returns status N + empty fields',
      () async {
        // Hermetic env disables `commit.gpgsign`, so the seed commit is
        // unsigned regardless of the developer's `~/.gitconfig`. The
        // status code from `git log --format=%G?` for an unsigned
        // commit is `N`, with the fingerprint / signer fields empty.
        // Production callers (PluginService.install) construct
        // GitService *without* the hermetic env so the operator's real
        // gpg / SSH config is honoured — see
        // common/lib/src/services/git_service.dart `verifyCommit`.
        await service.init();
        await File('${tempDir.path}/x.txt').writeAsString('x');
        await service.commit('x.txt', 'initial');

        final sig = await service.verifyCommit();
        expect(sig.status, 'N');
        expect(sig.fingerprint, isEmpty);
        expect(sig.signer, isEmpty);
        expect(sig.primaryKeyFingerprint, isEmpty);
        expect(sig.isPresent, isFalse);
        expect(sig.isVerified, isFalse);
        expect(sig.isUnknownTrust, isFalse);
      },
    );

    test(
      'verifyCommit on missing ref returns N rather than throwing',
      () async {
        // Empty repo — no HEAD to inspect. verifyCommit must degrade
        // gracefully so refresh-time logic can fall through to the
        // "(unsigned)" path instead of bubbling a process error.
        await service.init();
        final sig = await service.verifyCommit();
        expect(sig.status, 'N');
        expect(sig.fingerprint, isEmpty);
        expect(sig.isPresent, isFalse);
      },
    );

    test('verifyCommit surfaces fingerprint for SSH-signed commit even '
        'when allowed_signers is unconfigured', () async {
      // Regression for the operator-side bug where a freshly-
      // installed NixBlitz user has no `gpg.ssh.allowedSignersFile`
      // and `git log --format=%G?` reports `N` (no signature) for
      // a signed commit — collapsing "signed but trust unknown"
      // and "genuinely unsigned" into the same code. The fix
      // retries with a temp empty allowed_signers so SSH
      // verification gets far enough to emit `U` + the real
      // fingerprint, which is what TOFU pins on.
      final sshKeygen = await Process.run('which', ['ssh-keygen']);
      if (sshKeygen.exitCode != 0) {
        markTestSkipped('ssh-keygen not on PATH');
        return;
      }

      // Generate an ed25519 keypair scoped to this test.
      final keyPath = '${tempDir.path}/signing_key';
      final gen = await Process.run('ssh-keygen', [
        '-t',
        'ed25519',
        '-N',
        '',
        '-C',
        'nixblitz-test',
        '-f',
        keyPath,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      // Construct a non-hermetic GitService whose env has no
      // global / system gitconfig and no allowed_signers — i.e.
      // the operator's first-install state. We still need
      // user.email / user.name + a per-repo signing config, so
      // wire those via `extraConfigArgs` rather than via files.
      final isolatedEnv = {
        'PATH': Platform.environment['PATH'] ?? '',
        'HOME': tempDir.path,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_AUTHOR_NAME': 'Test',
        'GIT_AUTHOR_EMAIL': 'test@example.invalid',
        'GIT_COMMITTER_NAME': 'Test',
        'GIT_COMMITTER_EMAIL': 'test@example.invalid',
      };
      final signingConfig = [
        '-c',
        'gpg.format=ssh',
        '-c',
        'user.signingkey=$keyPath',
        '-c',
        'commit.gpgsign=true',
      ];
      final signing = GitService(
        repoDir: tempDir.path,
        environment: isolatedEnv,
        extraConfigArgs: signingConfig,
      );

      await signing.init();
      await File('${tempDir.path}/x.txt').writeAsString('hello');
      final ok = await signing.commit('x.txt', 'signed commit');
      expect(ok, isTrue, reason: 'signed commit should succeed');

      // Sanity: the commit object actually carries an SSH
      // signature header. If this fails the test setup is the
      // problem, not verifyCommit.
      final cat = await Process.run(
        'git',
        ['cat-file', '-p', 'HEAD'],
        workingDirectory: tempDir.path,
        environment: isolatedEnv,
      );
      expect(cat.stdout as String, contains('BEGIN SSH SIGNATURE'));

      // Fingerprint git would report given the public key.
      final fpProbe = await Process.run('ssh-keygen', [
        '-l',
        '-f',
        '$keyPath.pub',
      ]);
      expect(fpProbe.exitCode, 0);
      final expectedFp = (fpProbe.stdout as String)
          .split(' ')
          .firstWhere((p) => p.startsWith('SHA256:'));

      // The actual assertion: verifyCommit on this repo with no
      // allowed_signers must surface status `U` and the right
      // fingerprint. Pre-fix this was `N` + empty.
      final verify = GitService(
        repoDir: tempDir.path,
        environment: isolatedEnv,
      );
      final sig = await verify.verifyCommit();
      expect(
        sig.fingerprint,
        expectedFp,
        reason: 'fallback should surface the SSH key fingerprint',
      );
      expect(
        sig.status,
        'U',
        reason: 'good signature, no allowed_signers → unknown trust',
      );
      expect(sig.isPresent, isTrue);
      expect(sig.isVerified, isFalse);
      expect(sig.isUnknownTrust, isTrue);
    });

    test(
      'headCommitTime returns null on a virgin repo, then a DateTime',
      () async {
        await service.init();
        expect(await service.headCommitTime(), isNull);

        final before = DateTime.now().toUtc();
        await File('${tempDir.path}/x.txt').writeAsString('x');
        await service.commit('x.txt', 'first');
        final after = DateTime.now().toUtc();

        final t = await service.headCommitTime();
        expect(t, isNotNull);
        expect(t!.isUtc, isTrue);
        // git's commit timestamp has 1s resolution; allow a 2s slop on
        // each side to absorb clock skew between the test process and
        // git's view of "now".
        expect(
          t.isAfter(before.subtract(const Duration(seconds: 2))),
          isTrue,
          reason: 'commit time $t should be at/after $before',
        );
        expect(
          t.isBefore(after.add(const Duration(seconds: 2))),
          isTrue,
          reason: 'commit time $t should be at/before $after',
        );
      },
    );

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

    group('readCommittedFile', () {
      test(
        'returns committed content even when working tree is dirty',
        () async {
          // Mirrors the per-key-pending diff use case: operator
          // edited the file in memory (we model that as a working-
          // tree edit) and we need HEAD's view, NOT the dirty
          // working copy.
          await service.init();
          final file = File('${tempDir.path}/config.json');
          await file.writeAsString('{"v": 1}');
          await service.commit('config.json', 'initial');

          // Now dirty the working tree without committing.
          await file.writeAsString('{"v": 999}');

          final committed = await service.readCommittedFile('config.json');
          expect(committed, '{"v": 1}');
        },
      );

      test('returns null when the path is not present at HEAD', () async {
        // File added in the working tree but never committed —
        // git show HEAD:<path> exits non-zero.
        await service.init();
        await File('${tempDir.path}/seed.txt').writeAsString('seed');
        await service.commit('seed.txt', 'seed');

        // Different file, never committed.
        await File('${tempDir.path}/never_committed.txt').writeAsString('hi');

        final res = await service.readCommittedFile('never_committed.txt');
        expect(res, isNull);
      });

      test('returns null on an empty repo with no HEAD', () async {
        // Fresh-install case: repo initialised, no commits yet.
        // git show HEAD:<anything> exits non-zero. Caller treats
        // null as "no baseline" and surfaces an empty key set.
        await service.init();
        final res = await service.readCommittedFile('config.json');
        expect(res, isNull);
      });
    });
  });
}
