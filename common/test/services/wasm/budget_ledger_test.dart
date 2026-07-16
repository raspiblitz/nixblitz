import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String ledgerPath;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ledger_test_');
    ledgerPath = '${tmp.path}/budget.json';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final t0 = DateTime.utc(2026, 7, 16, 12, 0, 0);

  test('empty ledger spends 0', () {
    expect(BudgetLedger(ledgerPath).spentWithin(t0), 0);
  });

  test('reserve then settle records actual spend', () {
    final l = BudgetLedger(ledgerPath);
    final id = l.reserve(t0, 'sendtoaddress', 1000);
    expect(l.spentWithin(t0), 1000); // reservation counts immediately
    l.settle(id, 850);
    expect(l.spentWithin(t0), 850);
  });

  test('cancel removes a reservation', () {
    final l = BudgetLedger(ledgerPath);
    final id = l.reserve(t0, 'send', 500);
    l.cancel(id);
    expect(l.spentWithin(t0), 0);
  });

  test('entries older than 24h are excluded from the window', () {
    final l = BudgetLedger(ledgerPath);
    l.reserve(t0, 'send', 700);
    final later = t0.add(const Duration(hours: 25));
    expect(l.spentWithin(later), 0);
  });

  test('reservation survives reload (fail-closed on crash)', () {
    BudgetLedger(ledgerPath).reserve(t0, 'send', 300);
    // New instance = simulated process restart; reservation persisted.
    expect(BudgetLedger(ledgerPath).spentWithin(t0), 300);
  });

  test('write failure throws BudgetLedgerException', () {
    // A path whose parent does not exist and cannot be created.
    final l = BudgetLedger('/proc/nonexistent/budget.json');
    expect(
      () => l.reserve(t0, 'send', 1),
      throwsA(isA<BudgetLedgerException>()),
    );
  });
}
