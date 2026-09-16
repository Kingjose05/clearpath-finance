import 'package:card_debt_planner/models.dart';
import 'package:card_debt_planner/services/payment_planner.dart';
import 'package:card_debt_planner/services/statement_ocr.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a bilingual APAP-style statement into separate fields', () {
    final draft = parseStatementText(
      fileName: 'apap-2552.png',
      text: '''APAP card ending 2552
Current total DOP 40,495.15
Statement balance DOP 32,933.71
Minimum payment DOP 6,414.67
USD statement 37.61 USD minimum 10.00
Cutoff Date Aug 21, 2026 Due Date Sep 12, 2026
Mas Limite installment amount due 4,708.67''',
    );

    expect(draft.bankName, 'APAP');
    expect(draft.lastFour, '2552');
    expect(draft.currentTotalDop, 40495.15);
    expect(draft.statementBalanceDop, 32933.71);
    expect(draft.minimumDueDop, 6414.67);
    expect(draft.statementBalanceUsd, 37.61);
    expect(draft.minimumDueUsd, 10.00);
    expect(draft.installmentMonthlyPayment, 4708.67);
    expect(draft.cutoffDate, DateTime(2026, 8, 21));
    expect(draft.dueDate, DateTime(2026, 9, 12));
  });

  test('allocates minimums across cards and loans before APR avalanche', () {
    final cards = [
      CreditCard(
        id: 'card',
        name: 'Card',
        lastFour: '2552',
        balance: 10000,
        creditLimit: 20000,
        apr: 36,
        cutoffDay: 21,
        dueDay: 12,
        minimumDue: 1000,
        accentColor: 0,
        calibratedDueDate: DateTime(2026, 9, 12),
      ),
    ];
    final loans = [
      Loan(
        id: 'loan',
        name: 'Personal loan',
        balance: 100000,
        apr: 18,
        minimumPayment: 6039.29,
        dueDay: 12,
      ),
    ];
    final plan = const PaymentPlanner().buildPlan(
      cards: cards,
      loans: loans,
      paycheckAmount: 8000,
      exchangeRateDopPerUsd: 60,
      now: DateTime(2026, 9, 16),
    );

    expect(plan.coversMinimums, isTrue);
    expect(plan.allocationForCard('card')!.totalAmount, 1960.71);
    expect(plan.allocationForLoan('loan')!.totalAmount, 6039.29);
    expect(plan.allocationForCard('card')!.daysUntilDue, lessThan(0));
  });
}
