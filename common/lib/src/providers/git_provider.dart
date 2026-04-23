import 'package:riverpod/riverpod.dart';
import 'package:common/src/services/git_service.dart';
import 'package:common/src/providers/config_provider.dart';

final gitServiceProvider = Provider<GitService>((ref) {
  return GitService(repoDir: ref.watch(baseDirProvider));
});

/// Lines from `git status --porcelain`. Empty when the working tree is clean.
///
/// Re-runs automatically whenever [configProvider] changes (every
/// ConfigNotifier.updateConfig call publishes a new state after writing
/// config.json to disk). For changes that bypass the config notifier —
/// template refreshes, `nix flake update` commits, apply commits, discard
/// `git checkout` — the caller must invalidate this provider explicitly.
final pendingChangesProvider = FutureProvider<List<String>>((ref) async {
  ref.watch(configProvider);
  final git = ref.watch(gitServiceProvider);
  return git.status();
});
