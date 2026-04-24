import 'package:test/test.dart';

import 'package:common/src/models/rebuild_outcome.dart';

void main() {
  group('RebuildResult.classify', () {
    test('exit 0 → success', () {
      final r = RebuildResult.classify(const ['whatever'], 0);
      expect(r.outcome, RebuildOutcome.success);
      expect(r.failedUnits, isEmpty);
    });

    test('activation ran + units failed → partial', () {
      final lines = const [
        'building the system configuration...',
        'activating the configuration...',
        'setting up /etc...',
        'reloading user units for admin...',
        'warning: the following units failed: tailscale-autoconnect.service',
        'some stderr noise',
      ];
      final r = RebuildResult.classify(lines, 4);
      expect(r.outcome, RebuildOutcome.partial);
      expect(r.failedUnits, ['tailscale-autoconnect.service']);
    });

    test('multiple failed units parsed into list', () {
      final lines = const [
        'activating the configuration...',
        'warning: the following units failed: a.service b.service c.service',
      ];
      final r = RebuildResult.classify(lines, 4);
      expect(r.outcome, RebuildOutcome.partial);
      expect(r.failedUnits, ['a.service', 'b.service', 'c.service']);
    });

    test('exit nonzero with no activation marker → failure', () {
      final lines = const [
        'building the system configuration...',
        'error: attribute missing',
      ];
      final r = RebuildResult.classify(lines, 1);
      expect(r.outcome, RebuildOutcome.failure);
      expect(r.failedUnits, isEmpty);
    });

    test('activation ran but no concrete failed-unit marker → failure', () {
      // e.g. an activation script itself crashed — nixos-rebuild
      // doesn't print the "following units failed" line in that
      // case. Treat as hard failure.
      final lines = const [
        'activating the configuration...',
        'setting up /etc...',
        'activation script failed with status 1',
      ];
      final r = RebuildResult.classify(lines, 1);
      expect(r.outcome, RebuildOutcome.failure);
      expect(r.failedUnits, isEmpty);
    });

    test('empty output + exit 0 → success', () {
      final r = RebuildResult.classify(const [], 0);
      expect(r.outcome, RebuildOutcome.success);
    });
  });
}
