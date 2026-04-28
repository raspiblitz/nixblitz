import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/services/log_service.dart';

/// Watches `~/nixblitz/` for filesystem changes and reloads the
/// [configProvider] when they touch state the running TUI cares
/// about: the main `config.json` or any plugin's `manifest.json`.
///
/// Without this, an external mutation — `nixblitz plugin add ...`
/// from another shell, a hand-edit to `config.json`, a script —
/// is invisible to the running TUI until the operator quits and
/// relaunches. Everything downstream (`pendingChangesProvider`,
/// `PluginDashboardService`, the Configure view's plugin list)
/// already reacts to `configProvider` changes; the only gap is
/// that `configProvider` itself never re-reads from disk after
/// startup. This provider closes that gap.
///
/// Self-emit caveat: the TUI also writes to `config.json` via
/// `ConfigNotifier.updateConfig`. Those writes fire FS events
/// that reach this watcher, which then calls `reload()` — a
/// no-op in terms of the resulting state value, but it does
/// re-publish the same value through Riverpod and re-trigger
/// downstream rebuilds. Acceptable for now (config writes are
/// rare on the user-facing path; the cost is one redundant
/// re-render). A content-fingerprint check could short-circuit
/// the redundant emits if churn becomes a problem.
///
/// Per-plugin `config.json` writes (the Configure view writes
/// these on every keystroke when editing a plugin) are
/// intentionally **not** triggers — only the main config and
/// plugin manifests can change the shape of what the TUI
/// renders, and per-plugin config has its own provider chain.
///
/// Linux-only: Dart's `Directory.watch(recursive: true)` doesn't
/// work on macOS. NixBlitz only ships on NixOS in production;
/// dev on macOS still gets a working TUI minus this auto-reload
/// nicety.
final configWatcherProvider = Provider<void>((ref) {
  if (!Platform.isLinux) {
    LogService.info(
      'configWatcherProvider: not Linux, skipping FS watcher',
    );
    return;
  }

  final baseDir = ref.watch(baseDirProvider);
  final dir = Directory(baseDir);
  if (!dir.existsSync()) {
    // No tracked config yet — Setup hasn't run. Nothing to watch
    // until that changes. The watcher would be re-instantiated
    // on the next provider invalidation; we trust the surrounding
    // app to handle the bootstrap path explicitly.
    LogService.warn(
      'configWatcherProvider: $baseDir does not exist, skipping',
    );
    return;
  }

  Timer? debounce;
  StreamSubscription<FileSystemEvent>? sub;

  try {
    sub = dir.watch(recursive: true).listen(
      (event) {
        if (!_isRelevant(event.path, baseDir)) return;
        // Debounce so a burst of writes from a single CLI
        // operation (`plugin add` does several mkdir + writeFile
        // in sequence) collapses to one reload. 250 ms is
        // comfortably longer than the typical write burst on a
        // local disk, well below human-perceptible latency.
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 250), () {
          LogService.info(
            'configWatcherProvider: ${event.path} changed, '
            'reloading config',
          );
          ref.read(configProvider.notifier).reload();
        });
      },
      onError: (e, st) {
        LogService.error(
          'configWatcherProvider: watch stream errored',
          e,
          st,
        );
      },
    );
  } catch (e, st) {
    LogService.error(
      'configWatcherProvider: failed to start watching $baseDir',
      e,
      st,
    );
  }

  ref.onDispose(() {
    debounce?.cancel();
    sub?.cancel();
  });
});

/// True when [path] is something the running TUI should re-read
/// the config for. Captures the main `config.json` and anything
/// under `plugins/` (manifest, plugin.nix, README, LICENSE,
/// directory creates / deletes) — minus per-plugin `config.json`,
/// which churns on every keystroke from the Configure view and
/// has its own reactivity in `plugin_config_provider.dart`.
///
/// Why "anything under plugins/" rather than just manifest.json:
/// when a CLI tool creates `plugins/<id>/` and immediately writes
/// a manifest inside, Dart's `Directory.watch(recursive: true)`
/// can miss the inner file event because the recursive inotify
/// watcher hasn't finished hooking the new subdirectory yet. The
/// directory-creation event at `$base/plugins/<id>` fires
/// reliably, and that's enough of a "something changed" signal
/// — the subsequent reload re-walks the manifests and picks up
/// whatever finished writing.
bool _isRelevant(String path, String baseDir) {
  // Normalize trailing slashes that some platforms emit.
  final base = baseDir.endsWith('/')
      ? baseDir.substring(0, baseDir.length - 1)
      : baseDir;
  if (path == '$base/config.json') return true;
  // First-time `plugins/` directory creation. Recursive watches
  // miss the inner file events when a CLI creates the dir +
  // writes a manifest in quick succession (the inotify hook for
  // the new subdir hasn't installed yet); catch the parent dir
  // creation event so we still get a "something changed under
  // plugins" signal in that bootstrap case.
  if (path == '$base/plugins') return true;
  if (path.startsWith('$base/plugins/')) {
    // Per-plugin config.json writes happen on every keystroke in
    // the Configure view's plugin form; reloading the main
    // config on every one of those would churn the dashboard
    // pollers and pendingChangesProvider for no benefit.
    if (path.endsWith('/config.json')) return false;
    return true;
  }
  return false;
}
