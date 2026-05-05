import 'package:common/src/services/dashboard/dsl/binding_resolver.dart';
import 'package:test/test.dart';

void main() {
  const data = {
    'blocks': 871234,
    'verification_progress': 0.99987,
    'size_on_disk': 543210000000,
    'uptime_sec': 90061,
    'pubkey': '03fffeeeddddccccbbbbaaaa999988887777666655554444333322221111',
    'sync_state': 'syncing',
    'sync_pct': 87,
  };

  group('resolveValue', () {
    test('literal passthrough', () {
      expect(resolveValue('hello', data), 'hello');
      expect(resolveValue(42, data), 42);
    });

    test('\$data with hit', () {
      expect(resolveValue({'\$data': 'blocks'}, data), 871234);
    });

    test('\$data with miss yields placeholder', () {
      expect(resolveValue({'\$data': 'nope'}, data), '—');
    });

    test('\$bytes formats human-readable', () {
      expect(resolveValue({'\$bytes': 'size_on_disk'}, data), '543.2 GB');
    });

    test('\$duration formats h/m/s', () {
      expect(resolveValue({'\$duration': 'uptime_sec'}, data), '1d 1h 1m');
    });

    test('\$pct formats 0..1 → percent', () {
      expect(resolveValue({'\$pct': 'verification_progress'}, data), '99.99%');
    });

    test('\$truncate', () {
      expect(
        resolveValue({
          '\$truncate': {'key': 'pubkey', 'len': 12},
        }, data),
        '03fffeeeddd…',
      );
    });

    test('\$format template', () {
      expect(
        resolveValue({'\$format': '{blocks} of {sync_pct}%'}, data),
        '871234 of 87%',
      );
    });

    test('\$status selects matching case', () {
      final result = resolveValue({
        '\$status': {
          '\$on': 'sync_state',
          'syncing': {'text': 'syncing', 'color': 'warn'},
          'synced': {'text': 'synced', 'color': 'ok'},
        },
      }, data);
      expect(result, {'text': 'syncing', 'color': 'warn'});
    });

    test('\$status falls through to null when no case matches', () {
      final result = resolveValue({
        '\$status': {
          '\$on': 'sync_state',
          'unknown_value': {'text': 'x'},
        },
      }, data);
      expect(result, isNull);
    });

    test('unknown directive yields placeholder', () {
      expect(resolveValue({'\$weird': 'x'}, data), '—');
    });

    test('\$bytes with non-numeric data yields placeholder', () {
      expect(resolveValue({'\$bytes': 'pubkey'}, data), '—');
    });

    test('\$duration with non-numeric data yields placeholder', () {
      expect(resolveValue({'\$duration': 'pubkey'}, data), '—');
    });

    test('\$pct with non-numeric data yields placeholder', () {
      expect(resolveValue({'\$pct': 'pubkey'}, data), '—');
    });

    test('\$format with missing key shows placeholder for that key', () {
      expect(
        resolveValue({'\$format': '{blocks} {missing}'}, data),
        '871234 —',
      );
    });

    test('\$truncate when string is shorter than len returns string as-is', () {
      const shortData = {'name': 'short'};
      expect(
        resolveValue({
          '\$truncate': {'key': 'name', 'len': 12},
        }, shortData),
        'short',
      );
    });

    test('\$data with non-string arg yields placeholder (does not throw)', () {
      expect(resolveValue({'\$data': 42}, data), '—');
    });

    test('\$truncate with non-Map arg yields placeholder', () {
      expect(resolveValue({'\$truncate': 'wrong'}, data), '—');
    });

    test('\$status with malformed spec yields placeholder', () {
      expect(resolveValue({'\$status': 'not-a-map'}, data), '—');
    });
  });

  group('formatBytes', () {
    test('handles 0 / B / KB / MB / GB / TB', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(1500000), '1.5 MB');
      expect(formatBytes(2500000000), '2.5 GB');
      expect(formatBytes(3500000000000), '3.5 TB');
    });
  });

  group('formatDuration', () {
    test('seconds → days/hours/minutes', () {
      expect(formatDuration(0), '0m');
      expect(formatDuration(45), '0m'); // < 1m → 0m
      expect(formatDuration(90), '1m');
      expect(formatDuration(3700), '1h 1m');
      expect(formatDuration(90061), '1d 1h 1m');
    });
  });
}
