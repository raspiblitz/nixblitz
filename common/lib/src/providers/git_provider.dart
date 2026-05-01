import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/services/git_service.dart';
import 'package:common/src/services/log_service.dart';
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

/// HEAD's view of `~/nixblitz/config.json`, parsed as
/// [NixblitzConfig]. Null in three cases — all of them mean
/// "no useful baseline, treat the working tree as in-sync":
///
/// - Repo has no HEAD commit yet (first launch on a fresh
///   install before the wizard's first Apply).
/// - `config.json` doesn't exist at HEAD (added in working
///   tree, never committed).
/// - HEAD content fails to parse (corrupt history; logged and
///   swallowed so the dashboard doesn't trip on a broken
///   provider chain).
///
/// Deliberately does NOT watch [configProvider]. Operator
/// keystrokes / text-edit commits write `config.json` to disk
/// but don't change HEAD — re-running `git show HEAD:config.json`
/// for every keystroke would just return the same content and
/// trigger a useless [pendingChangeKeysProvider] re-evaluation,
/// which used to flicker the per-row `*` markers and the header
/// status off-then-on as the FutureProvider transitioned
/// through `AsyncLoading`.
///
/// Re-evaluation happens only via explicit `ref.invalidate(...)`
/// at the three commit / revert sites that mutate HEAD:
/// `apply_view._leave`, the update-view post-rebuild path,
/// and `plugin_config_provider.update`.
final committedConfigProvider = FutureProvider<NixblitzConfig?>((ref) async {
  final git = ref.watch(gitServiceProvider);
  try {
    final raw = await git.readCommittedFile('config.json');
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return NixblitzConfig.fromJson(json);
  } catch (e, st) {
    LogService.warn('committedConfigProvider: parse failed: $e');
    LogService.error('committedConfigProvider trace', e, st);
    return null;
  }
});

/// Set of dotted-path config keys whose live value differs from
/// HEAD's. Empty when no useful baseline (see
/// [committedConfigProvider]) or when nothing's pending. Drives:
///
/// - Per-row `*` markers in the Configure view (each row maps
///   to a key like `system.hostname`, `lnd.alias`).
/// - The dashboard header's `X pending` / `all applied` status
///   segment between platform and version.
///
/// **Synchronous Provider, not FutureProvider.** Both inputs
/// resolve via `ref.watch(...).maybeWhen(data:, orElse: null)`
/// so this returns a value in the same frame as the
/// `configProvider` keystroke that triggered it. The earlier
/// async shape walked through `AsyncLoading` on every change
/// and the UI flickered — markers clearing then reappearing —
/// because the loading-state fallback returned an empty set.
///
/// The dashboard's existing "! N pending change(s)" banner uses
/// the file-level [pendingChangesProvider] separately. The two
/// can occasionally disagree — e.g. a templates dir is dirty
/// (banner: "1 pending change") while no `config.json` keys
/// differ (header: "all applied"). Intentional: they signal
/// different scopes.
final pendingChangeKeysProvider = Provider<Set<String>>((ref) {
  final live = ref
      .watch(configProvider)
      .maybeWhen(data: (c) => c, orElse: () => null);
  if (live == null) return const <String>{};
  final committed = ref
      .watch(committedConfigProvider)
      .maybeWhen(data: (c) => c, orElse: () => null);
  if (committed == null) return const <String>{};
  return live.diffKeysFrom(committed);
});
