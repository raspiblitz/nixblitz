import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('DeclaredBranch.fromJson', () {
    test('parses required ref + optional description + default', () {
      final b = DeclaredBranch.fromJson({
        'ref': 'main',
        'description': 'Production releases',
        'default': true,
      });
      expect(b.ref, 'main');
      expect(b.description, 'Production releases');
      expect(b.isDefault, isTrue);
    });

    test('description and default are optional', () {
      final b = DeclaredBranch.fromJson({'ref': 'next'});
      expect(b.ref, 'next');
      expect(b.description, isNull);
      expect(b.isDefault, isFalse);
    });

    test('throws when ref is missing', () {
      expect(
        () => DeclaredBranch.fromJson({'description': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when ref contains whitespace', () {
      expect(
        () => DeclaredBranch.fromJson({'ref': 'has space'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when ref contains ".."', () {
      expect(
        () => DeclaredBranch.fromJson({'ref': 'foo..bar'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when ref contains control characters', () {
      expect(
        () => DeclaredBranch.fromJson({'ref': 'foo\tbar'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DeclaredBranch.toJson', () {
    test('omits null description and false default', () {
      final j = DeclaredBranch(ref: 'main').toJson();
      expect(j, {'ref': 'main'});
    });

    test('includes description and default when set', () {
      final j = DeclaredBranch(
        ref: 'main',
        description: 'Production',
        isDefault: true,
      ).toJson();
      expect(j, {'ref': 'main', 'description': 'Production', 'default': true});
    });
  });
}
