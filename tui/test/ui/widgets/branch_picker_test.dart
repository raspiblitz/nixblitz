import 'package:common/common.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/widgets/branch_picker.dart';

void main() {
  group('branchPickerRows', () {
    test('renders declared branches with refs and descriptions', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'description': 'Prod', 'default': true},
        'next': {'ref': 'develop', 'description': 'Beta'},
      });
      final rows = branchPickerRows(
        manifest: manifest,
        currentValue: 'stable',
        selectedIndex: 0,
      );
      final rendered = rows.join('\n');
      expect(rendered, contains('stable'));
      expect(rendered, contains('next'));
      expect(rendered, contains('main')); // ref
      expect(rendered, contains('develop')); // ref
      expect(rendered, contains('Prod')); // description
      expect(rendered, contains('Beta'));
      expect(rendered, contains('Custom branch'));
    });

    test('null manifest renders only Custom branch row', () {
      final rows = branchPickerRows(
        manifest: null,
        currentValue: null,
        selectedIndex: 0,
      );
      final rendered = rows.join('\n');
      expect(rendered, contains('Custom branch'));
      expect(rendered, isNot(contains('stable')));
      // With a null manifest, the only navigable row is Custom branch.
      expect(branchPickerRowCount(manifest: null), 1);
    });

    test('current selection highlighted with cursor prefix', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
        'next': {'ref': 'develop'},
      });
      // selectedIndex 1 → "next" row should carry the cursor prefix
      final rows = branchPickerRows(
        manifest: manifest,
        currentValue: 'stable',
        selectedIndex: 1,
      );
      // The cursor-marked row starts with '> '.
      final cursorRow = rows.firstWhere((r) => r.startsWith('> '));
      expect(cursorRow, contains('next'));
      // The non-selected current value still carries the "(current)"
      // suffix so the operator can see what they're on.
      final stableRow = rows.firstWhere((r) => r.contains('stable'));
      expect(stableRow, contains('(current)'));
    });

    test('current value "custom:<ref>" highlights the Custom branch row', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
      });
      // initialSelectedIndex on a custom: value should land on the
      // Custom branch row (the last index).
      final idx = initialSelectedIndex(
        manifest: manifest,
        currentValue: 'custom:my-feature',
      );
      // Declared rows + Custom branch row → Custom is at index
      // branches.length.
      expect(idx, 1);
      final rows = branchPickerRows(
        manifest: manifest,
        currentValue: 'custom:my-feature',
        selectedIndex: idx,
      );
      final customRow = rows.firstWhere((r) => r.contains('Custom branch'));
      expect(customRow, contains('(current)'));
    });

    test('initialSelectedIndex picks declared key row', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
        'next': {'ref': 'develop'},
      });
      expect(initialSelectedIndex(manifest: manifest, currentValue: 'next'), 1);
      expect(
        initialSelectedIndex(manifest: manifest, currentValue: 'stable'),
        0,
      );
    });

    test('initialSelectedIndex defaults to 0 for unknown / null value', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
      });
      expect(initialSelectedIndex(manifest: manifest, currentValue: null), 0);
      expect(
        initialSelectedIndex(manifest: manifest, currentValue: 'unknown'),
        0,
      );
    });
  });

  group('branchPickerChoice', () {
    test('selecting a declared row resolves to its key (not ref)', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
        'next': {'ref': 'develop'},
      });
      // index 0 → 'stable' (not 'main')
      final choice = branchPickerChoice(manifest: manifest, selectedIndex: 0);
      expect(choice, isA<DeclaredChoice>());
      expect((choice as DeclaredChoice).key, 'stable');
    });

    test('selecting the Custom branch row resolves to CustomChoice', () {
      final manifest = BranchManifest.fromJson({
        'stable': {'ref': 'main', 'default': true},
      });
      // Custom row is at index = branches.length = 1
      final choice = branchPickerChoice(manifest: manifest, selectedIndex: 1);
      expect(choice, isA<CustomChoice>());
    });

    test('null manifest: index 0 is always the Custom branch row', () {
      final choice = branchPickerChoice(manifest: null, selectedIndex: 0);
      expect(choice, isA<CustomChoice>());
    });

    test('encodeCustomBranch wraps ref in custom: prefix', () {
      expect(encodeCustomBranch('my-feature'), 'custom:my-feature');
      expect(encodeCustomBranch('  spaced  '), 'custom:spaced');
    });

    test('prefilledCustomRef strips custom: prefix from currentValue', () {
      expect(prefilledCustomRef('custom:my-feature'), 'my-feature');
      // Non-custom values produce an empty buffer.
      expect(prefilledCustomRef('stable'), '');
      expect(prefilledCustomRef(null), '');
    });
  });
}
