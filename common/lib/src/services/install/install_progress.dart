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

/// Total install bytes baked into the live medium at ISO/image build time
/// (`nix/iso.nix` / `nix/pi5-image.nix` write closureInfo's
/// `total-nar-size` to this path — see `nix/install-cli-products.nix`).
/// Reading it is instant, unlike [duSourceBytes]. Null on any failure
/// (missing file, unparsable contents, non-ISO context) — never throws.
Future<int?> installTotalBytesFromEtc({
  String path = '/etc/nixblitz/install-total-bytes',
}) async {
  try {
    final contents = await File(path).readAsString();
    return int.tryParse(contents.trim());
  } catch (e) {
    LogService.warn('installTotalBytesFromEtc failed: $e');
    return null;
  }
}

/// Total bytes to copy during install: prefer the value baked at ISO/image
/// build time (instant), falling back to a live `du -sb` scan (used
/// outside the baked-ISO context, e.g. dev runs). Injectable readers for
/// tests.
Future<int?> installTotalBytes({
  Future<int?> Function() readEtc = installTotalBytesFromEtc,
  Future<int?> Function() readDu = duSourceBytes,
}) async {
  final etcTotal = await readEtc();
  if (etcTotal != null) return etcTotal;
  return readDu();
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
  // Kicked off here rather than lazily on the first copy-phase poll: with
  // the baked etc-file reader it resolves instantly anyway, and with the
  // `du -sb` fallback it gets the whole eval/partition/format/mount phase
  // as a head start instead of blocking the first copy-phase tick.
  InstallProgressTracker({
    required Future<int?> Function() readTotalBytes,
    required Future<int?> Function() readUsedBytes,
    this.pollInterval = const Duration(seconds: 2),
    required this.onChange,
  }) : _totalFuture = readTotalBytes(),
       _readUsed = readUsedBytes;

  final Future<int?> _totalFuture;
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
    // Phases are monotonic for a real install run (preparing -> ... ->
    // done). nix's "copying path '...'" lines keep showing up during the
    // nixos-install tail even after we've moved past copying (e.g. while
    // installing the boot loader), which would otherwise flap the panel
    // back to an earlier phase and restart the copy poll. A retry always
    // gets a fresh tracker, so backward transitions are never legitimate.
    if (next.index <= _value.phase.index) return;
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
      _total = await _totalFuture;
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
