import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/staged_changes.dart';
import 'package:common/src/models/update_status.dart' show PluginAhead;
import 'package:common/src/services/log_service.dart';

/// Reads / writes `/var/lib/nixblitz-tui/staging/` — the set of
/// candidate changes the next Apply will promote to the live system.
///
/// On-disk layout:
///
/// ```
/// staging/
/// ├── flake.lock         # candidate lock (only present if a check
/// │                      # found upstream movement)
/// ├── plugin-pins.json   # [PluginAhead, ...] in JSON
/// ├── nvd-diff.txt       # cached nvd output for the staged state
/// ├── new-toplevel       # store path of the would-be system
/// └── checked-at         # ISO8601 timestamp
/// ```
///
/// Every method swallows I/O errors and logs — the Apply view treats
/// "staging unreadable" as "nothing staged" so a corrupted file can't
/// brick the dashboard.
class StagingService {
  StagingService({String? basePath}) : basePath = basePath ?? defaultPath();

  final String basePath;

  /// Default staging dir. Overridable via `NIXBLITZ_STAGING_PATH` so
  /// tests and dev-box runs don't trip on the production `/var/lib`
  /// path that systemd-tmpfiles provisions only on installed
  /// systems. Mirrors the `NIXBLITZ_UPDATE_STATUS_PATH` knob in
  /// `update_status.dart`.
  static String defaultPath() {
    final env = Platform.environment['NIXBLITZ_STAGING_PATH'];
    if (env != null && env.isNotEmpty) return env;
    return '/var/lib/nixblitz-tui/staging';
  }

  String get lockPath => '$basePath/flake.lock';
  String get _pluginsPath => '$basePath/plugin-pins.json';
  String get _nvdPath => '$basePath/nvd-diff.txt';
  String get _toplevelPath => '$basePath/new-toplevel';
  String get _checkedAtPath => '$basePath/checked-at';

  void _ensureDir() {
    final d = Directory(basePath);
    if (!d.existsSync()) d.createSync(recursive: true);
  }

  /// Read the current staging snapshot. Returns
  /// [StagedChanges.empty] when the dir is missing or every artifact
  /// is unreadable — callers should branch on [StagedChanges.isEmpty]
  /// rather than on null.
  StagedChanges read() {
    final lockFile = File(lockPath);
    final pluginsFile = File(_pluginsPath);
    final nvdFile = File(_nvdPath);
    final toplevelFile = File(_toplevelPath);
    final checkedAtFile = File(_checkedAtPath);

    List<PluginAhead> plugins = const [];
    if (pluginsFile.existsSync()) {
      try {
        final raw = pluginsFile.readAsStringSync();
        final j = jsonDecode(raw) as List<dynamic>;
        plugins = j
            .map((e) => PluginAhead.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e, st) {
        LogService.warn('staging: failed to read plugin-pins.json: $e');
        LogService.error('staging.read plugins trace', e, st);
      }
    }

    DateTime? checkedAt;
    if (checkedAtFile.existsSync()) {
      try {
        checkedAt = DateTime.parse(checkedAtFile.readAsStringSync().trim());
      } catch (e, st) {
        LogService.warn('staging: failed to parse checked-at: $e');
        LogService.error('staging.read checked-at trace', e, st);
      }
    }

    String? nvd;
    if (nvdFile.existsSync()) {
      try {
        nvd = nvdFile.readAsStringSync();
      } catch (e, st) {
        LogService.warn('staging: failed to read nvd-diff.txt: $e');
        LogService.error('staging.read nvd trace', e, st);
      }
    }

    String? toplevel;
    if (toplevelFile.existsSync()) {
      try {
        toplevel = toplevelFile.readAsStringSync().trim();
      } catch (e, st) {
        LogService.warn('staging: failed to read new-toplevel: $e');
        LogService.error('staging.read toplevel trace', e, st);
      }
    }

    return StagedChanges(
      lockBumpAvailable: lockFile.existsSync(),
      pluginPins: plugins,
      nvdDiff: nvd,
      newToplevel: toplevel,
      checkedAt: checkedAt,
    );
  }

  /// Copy [source] into staging as the candidate `flake.lock`.
  /// Caller is responsible for verifying [source] actually differs
  /// from the live `~/nixblitz/flake.lock` — this method just copies.
  void writeLockBump(File source) {
    _ensureDir();
    try {
      source.copySync(lockPath);
    } catch (e, st) {
      LogService.warn('staging.writeLockBump failed: $e');
      LogService.error('staging.writeLockBump trace', e, st);
    }
  }

  void writePluginPins(List<PluginAhead> pins) {
    _ensureDir();
    try {
      final j = jsonEncode(pins.map((p) => p.toJson()).toList());
      File(_pluginsPath).writeAsStringSync(j);
    } catch (e, st) {
      LogService.warn('staging.writePluginPins failed: $e');
      LogService.error('staging.writePluginPins trace', e, st);
    }
  }

  void writeNvdDiff(String text) {
    _ensureDir();
    try {
      File(_nvdPath).writeAsStringSync(text);
    } catch (e, st) {
      LogService.warn('staging.writeNvdDiff failed: $e');
      LogService.error('staging.writeNvdDiff trace', e, st);
    }
  }

  void writeNewToplevel(String path) {
    _ensureDir();
    try {
      File(_toplevelPath).writeAsStringSync(path);
    } catch (e, st) {
      LogService.warn('staging.writeNewToplevel failed: $e');
      LogService.error('staging.writeNewToplevel trace', e, st);
    }
  }

  void writeCheckedAt(DateTime when) {
    _ensureDir();
    try {
      File(_checkedAtPath).writeAsStringSync(when.toUtc().toIso8601String());
    } catch (e, st) {
      LogService.warn('staging.writeCheckedAt failed: $e');
      LogService.error('staging.writeCheckedAt trace', e, st);
    }
  }

  /// Wipe everything under the staging dir. Called by Apply after a
  /// successful rebuild — the staged candidates have either been
  /// promoted (lock copy, plugin marker writes) or discarded (operator
  /// hit `[d]`).
  void clearAll() {
    final d = Directory(basePath);
    if (!d.existsSync()) return;
    for (final entity in d.listSync()) {
      try {
        entity.deleteSync(recursive: true);
      } catch (e, st) {
        LogService.warn(
          'staging.clearAll: failed to delete ${entity.path}: $e',
        );
        LogService.error('staging.clearAll trace', e, st);
      }
    }
  }

  void clearLockBump() => _safeDelete(File(lockPath));
  void clearPluginPins() => _safeDelete(File(_pluginsPath));

  void _safeDelete(File f) {
    if (!f.existsSync()) return;
    try {
      f.deleteSync();
    } catch (e, st) {
      LogService.warn('staging: failed to delete ${f.path}: $e');
      LogService.error('staging._safeDelete trace', e, st);
    }
  }
}
