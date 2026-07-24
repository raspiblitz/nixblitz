import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../log_service.dart';
import 'install_phase.dart';

/// Snapshot of install progress for the panel.
class InstallProgress {
  final InstallPhase phase;
  final double? copyFraction;
  const InstallProgress({required this.phase, this.copyFraction});

  @override
  bool operator ==(Object other) =>
      other is InstallProgress &&
      other.phase == phase &&
      other.copyFraction == copyFraction;

  @override
  int get hashCode => Object.hash(phase, copyFraction);
}

/// Parse `du -sb path` stdout ("bytes\tpath") into bytes.
int? parseDuBytes(String duStdout) {
  final first = duStdout.trim().split(RegExp(r'\s+')).firstOrNull;
  return first == null ? null : int.tryParse(first);
}

/// Parse `df -B1 --output=used mnt` stdout ("used\nbytes") into bytes.
int? parseDfUsedBytes(String dfStdout) {
  final lines = dfStdout.trim().split('\n');
  if (lines.length < 2) return null;
  return int.tryParse(lines[1].trim());
}

/// Total bytes of the source store (the closure being copied). Null on
/// any failure — the tracker then hides the bar.
Future<int?> duSourceBytes([String path = '/nix/store']) async {
  try {
    final r = await Process.run('du', ['-sb', path]);
    if (r.exitCode != 0) return null;
    return parseDuBytes(r.stdout as String);
  } catch (e) {
    LogService.warn('duSourceBytes failed: $e');
    return null;
  }
}

/// Bytes used on the target mount. Null when the mount is absent or the
/// command fails — the tracker keeps showing a spinner instead.
Future<int?> dfUsedBytes(String mountPoint) async {
  try {
    final r = await Process.run('df', ['-B1', '--output=used', mountPoint]);
    if (r.exitCode != 0) return null;
    return parseDfUsedBytes(r.stdout as String);
  } catch (e) {
    LogService.warn('dfUsedBytes failed: $e');
    return null;
  }
}

/// Drives an [InstallProgress] from disko-install output lines + polled
/// filesystem byte counts. Never throws into the caller; all reader
/// failures degrade to a hidden bar.
class InstallProgressTracker {
  InstallProgressTracker({
    required Future<int?> Function() readTotalBytes,
    required Future<int?> Function() readUsedBytes,
    this.pollInterval = const Duration(seconds: 2),
    required this.onChange,
  }) : _readTotal = readTotalBytes,
       _readUsed = readUsedBytes;

  final Future<int?> Function() _readTotal;
  final Future<int?> Function() _readUsed;
  final Duration pollInterval;
  final void Function(InstallProgress) onChange;

  InstallProgress _value = const InstallProgress(phase: InstallPhase.preparing);
  InstallProgress get value => _value;

  Timer? _pollTimer;
  int? _total;
  bool _totalRequested = false;
  bool _disposed = false;

  void addLine(String line) {
    if (_disposed) return;
    final next = installPhaseForLine(line);
    if (next == null || next == _value.phase) return;
    switch (next) {
      case InstallPhase.copying:
        _emit(InstallProgress(phase: next, copyFraction: null));
        _startCopyPoll();
      case InstallPhase.loadingDb:
        _stopCopyPoll();
        _emit(
          const InstallProgress(
            phase: InstallPhase.loadingDb,
            copyFraction: 1.0,
          ),
        );
      default:
        _stopCopyPoll();
        _emit(InstallProgress(phase: next, copyFraction: null));
    }
  }

  void _startCopyPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    if (_value.phase != InstallPhase.copying) return;
    if (!_totalRequested) {
      _totalRequested = true;
      _total = await _readTotal();
    }
    // Bail before the (wasted) used-bytes read if the phase moved on or we
    // were disposed while awaiting the total-bytes read above.
    if (_disposed || _value.phase != InstallPhase.copying) return;
    final used = await _readUsed();
    // phase changed or disposed mid-await: don't emit a stale fraction.
    if (_disposed || _value.phase != InstallPhase.copying) return;
    double? frac;
    if (_total != null && _total! > 0 && used != null) {
      frac = math.min(0.99, used / _total!);
    }
    _emit(InstallProgress(phase: InstallPhase.copying, copyFraction: frac));
  }

  void _stopCopyPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _emit(InstallProgress p) {
    if (_disposed) return;
    if (p == _value) return;
    _value = p;
    onChange(p);
  }

  void dispose() {
    _disposed = true;
    _stopCopyPoll();
  }
}
