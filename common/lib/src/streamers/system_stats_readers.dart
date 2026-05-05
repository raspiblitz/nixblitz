/// Pure procfs/sysfs parsing helpers.
///
/// All functions take raw string content (as returned by
/// `File.readAsString()`), return strongly-typed value objects, and
/// contain no I/O.  This makes them straightforward to unit-test.
library;

class CpuTimes {
  final int user, system, idle, total;
  const CpuTimes({
    required this.user,
    required this.system,
    required this.idle,
    required this.total,
  });
}

/// Parse the aggregate `cpu` line from `/proc/stat`.
///
/// Fields (0-indexed after the label):
///   0:user  1:nice  2:system  3:idle  4:iowait  5:irq  6:softirq
///   7:steal  8:guest  9:guestnice
CpuTimes parseProcStatCpu(String s) {
  final line = s
      .split('\n')
      .firstWhere((l) => l.startsWith('cpu '), orElse: () => '');
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length < 5) {
    return const CpuTimes(user: 0, system: 0, idle: 0, total: 0);
  }
  // parts[0] == 'cpu', numeric values start at index 1.
  int p(int i) => i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0;
  final user = p(1) + p(2); // user + nice (matches top, htop conventions)
  final system = p(3);
  final idle = p(4) + p(5); // idle + iowait
  final total = [
    for (var i = 1; i < parts.length; i++) p(i),
  ].fold(0, (a, b) => a + b);
  return CpuTimes(user: user, system: system, idle: idle, total: total);
}

/// Return CPU usage percentage between two consecutive [CpuTimes] snapshots.
double cpuPercent(CpuTimes a, CpuTimes b) {
  final dTotal = b.total - a.total;
  final dIdle = b.idle - a.idle;
  if (dTotal <= 0) return 0;
  return ((dTotal - dIdle) * 100.0) / dTotal;
}

class MemInfo {
  final int totalBytes, availableBytes, usedBytes;
  const MemInfo({
    required this.totalBytes,
    required this.availableBytes,
    required this.usedBytes,
  });
}

/// Parse `/proc/meminfo` content.
MemInfo parseProcMeminfo(String s) {
  int? read(String key) {
    for (final line in s.split('\n')) {
      if (line.startsWith('$key:')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          final n = int.tryParse(parts[1]) ?? 0;
          return n * 1024; // kB → bytes
        }
      }
    }
    return null;
  }

  final total = read('MemTotal') ?? 0;
  final avail = read('MemAvailable') ?? 0;
  return MemInfo(
    totalBytes: total,
    availableBytes: avail,
    usedBytes: total - avail,
  );
}

/// Parse `/proc/uptime` — returns uptime in whole seconds.
int parseProcUptime(String s) {
  final first = s.trim().split(RegExp(r'\s+')).firstOrNull;
  return double.tryParse(first ?? '')?.toInt() ?? 0;
}

/// Parse a sysfs temperature file (value in millidegrees Celsius).
///
/// Returns `null` if the content cannot be parsed.
double? parseTemperatureMilliC(String s) {
  final n = int.tryParse(s.trim());
  return n == null ? null : n / 1000.0;
}
