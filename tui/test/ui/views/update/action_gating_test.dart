import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/update/action_gating.dart';

const _tuiInputName = 'nixblitz';

void main() {
  group('computeUpdateActionStates', () {
    test('no status file → both actions enabled with "no full check yet"', () {
      final states = computeUpdateActionStates(
        UpdateStatus.empty(),
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.tuiOnly.enabled, isTrue);
      expect(states.entireSystem.enabled, isTrue);
      expect(states.entireSystem.subtitle, contains('no full check yet'));
    });

    test('heavy.noChanges true → entireSystem disabled', () {
      final status = UpdateStatus(
        heavy: HeavyCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          noChanges: true,
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.entireSystem.enabled, isFalse);
      expect(states.entireSystem.subtitle, contains('no changes'));
    });

    test('heavy fresh + diff non-empty → entireSystem enabled with count', () {
      final status = UpdateStatus(
        heavy: HeavyCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          diffText: '[U.] foo 1.0 -> 1.1\n[A.] bar 1.0\n',
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.entireSystem.enabled, isTrue);
      expect(states.entireSystem.subtitle, contains('2 changes'));
    });

    test(
      'heavy stale + light has hits → entireSystem enabled with stale hint',
      () {
        final status = UpdateStatus(
          lightweight: LightCheck(
            checkedAt: DateTime.utc(2026, 5, 4),
            ok: true,
            inputsAhead: [
              InputAhead(
                name: 'nixpkgs',
                currentRev: 'a' * 40,
                upstreamRev: 'b' * 40,
                url: '',
              ),
            ],
          ),
          heavy: HeavyCheck(
            checkedAt: DateTime.utc(2026, 4, 1), // ~30 days old
            ok: true,
            noChanges: true,
          ),
        );
        final states = computeUpdateActionStates(
          status,
          tuiInputName: _tuiInputName,
          now: DateTime.utc(2026, 5, 4),
        );
        expect(states.entireSystem.enabled, isTrue);
        expect(states.entireSystem.subtitle, contains('heavy check stale'));
      },
    );

    test('TUI input ahead → tuiOnly enabled', () {
      final status = UpdateStatus(
        lightweight: LightCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          inputsAhead: [
            InputAhead(
              name: 'nixblitz',
              currentRev: 'a' * 40,
              upstreamRev: 'b' * 40,
              url: '',
            ),
          ],
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.tuiOnly.enabled, isTrue);
      expect(states.tuiOnly.subtitle, contains('ahead'));
    });

    test('TUI input not ahead → tuiOnly disabled', () {
      final status = UpdateStatus(
        lightweight: LightCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          inputsAhead: [
            InputAhead(
              name: 'nixpkgs',
              currentRev: 'a' * 40,
              upstreamRev: 'b' * 40,
              url: '',
            ),
          ],
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.tuiOnly.enabled, isFalse);
      expect(states.tuiOnly.subtitle, contains('up to date'));
    });
  });
}
