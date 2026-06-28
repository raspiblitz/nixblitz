import 'package:test/test.dart';
import 'package:common/src/models/sbom_change.dart';
import 'package:common/src/models/update_status.dart';

void main() {
  group('SbomChange JSON', () {
    test('round-trips a changed entry', () {
      const c = SbomChange(
        name: 'foo',
        from: '1.2',
        to: '1.3',
        kind: SbomChangeKind.changed,
      );
      final back = SbomChange.fromJson(c.toJson());
      expect(back.name, 'foo');
      expect(back.from, '1.2');
      expect(back.to, '1.3');
      expect(back.kind, SbomChangeKind.changed);
    });

    test('round-trips added/removed (null sides)', () {
      const added = SbomChange(
        name: 'bar',
        from: null,
        to: '0.9',
        kind: SbomChangeKind.added,
      );
      const removed = SbomChange(
        name: 'baz',
        from: '2.0',
        to: null,
        kind: SbomChangeKind.removed,
      );
      expect(SbomChange.fromJson(added.toJson()).kind, SbomChangeKind.added);
      expect(SbomChange.fromJson(added.toJson()).to, '0.9');
      expect(
        SbomChange.fromJson(removed.toJson()).kind,
        SbomChangeKind.removed,
      );
      expect(SbomChange.fromJson(removed.toJson()).from, '2.0');
    });
  });

  group('CheckResult.sbomChanges', () {
    test('defaults to empty + round-trips', () {
      final r = CheckResult(
        checkedAt: DateTime(2026, 1, 1),
        ok: true,
        sbomChanges: const [
          SbomChange(
            name: 'foo',
            from: '1.2',
            to: '1.3',
            kind: SbomChangeKind.changed,
          ),
        ],
      );
      expect(
        CheckResult(checkedAt: DateTime(2026, 1, 1), ok: true).sbomChanges,
        isEmpty,
      );
      final back = CheckResult.fromJson(r.toJson());
      expect(back.sbomChanges, hasLength(1));
      expect(back.sbomChanges.first.to, '1.3');
    });
  });
}
