import 'dart:async';
import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/plugin/plugin_tile.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/installed_plugins_provider.dart';
import 'package:common/src/providers/plugin_action_provider.dart';
import 'package:common/src/providers/plugin_provider.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/plugin_action_runner.dart';
import 'package:common/src/services/plugin_service.dart';

/// Polls each installed plugin's `dashboard` command at its declared
/// interval, parses the JSON output into a [PluginTileSnapshot],
/// and broadcasts the latest snapshot map keyed by plugin `id`.
///
/// Lifecycle: `_PluginPoller` per plugin owns one `Timer.periodic`
/// + the latest snapshot. The service watches the installed-plugin
/// marker set and reconciles the poller set: spin up pollers for
/// non-disabled plugins with `dashboard` blocks, tear down pollers
/// for plugins that get disabled or removed.
class PluginDashboardService {
  final Ref _ref;
  final PluginService _pluginService;
  final PluginActionRunner _runner;
  final String _pluginsDir;

  final Map<String, _PluginPoller> _pollers = {};
  final StreamController<Map<String, PluginTileSnapshot?>> _ctrl =
      StreamController<Map<String, PluginTileSnapshot?>>.broadcast();

  bool _disposed = false;

  PluginDashboardService(Ref ref)
    : _ref = ref,
      _pluginService = ref.read(pluginServiceProvider),
      _runner = ref.read(pluginActionRunnerProvider),
      _pluginsDir = ref.read(pluginServiceProvider).pluginsDir {
    // Reconcile when the installed-plugin set changes (an install,
    // remove, or refresh), and once eagerly on construction so
    // pollers spin up immediately.
    _ref.listen(
      installedPluginsProvider,
      (_, _) => _reconcile(),
      fireImmediately: true,
    );
    // Re-reconcile when the operator config changes (e.g. the user
    // toggles a plugin's enabled flag). Mirrors the gate in
    // dashboard_provider that skips disabled-config plugins.
    _ref.listen(configProvider, (_, _) => _reconcile());
  }

  /// Latest snapshot for every plugin we know about. Late
  /// subscribers see this on first emission via
  /// `pluginTileSnapshotsProvider`'s `_withSeed` wrapper.
  Map<String, PluginTileSnapshot?> get seed => _currentSeed();

  Stream<Map<String, PluginTileSnapshot?>> get snapshots => _ctrl.stream;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final p in _pollers.values) {
      p.dispose();
    }
    _pollers.clear();
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  // ── private ──────────────────────────────────────────────────

  Map<String, PluginTileSnapshot?> _currentSeed() {
    return {
      for (final entry in _pollers.entries) entry.key: entry.value.latest,
    };
  }

  void _emit() {
    if (_ctrl.isClosed) return;
    _ctrl.add(_currentSeed());
  }

  /// Reconcile pollers against the current marker set. Non-disabled
  /// plugins with a `dashboard` block get a poller; disabled or
  /// removed plugins lose theirs.
  void _reconcile() {
    if (_disposed) return;

    final markers = discoverInstalledMarkers(_pluginsDir);
    final config = _ref.read(configProvider).value;

    final desired = <String, PluginTileSpec>{};
    for (final m in markers) {
      if (m.disabled) continue;
      // Operator's per-plugin enabled toggle — a disabled plugin's daemon
      // is off, so polling it would just churn errors. Mirrors the gate in
      // dashboard_provider. Config not loaded yet → skip (re-reconciles on
      // load via the configProvider listener added in the constructor).
      if (config == null || !config.isAppEnabled(m.id)) continue;
      try {
        final manifest = _pluginService.readManifest(m.id);
        final spec = manifest.dashboard;
        if (spec == null) continue;
        desired[m.id] = spec;
      } catch (e, st) {
        LogService.warn(
          'PluginDashboardService: failed to read manifest for '
          '${m.id}: $e',
        );
        LogService.error('manifest read', e, st);
      }
    }

    // Tear down pollers for plugins no longer wanted.
    final toRemove = _pollers.keys
        .where((k) => !desired.containsKey(k))
        .toList(growable: false);
    for (final key in toRemove) {
      _pollers.remove(key)?.dispose();
    }

    // Spin up new pollers; restart any whose spec changed (e.g.
    // user edited config that changes interval — rare but covered).
    for (final entry in desired.entries) {
      final id = entry.key;
      final spec = entry.value;
      final existing = _pollers[id];
      if (existing != null && existing.spec == spec) continue;
      existing?.dispose();
      _pollers[id] = _PluginPoller(
        pluginId: id,
        spec: spec,
        runner: _runner,
        onSnapshot: (_) => _emit(),
      )..start();
    }

    _emit();
  }
}

/// Per-plugin poll loop + latest snapshot.
class _PluginPoller {
  final String pluginId;
  final PluginTileSpec spec;
  final PluginActionRunner runner;
  final void Function(PluginTileSnapshot?) onSnapshot;

  Timer? _timer;
  PluginTileSnapshot? _latest;
  bool _disposed = false;

  _PluginPoller({
    required this.pluginId,
    required this.spec,
    required this.runner,
    required this.onSnapshot,
  });

  PluginTileSnapshot? get latest => _latest;

  void start() {
    // Fire one poll immediately so the tile populates without
    // waiting up to 30s for the first refresh.
    unawaited(_poll());
    _timer = Timer.periodic(spec.pollInterval, (_) => _poll());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_disposed) return;
    try {
      final result = await runner.runOneShot(
        command: spec.command,
        timeout: spec.timeout,
      );
      if (_disposed) return;
      _latest = _interpret(result);
    } catch (e, st) {
      LogService.error('plugin tile poll threw for $pluginId', e, st);
      if (_disposed) return;
      _latest = PluginTileSnapshot.failure(
        spec: spec,
        reason: 'poll error: $e',
      );
    }
    onSnapshot(_latest);
  }

  PluginTileSnapshot _interpret(
    ({int exitCode, String stdout, String stderr}) r,
  ) {
    if (r.exitCode == 124) {
      return PluginTileSnapshot.failure(
        spec: spec,
        reason: 'timed out (${spec.timeout.inSeconds}s)',
      );
    }
    // bash exit 127 = command not found. The common cause is a
    // freshly installed plugin whose tile-state script is declared
    // in the manifest but not yet on PATH because the operator
    // hasn't run Apply. Render that as a yellow "pending" tile
    // rather than a red runtime error so it doesn't look like the
    // plugin is broken before they've even had a chance to deploy
    // it.
    if (r.exitCode == 127) {
      return PluginTileSnapshot(
        title: spec.title,
        accentColorHex: spec.accentColorHex,
        rows: const [],
        statusLabel: 'pending',
        statusColor: PluginTileStatus.warn,
        footer: 'awaiting Apply — `${spec.command}` not on PATH yet',
        footerColor: PluginTileStatus.warn,
      );
    }
    if (r.exitCode != 0) {
      final lastErr = _lastNonEmptyLine(r.stderr);
      return PluginTileSnapshot.failure(
        spec: spec,
        reason:
            'command failed (exit ${r.exitCode})'
            '${lastErr.isEmpty ? '' : ': $lastErr'}',
      );
    }
    final trimmed = r.stdout.trim();
    if (trimmed.isEmpty) {
      return PluginTileSnapshot.failure(spec: spec, reason: 'empty stdout');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return PluginTileSnapshot.failure(
        spec: spec,
        reason: 'invalid JSON output',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      return PluginTileSnapshot.failure(
        spec: spec,
        reason: 'expected JSON object, got ${decoded.runtimeType}',
      );
    }
    return PluginTileSnapshot.fromCommandOutput(spec: spec, json: decoded);
  }

  String _lastNonEmptyLine(String s) {
    for (final l in s.split('\n').reversed) {
      final t = l.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }
}
