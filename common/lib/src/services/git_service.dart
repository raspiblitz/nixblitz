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
}
