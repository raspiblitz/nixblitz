import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_action.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_teardown.dart';

/// Runs one plugin action and returns its output stream + exit code. The
/// real binding is `PluginActionRunner.run`; tests pass a fake.
typedef ActionRun =
    ({Stream<String> output, Future<int> exitCode}) Function(
      PluginAction action,
    );

/// Detects the plugins being halted by the rebuild this Apply/CLI run will
/// perform — removed from `plugins.list` (uninstall) ∪ `enabled` true→false
/// (disable) — resolves each one's teardown from the committed manifest, and
/// runs it on the live system. Path-agnostic: both the TUI Apply flow and the
/// CLI `update` rebuild construct one and call [runPending] before
/// `nixos-rebuild`. Best-effort throughout: nothing here throws to the caller.
class PluginTeardownRunner {
  PluginTeardownRunner({
    required this.runAction,
    required this.readCommitted,
    required this.readCurrent,
  });

  /// Runs a resolved teardown action (→ `PluginActionRunner.run`).
  final ActionRun runAction;

  /// Reads a repo-relative path from the committed tree (git HEAD). Returns
  /// null when the path isn't committed. (→ `GitService.readCommittedFile`.)
  final Future<String?> Function(String relPath) readCommitted;

  /// Reads a repo-relative path from the working tree. Returns null when
  /// absent.
  final String? Function(String relPath) readCurrent;

  /// The production [readCurrent] binding: read repo-relative paths from
  /// the working tree at [baseDir]. Kept here so callers (TUI Apply, CLI
  /// update) don't each hand-roll the file access.
  static String? Function(String relPath) workingTreeReader(String baseDir) =>
      (p) {
        final f = File('$baseDir/$p');
        return f.existsSync() ? f.readAsStringSync() : null;
      };

  /// Resolve the teardowns pending for this rebuild. Reads HEAD vs the working
  /// tree, so call BEFORE any commit that would collapse the diff.
  Future<List<PluginTeardown>> resolvePending() async {
    try {
      final removed = removedPluginIds(
        committed: parsePluginsList(await readCommitted('plugins.list')),
        current: parsePluginsList(readCurrent('plugins.list')),
      );
      final disabled = disabledPluginIds(
        committed: _config(await readCommitted('config.json')),
        current: _config(readCurrent('config.json')),
      );
      final ids = {...removed, ...disabled};
      return resolveTeardowns(
        removedIds: ids,
        readManifest: (id) => readCommitted('plugins/$id/plugin.json'),
      );
    } catch (e, st) {
      LogService.error('teardown: resolving pending teardowns failed', e, st);
      return const [];
    }
  }

  /// Run the given teardowns, streaming progress to [emit]. Non-fatal.
  Future<void> run(
    List<PluginTeardown> teardowns,
    void Function(String line) emit,
  ) async {
    for (final t in teardowns) {
      emit('');
      emit('> tearing down ${t.pluginId}: ${t.action.label}');
      try {
        final (:output, :exitCode) = runAction(t.action);
        await output.forEach((line) {
          LogService.info('[teardown ${t.pluginId}] $line');
          emit(line);
        });
        final code = await exitCode;
        if (code != 0) {
          LogService.warn('teardown ${t.pluginId} exited $code');
          emit('  ! teardown ${t.pluginId} exited $code — continuing');
        }
      } catch (e, st) {
        LogService.error('teardown ${t.pluginId} failed', e, st);
        emit('  ! teardown ${t.pluginId} failed: $e — continuing');
      }
    }
  }

  /// Convenience: [resolvePending] then [run].
  Future<void> runPending(void Function(String line) emit) async =>
      run(await resolvePending(), emit);

  NixblitzConfig? _config(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return NixblitzConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      LogService.warn('teardown: config parse failed: $e');
      return null;
    }
  }
}
