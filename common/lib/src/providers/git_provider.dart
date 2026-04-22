import 'package:riverpod/riverpod.dart';
import 'package:common/src/services/git_service.dart';
import 'package:common/src/providers/config_provider.dart';

final gitServiceProvider = Provider<GitService>((ref) {
  return GitService(repoDir: ref.watch(baseDirProvider));
});

/// Lines from `git status --porcelain`. Empty when the working tree is clean.
/// Invalidate this provider after any apply/discard to force a re-check.
final pendingChangesProvider = FutureProvider<List<String>>((ref) async {
  final git = ref.watch(gitServiceProvider);
  return git.status();
});
