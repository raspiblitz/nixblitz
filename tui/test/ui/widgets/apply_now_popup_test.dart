import 'package:test/test.dart';
import 'package:tui/src/ui/widgets/apply_now_popup.dart';

void main() {
  group('applyNowPendingSummary', () {
    test('one change is singular', () {
      expect(applyNowPendingSummary(1), '1 pending change.');
    });

    test('multiple changes are plural with the count', () {
      expect(applyNowPendingSummary(3), '3 pending changes.');
    });

    test('zero / negative falls back to a generic line', () {
      expect(applyNowPendingSummary(0), 'You have pending changes.');
      expect(applyNowPendingSummary(-1), 'You have pending changes.');
    });
  });
}
