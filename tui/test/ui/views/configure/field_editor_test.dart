import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/views/configure/field_editor.dart';

void main() {
  group('formatFieldValue', () {
    test('BoolField on/off', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: false);
      expect(formatFieldValue(f, true), 'on');
      expect(formatFieldValue(f, false), 'off');
      // null → default (false)
      expect(formatFieldValue(f, null), 'off');
    });

    test('BoolField with default true falls back correctly', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: true);
      expect(formatFieldValue(f, null), 'on');
    });

    test('StringField empty + populated', () {
      const f = StringField(name: 'x', label: 'X', defaultValue: '');
      expect(formatFieldValue(f, 'hello'), 'hello');
      expect(formatFieldValue(f, null), '');
    });

    test('StringField non-empty default', () {
      const f = StringField(name: 'x', label: 'X', defaultValue: 'mynode');
      expect(formatFieldValue(f, null), 'mynode');
      expect(formatFieldValue(f, 'other'), 'other');
    });

    test('IntField stringifies', () {
      const f = IntField(name: 'x', label: 'X', defaultValue: 0);
      expect(formatFieldValue(f, 42), '42');
      expect(formatFieldValue(f, null), '0');
    });

    test('IntField with non-zero default', () {
      const f = IntField(name: 'x', label: 'X', defaultValue: 550);
      expect(formatFieldValue(f, null), '550');
      expect(formatFieldValue(f, 1024), '1024');
    });

    test('EnumField returns the choice', () {
      const f = EnumField(
        name: 'x',
        label: 'X',
        defaultValue: 'a',
        choices: ['a', 'b', 'c'],
      );
      expect(formatFieldValue(f, 'b'), 'b');
      expect(formatFieldValue(f, null), 'a');
    });
  });

  group('fieldRequiresEditor', () {
    test('BoolField does not require overlay', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: false);
      expect(fieldRequiresEditor(f), isFalse);
    });

    test('StringField requires overlay', () {
      const f = StringField(name: 'x', label: 'X', defaultValue: '');
      expect(fieldRequiresEditor(f), isTrue);
    });

    test('IntField requires overlay', () {
      const f = IntField(name: 'x', label: 'X', defaultValue: 0);
      expect(fieldRequiresEditor(f), isTrue);
    });

    test('EnumField does not require overlay (cycled in-place)', () {
      const f = EnumField(
        name: 'x',
        label: 'X',
        defaultValue: 'a',
        choices: ['a', 'b'],
      );
      expect(fieldRequiresEditor(f), isFalse);
    });
  });

  group('cycleFieldValue', () {
    test('BoolField toggles true→false', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: false);
      expect(cycleFieldValue(f, true), isFalse);
    });

    test('BoolField toggles false→true', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: false);
      expect(cycleFieldValue(f, false), isTrue);
    });

    test('BoolField null falls back to default then toggles', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: false);
      // null treated as false → cycles to true
      expect(cycleFieldValue(f, null), isTrue);
    });

    test('BoolField null with default true cycles to false', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: true);
      expect(cycleFieldValue(f, null), isFalse);
    });

    test('EnumField cycles forward through choices', () {
      const f = EnumField(
        name: 'x',
        label: 'X',
        defaultValue: 'a',
        choices: ['a', 'b', 'c'],
      );
      expect(cycleFieldValue(f, 'a'), 'b');
      expect(cycleFieldValue(f, 'b'), 'c');
      expect(cycleFieldValue(f, 'c'), 'a'); // wraps
    });

    test('EnumField null cycles from start', () {
      const f = EnumField(
        name: 'x',
        label: 'X',
        defaultValue: 'a',
        choices: ['a', 'b', 'c'],
      );
      // null → idx -1 → (-1 + 1) % 3 = 0 → 'a'
      expect(cycleFieldValue(f, null), 'a');
    });

    test('StringField throws ArgumentError', () {
      const f = StringField(name: 'x', label: 'X', defaultValue: '');
      expect(() => cycleFieldValue(f, 'v'), throwsArgumentError);
    });

    test('IntField throws ArgumentError', () {
      const f = IntField(name: 'x', label: 'X', defaultValue: 0);
      expect(() => cycleFieldValue(f, 1), throwsArgumentError);
    });
  });

  group('buildFieldEditor', () {
    test('BoolField throws ArgumentError', () {
      const f = BoolField(name: 'x', label: 'X', defaultValue: false);
      expect(
        () => buildFieldEditor(
          field: f,
          currentValue: false,
          onSubmit: (_) {},
          onCancel: () {},
        ),
        throwsArgumentError,
      );
    });

    test('EnumField throws ArgumentError', () {
      const f = EnumField(
        name: 'x',
        label: 'X',
        defaultValue: 'a',
        choices: ['a', 'b'],
      );
      expect(
        () => buildFieldEditor(
          field: f,
          currentValue: 'a',
          onSubmit: (_) {},
          onCancel: () {},
        ),
        throwsArgumentError,
      );
    });

    test('StringField returns non-null Component', () {
      const f = StringField(name: 'x', label: 'X', defaultValue: '');
      final w = buildFieldEditor(
        field: f,
        currentValue: 'hello',
        onSubmit: (_) {},
        onCancel: () {},
      );
      expect(w, isNotNull);
    });

    test('IntField returns non-null Component', () {
      const f = IntField(name: 'x', label: 'X', defaultValue: 0);
      final w = buildFieldEditor(
        field: f,
        currentValue: 42,
        onSubmit: (_) {},
        onCancel: () {},
      );
      expect(w, isNotNull);
    });

    test('StringField null currentValue uses defaultValue', () {
      const f = StringField(name: 'x', label: 'X', defaultValue: 'default');
      // Should construct without error when currentValue is null
      final w = buildFieldEditor(
        field: f,
        currentValue: null,
        onSubmit: (_) {},
        onCancel: () {},
      );
      expect(w, isNotNull);
    });

    test('IntField null currentValue uses defaultValue', () {
      const f = IntField(name: 'x', label: 'X', defaultValue: 100);
      final w = buildFieldEditor(
        field: f,
        currentValue: null,
        onSubmit: (_) {},
        onCancel: () {},
      );
      expect(w, isNotNull);
    });
  });
}
