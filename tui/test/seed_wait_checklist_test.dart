import 'package:common/common.dart';
import 'package:tui/src/ui/widgets/seed_wait_checklist.dart';
import 'package:test/test.dart';

void main() {
  group('seedWaitChecklistRows', () {
    test('startingService: row 0 current, rest pending', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(phase: SeedWaitPhase.startingService),
      );
      expect(rows, hasLength(3));
      expect(rows[0].isCurrent, isTrue);
      expect(rows[0].glyph, '⠿'); // spinner placeholder glyph
      expect(rows[1].glyph, '○');
      expect(rows[2].glyph, '○');
      expect(rows[2].label, contains('sudo'));
    });

    test('waitingForSeedFile: row 0 done, row 1 current', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(
          phase: SeedWaitPhase.waitingForSeedFile,
          lndState: ServiceState.running,
        ),
      );
      expect(rows[0].glyph, '✓');
      expect(rows[1].isCurrent, isTrue);
      expect(rows[2].glyph, '○');
    });

    test('done: all rows ✓', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(phase: SeedWaitPhase.done),
      );
      expect(rows.map((r) => r.glyph), everyElement('✓'));
    });

    test('failure marks the phase row ✗ and keeps earlier rows ✓', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(
          phase: SeedWaitPhase.readingSeed,
          error: 'Could not read seed file (exit 1): denied',
        ),
      );
      expect(rows[0].glyph, '✓');
      expect(rows[1].glyph, '✓');
      expect(rows[2].glyph, '✗');
      expect(rows[2].isFailed, isTrue);
    });

    test('failure during startingService marks row 0 ✗', () {
      final rows = seedWaitChecklistRows(
        const SeedWaitStatus(
          phase: SeedWaitPhase.startingService,
          lndState: ServiceState.failed,
          error: 'lnd service failed to start — press [l] for the LND log.',
        ),
      );
      expect(rows[0].glyph, '✗');
      expect(rows[0].isFailed, isTrue);
    });
  });
}
