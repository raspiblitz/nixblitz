// common/lib/src/services/git_service.dart
import 'dart:io';

class GitService {
  final String repoDir;

  GitService({required this.repoDir});

  Future<bool> init() async {
    final result = await Process.run('git', ['init'], workingDirectory: repoDir);
    if (result.exitCode != 0) return false;
    await Process.run('git', ['config', 'user.email', 'nixblitz@localhost'], workingDirectory: repoDir);
    await Process.run('git', ['config', 'user.name', 'NixBlitz'], workingDirectory: repoDir);
    return true;
  }

  Future<bool> commit(String filePath, String message) async {
    final add = await Process.run('git', ['add', filePath], workingDirectory: repoDir);
    if (add.exitCode != 0) return false;
    final commit = await Process.run('git', ['commit', '-m', message], workingDirectory: repoDir);
    return commit.exitCode == 0;
  }

  Future<bool> revertLast() async {
    final result = await Process.run('git', ['revert', '--no-edit', 'HEAD'], workingDirectory: repoDir);
    return result.exitCode == 0;
  }

  Future<String> log({int count = 10}) async {
    final result = await Process.run('git', ['log', '--oneline', '-$count'], workingDirectory: repoDir);
    return result.stdout as String;
  }

  /// Diff the working tree against HEAD (tracked files only). Pass a path to
  /// restrict the diff. Always returns uncolored text suitable for rendering
  /// in a plain [ScrollableLog].
  Future<String> diff({String? path}) async {
    final args = ['diff', '--no-color', ?path];
    final result = await Process.run('git', args, workingDirectory: repoDir);
    return result.stdout as String;
  }

  /// List of `XY path` lines from `git status --porcelain`. Each line
  /// describes one tracked or untracked file that differs from HEAD.
  Future<List<String>> status() async {
    final result = await Process.run(
      'git',
      ['status', '--porcelain'],
      workingDirectory: repoDir,
    );
    if (result.exitCode != 0) return const [];
    return (result.stdout as String)
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Stage every change (tracked or untracked) and commit with [message].
  /// Returns true only if the commit was created; `git add` failing or
  /// nothing-to-commit both yield false.
  Future<bool> commitAll(String message) async {
    final add = await Process.run(
      'git',
      ['add', '-A'],
      workingDirectory: repoDir,
    );
    if (add.exitCode != 0) return false;
    final commit = await Process.run(
      'git',
      ['commit', '-m', message],
      workingDirectory: repoDir,
    );
    return commit.exitCode == 0;
  }

  /// Revert the working tree to match HEAD, wiping any uncommitted changes.
  /// Untracked files are left in place.
  Future<bool> discardAll() async {
    final result = await Process.run(
      'git',
      ['checkout', '--', '.'],
      workingDirectory: repoDir,
    );
    return result.exitCode == 0;
  }
}
