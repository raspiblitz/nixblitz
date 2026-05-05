import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/services/dashboard/tile_event.dart';
import 'package:common/src/services/dashboard/tile_event_source.dart';
import 'package:common/src/services/log_service.dart';

/// Emitted on the events stream when the subprocess has restarted at least
/// [crashLoopThreshold] times within [crashLoopWindow]. Consumers should
/// surface this as a persistent error tile.
class StreamerCrashLoopError implements Exception {
  final String streamerId;
  final int restarts;

  StreamerCrashLoopError(this.streamerId, this.restarts);

  @override
  String toString() =>
      'StreamerCrashLoopError: streamer "$streamerId" crash-looping '
      '($restarts restarts) — see log';
}

/// [TileEventSource] that spawns a long-lived subprocess and parses its
/// stdout as newline-delimited JSON. Each valid JSON object becomes a
/// [TileEvent]. Invalid / over-long lines are dropped and logged.
///
/// Lifecycle:
/// - [start] spawns the process and kicks off the run loop.
/// - On exit the loop waits the next [backoff] duration and restarts.
/// - If [crashLoopThreshold] restarts accumulate within [crashLoopWindow],
///   a [StreamerCrashLoopError] is added to [events] and backoff slows to
///   the last entry (or 30 s). Retries continue — the error is "sticky" but
///   clears on a successful first-event.
/// - [dispose] sends SIGTERM; if the child doesn't exit within 2 s, SIGKILL.
class StreamerSubprocessSource implements TileEventSource {
  @override
  final String id;
  @override
  final Set<String> providedTileIds;

  final String command;
  final List<String> args;

  /// If non-null, replaces the child's entire environment. If null, the child
  /// inherits only PATH and LANG from the parent to keep it reproducible.
  final Map<String, String>? environmentOverride;

  /// Working directory for the spawned process. When non-null the directory is
  /// created if it does not exist, and HOME is set to this path (unless
  /// [environmentOverride] is provided). When null the parent's cwd is used —
  /// this is the test-friendly default; production callers should pass
  /// `/var/lib/nixblitz/streamers/<id>`.
  final String? workingDirectory;

  /// Backoff sequence applied between restarts. Empty means restart
  /// immediately with no delay (useful in tests).
  final List<Duration> backoff;

  /// Number of restarts within [crashLoopWindow] that triggers crash-loop
  /// detection.
  final int crashLoopThreshold;

  /// Sliding window used for crash-loop accounting.
  final Duration crashLoopWindow;

  /// Lines longer than this are dropped + logged rather than parsed.
  final int maxLineLength;

  final StreamController<TileEvent> _ctrl =
      StreamController<TileEvent>.broadcast();

  Process? _proc;
  bool _started = false;
  bool _disposed = false;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  /// Timestamps of recent process exits — used for crash-loop detection.
  final List<DateTime> _restartTs = [];

  StreamerSubprocessSource({
    required this.id,
    required this.providedTileIds,
    required this.command,
    required this.args,
    this.environmentOverride,
    this.workingDirectory,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
    this.crashLoopThreshold = 3,
    this.crashLoopWindow = const Duration(seconds: 60),
    this.maxLineLength = 64 * 1024,
  });

  @override
  Stream<TileEvent> get events => _ctrl.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    unawaited(_runLoop());
  }

  Future<void> _runLoop() async {
    var attempt = 0;
    while (!_disposed) {
      bool wasClean = false;
      try {
        wasClean = await _spawnAndPipe();
      } catch (e, st) {
        LogService.warn('streamer "$id" run failed: $e\n$st');
      }

      if (_disposed) return;

      // Reset backoff on a clean run so a flapping-then-stabilising streamer
      // doesn't carry stale backoff debt once it recovers.
      if (wasClean) attempt = 0;

      // Crash-loop detection: count exits within the sliding window.
      final now = DateTime.now();
      _restartTs.add(now);
      _restartTs.removeWhere((t) => now.difference(t) > crashLoopWindow);

      if (_restartTs.length >= crashLoopThreshold) {
        if (!_ctrl.isClosed) {
          _ctrl.addError(StreamerCrashLoopError(id, _restartTs.length));
        }
        // Keep retrying but at the slowest pace to avoid thrashing.
        final slowest = backoff.isEmpty
            ? const Duration(seconds: 30)
            : backoff.last;
        if (!_disposed) await Future.delayed(slowest);
        continue;
      }

      final wait = backoff.isEmpty
          ? Duration.zero
          : backoff[attempt.clamp(0, backoff.length - 1)];
      attempt++;
      if (wait != Duration.zero && !_disposed) await Future.delayed(wait);
    }
  }

  Future<bool> _spawnAndPipe() async {
    final env =
        environmentOverride ??
        <String, String>{
          'PATH': Platform.environment['PATH'] ?? '',
          'LANG': 'C.UTF-8',
          'HOME': ?workingDirectory,
        };

    // Create the working directory if it was specified but doesn't exist yet.
    if (workingDirectory != null) {
      final dir = Directory(workingDirectory!);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }

    final proc = await Process.start(
      command,
      args,
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: workingDirectory,
    );
    _proc = proc;

    // Fix: if dispose() ran while Process.start was in-flight, kill immediately
    // rather than waiting for the child to exit on its own.
    if (_disposed) {
      proc.kill(ProcessSignal.sigterm);
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        proc.kill(ProcessSignal.sigkill);
        await proc.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      }
      _proc = null;
      return false;
    }

    // Track whether the subprocess emitted at least one valid event so we
    // can reset the restart-counter on a successful run.
    var firstEventSeen = false;

    _stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.length > maxLineLength) {
            LogService.warn(
              'streamer "$id": dropped over-long line (${line.length} bytes)',
            );
            return;
          }
          try {
            final json = jsonDecode(line) as Map<String, dynamic>;
            final ev = TileEvent(
              tileId: json['tile'] as String,
              data: ((json['data'] as Map?) ?? const {})
                  .cast<String, dynamic>(),
              ts: DateTime.fromMillisecondsSinceEpoch(
                (json['ts'] as num?)?.toInt() ??
                    DateTime.now().millisecondsSinceEpoch,
              ),
            );
            if (!_ctrl.isClosed) _ctrl.add(ev);
            firstEventSeen = true;
          } catch (e) {
            LogService.warn('streamer "$id": malformed line dropped: $e');
          }
        });

    _stderrSub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => LogService.warn('streamer "$id" stderr: $line'));

    final exitCode = await proc.exitCode;
    LogService.info('streamer "$id" exited (code $exitCode)');

    // Reset the restart counter only when the process exited cleanly (code 0)
    // AND emitted at least one event. A process that crashes (non-zero exit)
    // is still considered unstable even if it managed to produce some output.
    // This lets a flapping-but-recovering streamer clear its crash-loop debt
    // once it actually stays healthy through a full run.
    final wasClean = exitCode == 0 && firstEventSeen;
    if (wasClean) _restartTs.clear();

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _proc = null;
    return wasClean;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final p = _proc;
    if (p != null) {
      p.kill(ProcessSignal.sigterm);
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
        await p.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1, // best-effort orphan if D-state
        );
      }
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}
