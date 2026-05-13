import 'dart:convert';
import 'dart:io';

import 'package:common/src/services/log_service.dart';

/// Snapshot of what HEAD looked like the last time a `nixos-rebuild
/// switch` exited 0.
///
/// Compared against `git rev-parse HEAD` to detect the case where the
/// repo has commits that never reached `/run/current-system` — usually
/// because the operator quit (or the rebuild crashed) between the
/// pre-rebuild `git commit` and the actual switch.
class AppliedState {
  const AppliedState({
    required this.rev,
    required this.appliedAt,
    required this.toplevel,
    required this.flakeAttr,
  });

  /// Full SHA returned by `git rev-parse HEAD` at the moment the
  /// rebuild succeeded.
  final String rev;

  /// Wall-clock time of the successful rebuild, ISO 8601 UTC.
  final DateTime appliedAt;

  /// Store path that `/run/current-system` pointed at immediately
  /// after the switch. Diagnostic only — lets us confirm the recorded
  /// rev matches a system that's actually running if the operator
  /// files a bug.
  final String toplevel;

  /// Rebuild attribute (`x86-installed`, `pi5-installed`, …).
  /// Informational; not consumed by any provider today.
  final String flakeAttr;

  Map<String, dynamic> toJson() => {
    'rev': rev,
    'appliedAt': appliedAt.toUtc().toIso8601String(),
    'toplevel': toplevel,
    'flakeAttr': flakeAttr,
  };

  static AppliedState? fromJson(Map<String, dynamic> json) {
    final rev = json['rev'];
    final appliedAt = json['appliedAt'];
    final toplevel = json['toplevel'];
    final flakeAttr = json['flakeAttr'];
    if (rev is! String || appliedAt is! String) return null;
    final parsedAt = DateTime.tryParse(appliedAt);
    if (parsedAt == null) return null;
    return AppliedState(
      rev: rev,
      appliedAt: parsedAt,
      toplevel: toplevel is String ? toplevel : '',
      flakeAttr: flakeAttr is String ? flakeAttr : '',
    );
  }
}

/// Reads / writes `last-applied.json` — the single source of truth
/// for "what HEAD did we last actually activate."
///
/// The file is a hint, not authoritative state. Missing / unreadable /
/// corrupt → [read] returns null and the dashboard falls back to
/// "no signal" (same UX as a fresh install where the operator hasn't
/// applied anything yet).
class AppliedStateService {
  AppliedStateService({String? stateDir}) : _stateDir = stateDir;

  final String? _stateDir;

  /// `~/.local/state/nixblitz/` by default. Honours `$XDG_STATE_HOME`
  /// when set; falls back to `~/.local/state/` per the XDG Base Dir
  /// spec. If `$HOME` is empty (CI / sandbox), returns null and the
  /// service becomes a no-op.
  String? _resolveDir() {
    if (_stateDir != null) return _stateDir;
    final env = Platform.environment;
    final xdg = env['XDG_STATE_HOME'];
    if (xdg != null && xdg.isNotEmpty) return '$xdg/nixblitz';
    final home = env['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/.local/state/nixblitz';
  }

  String? _path() {
    final dir = _resolveDir();
    return dir == null ? null : '$dir/last-applied.json';
  }

  Future<AppliedState?> read() async {
    final path = _path();
    if (path == null) return null;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return AppliedState.fromJson(decoded);
    } catch (e, st) {
      LogService.warn('AppliedStateService.read failed: $e');
      LogService.error('AppliedStateService.read trace', e, st);
      return null;
    }
  }

  /// Writes the state synchronously. Failures are logged and
  /// swallowed — the caller has just finished a successful rebuild,
  /// and a missing hint file should not roll that back.
  void write({
    required String rev,
    required String toplevel,
    required String flakeAttr,
  }) {
    final dir = _resolveDir();
    if (dir == null) return;
    try {
      Directory(dir).createSync(recursive: true);
      final state = AppliedState(
        rev: rev,
        appliedAt: DateTime.now().toUtc(),
        toplevel: toplevel,
        flakeAttr: flakeAttr,
      );
      File('$dir/last-applied.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(state.toJson()),
      );
    } catch (e, st) {
      LogService.warn('AppliedStateService.write failed: $e');
      LogService.error('AppliedStateService.write trace', e, st);
    }
  }
}
