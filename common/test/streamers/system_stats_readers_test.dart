import 'package:common/src/streamers/system_stats_readers.dart';
import 'package:test/test.dart';

void main() {
  group('parseProcStatCpu', () {
    test('extracts the aggregate cpu line', () {
      const sample = '''
cpu  100 50 200 10000 0 0 0 0 0 0
cpu0 50 25 100 5000 0 0 0 0 0 0
intr 12345
''';
      final s = parseProcStatCpu(sample);
      expect(s.user, 150); // user (100) + nice (50)
      expect(s.idle, 10000);
      expect(s.total, 100 + 50 + 200 + 10000);
    });

    test('iowait is folded into idle', () {
      const sample = '''
cpu  100 50 200 10000 500 0 0 0 0 0
''';
      final s = parseProcStatCpu(sample);
      expect(s.idle, 10500); // idle (10000) + iowait (500)
    });
  });

  group('cpuPercent', () {
    test('idle delta of 90 over total 100 → 10%', () {
      final a = CpuTimes(user: 0, system: 0, idle: 0, total: 0);
      final b = CpuTimes(user: 5, system: 5, idle: 90, total: 100);
      expect(cpuPercent(a, b), closeTo(10.0, 0.01));
    });

    test('zero total delta → 0%', () {
      final a = CpuTimes(user: 1, system: 1, idle: 1, total: 100);
      final b = CpuTimes(user: 1, system: 1, idle: 1, total: 100);
      expect(cpuPercent(a, b), 0);
    });
  });

  group('parseProcMeminfo', () {
    test('extracts MemTotal / MemAvailable', () {
      const sample = '''
MemTotal:        8192000 kB
MemFree:         1024000 kB
MemAvailable:    4096000 kB
Buffers:          512000 kB
''';
      final m = parseProcMeminfo(sample);
      expect(m.totalBytes, 8192000 * 1024);
      expect(m.availableBytes, 4096000 * 1024);
      expect(m.usedBytes, (8192000 - 4096000) * 1024);
    });

    test('returns zeros when fields missing', () {
      final m = parseProcMeminfo('');
      expect(m.totalBytes, 0);
      expect(m.availableBytes, 0);
    });
  });

  group('parseProcUptime', () {
    test('first field as seconds', () {
      expect(parseProcUptime('12345.67 9876.54'), 12345);
    });

    test('returns 0 on empty input', () {
      expect(parseProcUptime(''), 0);
    });
  });

  group('parseTemperatureMilliC', () {
    test('45000 → 45.0 C', () {
      expect(parseTemperatureMilliC('45000\n'), closeTo(45.0, 0.01));
    });

    test('returns null on non-numeric input', () {
      expect(parseTemperatureMilliC('not-a-number'), isNull);
    });
  });
}
