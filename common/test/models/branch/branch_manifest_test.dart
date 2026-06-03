import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('BranchManifest.fromJson', () {
    test('parses a well-formed manifest', () {
      final m = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'description': 'Prod', 'default': true},
        'next': {'ref': 'next', 'description': 'Pre-release'},
      });
      expect(m.branches.keys, containsAll(['stable', 'next']));
      expect(m.branches['stable']!.ref, 'main');
      expect(m.defaultKey, 'stable');
    });

    test('rejects empty map', () {
      expect(
        () => BranchManifest.fromJson(const {}),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects multiple entries with default:true', () {
      expect(
        () => BranchManifest.fromJson({
          'a': {'ref': 'main', 'default': true},
          'b': {'ref': 'next', 'default': true},
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('exactly one'),
          ),
        ),
      );
    });

    test('allows zero entries with default:true (defaultKey is null)', () {
      final m = BranchManifest.fromJson({
        'a': {'ref': 'main'},
        'b': {'ref': 'next'},
      });
      expect(m.defaultKey, isNull);
    });

    test('toJson roundtrips', () {
      final m = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
        'next': {'ref': 'next', 'description': 'Pre-release'},
      });
      final back = BranchManifest.fromJson(m.toJson());
      expect(back.branches['stable']!.ref, 'main');
      expect(back.branches['next']!.description, 'Pre-release');
      expect(back.defaultKey, 'stable');
    });
  });
}
