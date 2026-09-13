import 'package:card_debt_planner/models.dart';
import 'package:card_debt_planner/services/payoff_calendar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calendar protects minimums and prioritizes highest APR', () {
    const cards = [
      CreditCard(
        id: 'low',
        name: 'Low APR',
        lastFour: '1111',
        balance: 10000,
        creditLimit: 20000,
        apr: 12,
        cutoffDay: 10,
        dueDay: 5,
        minimumDue: 500,
        accentColor: 0,
      ),
      CreditCard(
        id: 'high',
        name: 'High APR',
        lastFour: '2222',
        balance: 10000,
        creditLimit: 20000,
        apr: 36,
        cutoffDay: 15,
        dueDay: 12,
        minimumDue: 500,
        accentColor: 0,
      ),
    ];
    final schedule = buildPayoffSchedule(
      cards: cards,
      loans: const [],
      monthlyBudgetDop: 4000,
      exchangeRateDopPerUsd: 60,
      startDate: DateTime(2026, 9, 1),
    );
    final first = schedule.months.first.payments;
    final low = first.firstWhere((payment) => payment.debtId == 'low');
    final high = first.firstWhere((payment) => payment.debtId == 'high');
    expect(schedule.minimumsCovered, isTrue);
    expect(high.amountDop, greaterThan(low.amountDop));
    expect(schedule.completed, isTrue);
    expect(buildPayoffCalendarIcs(schedule), contains('BEGIN:VALARM'));
  });

  test('USD debt is converted to DOP budget and back to native payment', () {
    const card = CreditCard(
      id: 'usd',
      name: 'USD Card',
      lastFour: '3333',
      balance: 100,
      creditLimit: 1000,
      apr: 0,
      cutoffDay: 1,
      dueDay: 20,
      minimumDue: 100,
      accentColor: 0,
      currency: 'USD',
    );
    final schedule = buildPayoffSchedule(
      cards: const [card],
      loans: const [],
      monthlyBudgetDop: 6000,
      exchangeRateDopPerUsd: 60,
    );
    expect(schedule.months.single.payments.single.nativeAmount, 100);
  });
}
