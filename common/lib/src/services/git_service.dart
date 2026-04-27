// common/lib/src/services/git_service.dart
import 'dart:io';

class GitService {
  GitService({
    required this.repoDir,
    this.environment,
    this.extraConfigArgs = const [],
  });

  final String repoDir;

  /// Optional environment overrides for every spawned `git` process.
  /// Merged into the parent environment (Dart's
  /// `Process.run(includeParentEnvironment: true)` is the default).
  /// Production callers leave this null; tests pass a hermetic map
  /// so the user's `~/.gitconfig`, ssh-agent state, and
  /// askpass setup don't leak into the test harness — see
  /// `common/test/test_helpers/git_isolation.dart`.
  final Map<String, String>? environment;

  /// `-c key=value` pairs prepended before every git subcommand.
  /// Same purpose as [environment]: lets tests force
  /// `commit.gpgsign=false`, etc., without touching production
  /// behaviour at user-Apply time.
  final List<String> extraConfigArgs;

  /// Prepend the per-instance `-c` overrides to a subcommand argv.
  List<String> _g(List<String> args) => [...extraConfigArgs, ...args];

  Future<bool> init() async {
    final result = await Process.run(
      'git', _g(['init']),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (result.exitCode != 0) return false;
    await Process.run(
      'git', _g(['config', 'user.email', 'nixblitz@localhost']),
      workingDirectory: repoDir,
      environment: environment,
    );
    await Process.run(
      'git', _g(['config', 'user.name', 'NixBlitz']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return true;
  }

  Future<bool> commit(String filePath, String message) async {
    final add = await Process.run(
      'git', _g(['add', filePath]),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (add.exitCode != 0) return false;
    final commit = await Process.run(
      'git', _g(['commit', '-m', message]),
      workingDirectory: repoDir,
      environment: environment,
    );
    return commit.exitCode == 0;
  }

  Future<bool> revertLast() async {
    final result = await Process.run(
      'git', _g(['revert', '--no-edit', 'HEAD']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.exitCode == 0;
  }

  Future<String> log({int count = 10}) async {
    final result = await Process.run(
      'git', _g(['log', '--oneline', '-$count']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.stdout as String;
  }

  /// Diff the working tree against HEAD (tracked files only). Pass a path to
  /// restrict the diff. Always returns uncolored text suitable for rendering
  /// in a plain [ScrollableLog].
  Future<String> diff({String? path}) async {
    final args = ['diff', '--no-color', ?path];
    final result = await Process.run(
      'git', _g(args),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.stdout as String;
  }

  /// List of `XY path` lines from `git status --porcelain`. Each line
  /// describes one tracked or untracked file that differs from HEAD.
  Future<List<String>> status() async {
    final result = await Process.run(
      'git',
      _g(['status', '--porcelain']),
      workingDirectory: repoDir,
      environment: environment,
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
      _g(['add', '-A']),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (add.exitCode != 0) return false;
    final commit = await Process.run(
      'git',
      _g(['commit', '-m', message]),
      workingDirectory: repoDir,
      environment: environment,
    );
    return commit.exitCode == 0;
  }

  /// Revert the working tree to match HEAD, wiping any uncommitted changes.
  /// Untracked files are left in place.
  Future<bool> discardAll() async {
    final result = await Process.run(
      'git',
      _g(['checkout', '--', '.']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.exitCode == 0;
  }
}
