// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:card_debt_planner/models.dart';
import 'package:card_debt_planner/services/payment_planner.dart';

void main() {
  test('pays minimums before adding extra to the highest APR card', () {
    const planner = PaymentPlanner();
    final cards = [
      const CreditCard(
        id: 'low-apr',
        name: 'Low APR',
        lastFour: '1111',
        balance: 500,
        creditLimit: 1000,
        apr: 18,
        cutoffDay: 10,
        dueDay: 8,
        minimumDue: 50,
        accentColor: 0xFF0F766E,
      ),
      const CreditCard(
        id: 'high-apr',
        name: 'High APR',
        lastFour: '2222',
        balance: 600,
        creditLimit: 1000,
        apr: 30,
        cutoffDay: 11,
        dueDay: 12,
        minimumDue: 60,
        accentColor: 0xFFB45309,
      ),
    ];

    final plan = planner.buildPlan(cards: cards, paycheckAmount: 200);

    expect(plan.coversMinimums, isTrue);
    expect(plan.allocatedAmount, 200);
    expect(plan.allocationForCard('low-apr')!.totalAmount, 50);
    expect(plan.allocationForCard('high-apr')!.totalAmount, 150);
  });
}
