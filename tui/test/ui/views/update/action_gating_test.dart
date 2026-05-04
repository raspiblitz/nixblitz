import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/update/action_gating.dart';

const _tuiInputName = 'nixblitz';

InputAhead _input(String name) => InputAhead(
  name: name,
  currentRev: 'a' * 40,
  upstreamRev: 'b' * 40,
  url: '',
);

void main() {
  group('computeUpdateActionStates', () {
    test('no status file → both actions enabled with "no full check yet"', () {
      final states = computeUpdateActionStates(
        UpdateStatus.empty(),
        tuiInputName: _tuiInputName,
        liveInputsAhead: const [],
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
        liveInputsAhead: const [],
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
        liveInputsAhead: const [],
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
            inputsAhead: [_input('nixpkgs')],
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
          liveInputsAhead: [_input('nixpkgs')],
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
          inputsAhead: [_input('nixblitz')],
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        liveInputsAhead: [_input('nixblitz')],
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
          inputsAhead: [_input('nixpkgs')],
        ),
      );
      final states = computeUpdateActionStates(
        status,
        tuiInputName: _tuiInputName,
        liveInputsAhead: [_input('nixpkgs')],
        now: DateTime.utc(2026, 5, 4),
      );
      expect(states.tuiOnly.enabled, isFalse);
      expect(states.tuiOnly.subtitle, contains('up to date'));
    });

    test(
      'heavy.diffText non-empty but lock has caught up → entireSystem disabled',
      () {
        // The bug from real use: heavy ran 17h ago, found 1 change.
        // Operator ran Update since then (advancing the lock). Light
        // ran 12m ago and found nothing ahead. We should NOT keep
        // surfacing "1 change pending" — heavy is stale.
        final status = UpdateStatus(
          lightweight: LightCheck(
            checkedAt: DateTime.utc(2026, 5, 4, 12, 0),
            ok: true,
            inputsAhead: const [], // live lock matches upstream
          ),
          heavy: HeavyCheck(
            checkedAt: DateTime.utc(2026, 5, 3, 19, 0), // 17h before light
            ok: true,
            diffText: '[U.] foo 1.0 -> 1.1\n',
          ),
        );
        final states = computeUpdateActionStates(
          status,
          tuiInputName: _tuiInputName,
          liveInputsAhead: const [],
          now: DateTime.utc(2026, 5, 4, 12, 5),
        );
        expect(states.entireSystem.enabled, isFalse);
        expect(states.entireSystem.subtitle, contains('no changes'));
      },
    );
  });

  group('isHeavyDiffStale', () {
    test('returns false when heavy is null', () {
      expect(
        isHeavyDiffStale(UpdateStatus.empty(), liveInputsAhead: const []),
        isFalse,
      );
    });

    test('returns false when light is older than heavy', () {
      final status = UpdateStatus(
        lightweight: LightCheck(checkedAt: DateTime.utc(2026, 5, 1), ok: true),
        heavy: HeavyCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          diffText: '[U.] foo\n',
        ),
      );
      expect(isHeavyDiffStale(status, liveInputsAhead: const []), isFalse);
    });

    test('returns false when light is fresher but live ahead is non-empty', () {
      // Light says "still ahead" → heavy diff is still relevant.
      final status = UpdateStatus(
        lightweight: LightCheck(
          checkedAt: DateTime.utc(2026, 5, 4),
          ok: true,
          inputsAhead: [_input('nixpkgs')],
        ),
        heavy: HeavyCheck(
          checkedAt: DateTime.utc(2026, 5, 3),
          ok: true,
          diffText: '[U.] foo\n',
        ),
      );
      expect(
        isHeavyDiffStale(status, liveInputsAhead: [_input('nixpkgs')]),
        isFalse,
      );
    });

    test(
      'returns true when light is fresher AND live lock matches upstream',
      () {
        final status = UpdateStatus(
          lightweight: LightCheck(
            checkedAt: DateTime.utc(2026, 5, 4),
            ok: true,
          ),
          heavy: HeavyCheck(
            checkedAt: DateTime.utc(2026, 5, 3),
            ok: true,
            diffText: '[U.] foo\n',
          ),
        );
        expect(isHeavyDiffStale(status, liveInputsAhead: const []), isTrue);
      },
    );
  });
}
