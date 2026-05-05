import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/streamers/system_stats_readers.dart';

/// Entry point invoked via `nixblitz streamer system-stats`. Reads
/// procfs/sysfs and emits TileEvent JSON-lines on stdout for the
/// hardware + system tiles.
///
/// Args:
///   --units a,b,c   comma-separated systemd units to poll for
///                   is-active state. Empty = no service map rows.
Future<void> systemStatsMain(List<String> args) async {
  final units = _parseUnitsArg(args);

  // Hardware: every 2s. System: every 5s.
  var hardwareBusy = false;
  var systemBusy = false;

  Timer.periodic(const Duration(seconds: 2), (_) async {
    if (hardwareBusy) return;
    hardwareBusy = true;
    try {
      final ev = await _readHardware();
      _emit('hardware', ev);
    } catch (e) {
      stderr.writeln('system-stats: hardware read failed: $e');
    } finally {
      hardwareBusy = false;
    }
  });
  Timer.periodic(const Duration(seconds: 5), (_) async {
    if (systemBusy) return;
    systemBusy = true;
    try {
      final ev = await _readSystem(units);
      _emit('system', ev);
    } catch (e) {
      stderr.writeln('system-stats: system read failed: $e');
    } finally {
      systemBusy = false;
    }
  });

  // Emit once immediately so the UI populates fast.
  _emit('hardware', await _readHardware());
  _emit('system', await _readSystem(units));

  // Block forever (until parent SIGTERMs us).
  await Completer<void>().future;
}

List<String> _parseUnitsArg(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--units' && i + 1 < args.length) {
      return args[i + 1].split(',').where((s) => s.isNotEmpty).toList();
    }
  }
  return const [];
}

CpuTimes _lastCpu = const CpuTimes(user: 0, system: 0, idle: 0, total: 0);

Future<Map<String, dynamic>> _readHardware() async {
  final stat = await File('/proc/stat').readAsString();
  final cur = parseProcStatCpu(stat);
  final pct = cpuPercent(_lastCpu, cur);
  _lastCpu = cur;

  final meminfo = await File('/proc/meminfo').readAsString();
  final mem = parseProcMeminfo(meminfo);

  double? tempC;
  final tempFile = File('/sys/class/thermal/thermal_zone0/temp');
  if (tempFile.existsSync()) {
    try {
      tempC = parseTemperatureMilliC(await tempFile.readAsString());
    } catch (_) {}
  }

  // Disk usage on /mnt/data (or / fallback).
  final diskMount = Directory('/mnt/data').existsSync() ? '/mnt/data' : '/';
  final df = await Process.run('df', ['-B1', diskMount]);
  int diskUsed = 0, diskTotal = 0;
  if (df.exitCode == 0) {
    final lines = (df.stdout as String).split('\n');
    if (lines.length >= 2) {
      final parts = lines[1].split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        diskTotal = int.tryParse(parts[1]) ?? 0;
        diskUsed = int.tryParse(parts[2]) ?? 0;
      }
    }
  }

  return {
    'cpu_percent': pct,
    'mem_used_bytes': mem.usedBytes,
    'mem_total_bytes': mem.totalBytes,
    'temperature_c': tempC,
    'disk_used_bytes': diskUsed,
    'disk_total_bytes': diskTotal,
    'disk_mount': diskMount,
  };
}

Future<Map<String, dynamic>> _readSystem(List<String> units) async {
  final uptime = parseProcUptime(await File('/proc/uptime').readAsString());
  final result = <String, dynamic>{'uptime_sec': uptime};
  for (final unit in units) {
    final r = await Process.run('systemctl', ['is-active', unit]);
    result['services.$unit'] = (r.stdout as String).trim();
  }
  return result;
}

void _emit(String tile, Map<String, dynamic> data) {
  stdout.writeln(
    jsonEncode({
      'tile': tile,
      'data': data,
      'ts': DateTime.now().millisecondsSinceEpoch,
    }),
  );
}
