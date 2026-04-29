import 'dart:io';

import 'package:common/src/services/git_service.dart';

/// Hermetic environment for child `git` processes spawned from
/// tests. Drops the developer's `~/.gitconfig`, system gitconfig,
/// and ssh-agent state so the test harness behaves the same on
/// every machine.
///
/// Why each var matters:
/// - `GIT_TERMINAL_PROMPT=0` — never block on a tty for credentials.
/// - `GIT_CONFIG_NOSYSTEM=1` — ignore `/etc/gitconfig`.
/// - `GIT_CONFIG_GLOBAL=/dev/null` — ignore `~/.gitconfig`. Notably
///   bypasses commit-signing config (`gpg.format=ssh`,
///   `commit.gpgsign=true`) that otherwise spawns `ssh-askpass`
///   when the agent doesn't hold the signing key.
/// - `GIT_AUTHOR_*` / `GIT_COMMITTER_*` — make commits succeed
///   without relying on a user.email / user.name being set.
const Map<String, String> hermeticGitEnv = {
  'GIT_TERMINAL_PROMPT': '0',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_GLOBAL': '/dev/null',
  'GIT_AUTHOR_NAME': 'Test',
  'GIT_AUTHOR_EMAIL': 'test@example.invalid',
  'GIT_COMMITTER_NAME': 'Test',
  'GIT_COMMITTER_EMAIL': 'test@example.invalid',
};

/// `-c key=value` pairs applied before every subcommand. Belt to
/// the env's suspenders — even if some config slips through (e.g.
/// a per-repo `.git/config` we didn't write), these flags keep
/// signing and other surprises off.
const List<String> hermeticGitConfigArgs = [
  '-c',
  'commit.gpgsign=false',
  '-c',
  'tag.gpgsign=false',
];

/// Construct a GitService wired for tests: hermetic env + the
/// `-c` overrides above. Use this anywhere a test would otherwise
/// instantiate `GitService(repoDir: …)` directly.
GitService hermeticGitService(String repoDir) => GitService(
  repoDir: repoDir,
  environment: hermeticGitEnv,
  extraConfigArgs: hermeticGitConfigArgs,
);

/// Direct `git` invocation for tests that don't go through
/// GitService — typically fixture-setup helpers seeding a "remote"
/// repo before a clone test.
Future<ProcessResult> testGit(
  List<String> args, {
  required String workingDirectory,
}) => Process.run(
  'git',
  [...hermeticGitConfigArgs, ...args],
  workingDirectory: workingDirectory,
  environment: hermeticGitEnv,
);
