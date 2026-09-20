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

  test('parses debit-account available balance from a screenshot', () {
    final draft = parseStatementText(
      fileName: 'bank-a-debit.png',
      text: '''Banco Popular debit card ending 4412
Cuenta de ahorro
Saldo disponible DOP 125,000.50''',
    );

    expect(draft.accountType, AccountType.debit);
    expect(draft.lastFour, '4412');
    expect(draft.availableBalanceDop, 125000.50);
  });

  test('keeps card and Credimas limits separate from debt', () {
    final draft = StatementDraft.fromVision(
      fileName: 'banreservas-mastercard.png',
      values: const {
        'bankName': 'Banreservas',
        'accountName': 'Mastercard',
        'lastFour': '3103',
        'associatedDebitCardLastFours': [],
        'accountType': 'credit',
        'availableBalanceDop': 35695.13,
        'availableBalanceUsd': null,
        'creditLimitDop': 39000,
        'creditLimitUsd': null,
        'installmentCreditLimitDop': 39000,
        'installmentCreditLimitUsd': null,
        'currentTotalDop': 3304.87,
        'currentTotalUsd': null,
        'statementBalanceDop': null,
        'minimumDueDop': null,
        'statementBalanceUsd': null,
        'minimumDueUsd': null,
        'installmentBalance': null,
        'installmentMonthlyPayment': null,
        'cutoffDate': '2026-08-26',
        'dueDate': '2026-09-17',
        'rawText':
            'Credito disponible 35,695.13. Limite 39,000. Credimas disponible 39,000.',
      },
    );

    expect(draft.currentTotalDop, 3304.87);
    expect(draft.creditLimitDop, 39000);
    expect(draft.installmentCreditLimitDop, 39000);
    expect(draft.installmentBalance, isNull);
  });

  test('recovers limits from an older AI transcription', () {
    final draft = StatementDraft.fromVision(
      fileName: 'banreservas-mastercard.png',
      values: const {
        'bankName': 'Banreservas',
        'accountName': 'Mastercard',
        'lastFour': '3103',
        'associatedDebitCardLastFours': [],
        'accountType': 'credit',
        'availableBalanceDop': null,
        'availableBalanceUsd': null,
        'currentTotalDop': null,
        'currentTotalUsd': null,
        'statementBalanceDop': null,
        'minimumDueDop': null,
        'statementBalanceUsd': null,
        'minimumDueUsd': null,
        'installmentBalance': null,
        'installmentMonthlyPayment': null,
        'cutoffDate': null,
        'dueDate': null,
        'rawText':
            'Crédito disponible DOP 35,695.13. Límite DOP 39,000.00. Credimás Disponible DOP 39,000.00.',
      },
    );

    expect(draft.availableBalanceDop, 35695.13);
    expect(draft.creditLimitDop, 39000);
    expect(draft.installmentCreditLimitDop, 39000);
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
