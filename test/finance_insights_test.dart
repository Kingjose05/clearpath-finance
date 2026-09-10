import 'package:card_debt_planner/models.dart';
import 'package:card_debt_planner/services/finance_insights.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('analytics separates purchases, cash withdrawals, and income', () {
    final now = DateTime(2026, 9, 10);
    final analytics = buildAnalytics([
      Purchase(
        id: 'food',
        cardId: 'debit',
        merchant: 'Cafe',
        amount: 500,
        purchasedAt: now,
        source: PurchaseSource.email,
        category: SpendingCategory.food,
      ),
      Purchase(
        id: 'cash',
        cardId: 'debit',
        merchant: 'ATM',
        amount: 2000,
        purchasedAt: now,
        source: PurchaseSource.email,
        kind: TransactionKind.withdrawal,
        category: SpendingCategory.cash,
      ),
      Purchase(
        id: 'salary',
        cardId: 'debit',
        merchant: 'Salary',
        amount: 50000,
        purchasedAt: now,
        source: PurchaseSource.email,
        kind: TransactionKind.income,
        category: SpendingCategory.income,
      ),
    ], now: now);
    expect(analytics.spending, 2500);
    expect(analytics.withdrawals, 2000);
    expect(analytics.income, 50000);
  });

  test('payoff strategy prioritizes the highest APR after minimums', () {
    const cards = [
      CreditCard(
        id: 'low',
        name: 'Low',
        lastFour: '1111',
        balance: 20000,
        creditLimit: 50000,
        apr: 18,
        cutoffDay: 10,
        dueDay: 5,
        minimumDue: 1000,
        accentColor: 0xFF000000,
      ),
      CreditCard(
        id: 'high',
        name: 'High',
        lastFour: '2222',
        balance: 20000,
        creditLimit: 50000,
        apr: 36,
        cutoffDay: 15,
        dueDay: 12,
        minimumDue: 1000,
        accentColor: 0xFF000000,
      ),
    ];
    final plan = buildDebtStrategy(
      cards: cards,
      loans: const [],
      monthlySalary: 60000,
      essentialExpenses: 30000,
      targetMonths: 6,
    );
    final high = plan.allocations.firstWhere((item) => item.id == 'high');
    final low = plan.allocations.firstWhere((item) => item.id == 'low');
    expect(high.amount, greaterThan(low.amount));
    expect(plan.monthlyPayment, lessThanOrEqualTo(30000));
  });
}
