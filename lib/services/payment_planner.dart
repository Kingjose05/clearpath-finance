import 'dart:math' as math;

import '../models.dart';

class PaymentAllocation {
  const PaymentAllocation({
    required this.cardId,
    required this.cardName,
    required this.accentColor,
    required this.dueDate,
    required this.daysUntilDue,
    required this.minimumAmount,
    required this.extraAmount,
    required this.reason,
    required this.isAtRisk,
    this.currency = 'DOP',
    this.exchangeRateDopPerUsd = 1,
  });

  final String cardId;
  final String cardName;
  final int accentColor;
  final DateTime dueDate;
  final int daysUntilDue;
  final double minimumAmount;
  final double extraAmount;
  final String reason;
  final bool isAtRisk;
  final String currency;
  final double exchangeRateDopPerUsd;

  double get totalAmount => minimumAmount + extraAmount;
  double get nativeAmount =>
      currency == 'USD' ? totalAmount / exchangeRateDopPerUsd : totalAmount;
}

class PaymentPlan {
  const PaymentPlan({
    required this.paycheckAmount,
    required this.requiredMinimums,
    required this.allocations,
  });

  final double paycheckAmount;
  final double requiredMinimums;
  final List<PaymentAllocation> allocations;

  double get allocatedAmount =>
      allocations.fold(0, (sum, allocation) => sum + allocation.totalAmount);
  double get unallocatedAmount => math.max(0, paycheckAmount - allocatedAmount);
  double get shortfall => math.max(0, requiredMinimums - paycheckAmount);
  bool get coversMinimums => shortfall <= 0.01;

  PaymentAllocation? allocationForCard(String cardId) {
    for (final allocation in allocations) {
      if (allocation.cardId == cardId) return allocation;
    }
    return null;
  }
}

class PaymentPlanner {
  const PaymentPlanner();

  PaymentPlan buildPlan({
    required List<CreditCard> cards,
    required double paycheckAmount,
    double exchangeRateDopPerUsd = 60,
  }) {
    final budget = math.max(0, paycheckAmount).toDouble();
    final now = DateTime.now();
    final activeCards = cards
        .where((card) => card.isCredit && card.totalOwed > 0.01)
        .toList();
    final minimums = <String, double>{
      for (final card in activeCards)
        card.id: amountInDop(
          math.min(
            card.minimumDue + card.installmentMonthlyPayment,
            card.totalOwed,
          ),
          card.currency,
          exchangeRateDopPerUsd,
        ),
    };
    final requiredMinimums = minimums.values.fold(
      0.0,
      (sum, value) => sum + value,
    );
    var remaining = budget;
    final payments = <String, double>{};

    final byDueDate = [...activeCards]
      ..sort((a, b) {
        final dueCompare = a.nextDueDate(now).compareTo(b.nextDueDate(now));
        return dueCompare != 0 ? dueCompare : b.apr.compareTo(a.apr);
      });
    for (final card in byDueDate) {
      final paid = math.min(minimums[card.id] ?? 0, remaining).toDouble();
      payments[card.id] = paid;
      remaining -= paid;
    }

    final byPriority = [...activeCards]
      ..sort((a, b) {
        final aprCompare = b.apr.compareTo(a.apr);
        if (aprCompare != 0) return aprCompare;
        return a.daysUntilDue(now).compareTo(b.daysUntilDue(now));
      });
    for (final card in byPriority) {
      if (remaining <= 0.01) break;
      final alreadyPaid = payments[card.id] ?? 0;
      final extra = math
          .min(
            math.max(
              0,
              amountInDop(
                    card.totalOwed,
                    card.currency,
                    exchangeRateDopPerUsd,
                  ) -
                  alreadyPaid,
            ),
            remaining,
          )
          .toDouble();
      payments[card.id] = alreadyPaid + extra;
      remaining -= extra;
    }

    final allocations = <PaymentAllocation>[];
    for (final card in byDueDate) {
      final total = payments[card.id] ?? 0;
      if (total <= 0.01) continue;
      final minimum = math.min(total, minimums[card.id] ?? 0).toDouble();
      final extra = math.max(0, total - minimum).toDouble();
      final daysUntilDue = card.daysUntilDue(now);
      final atRisk = minimum + 0.01 < (minimums[card.id] ?? 0);
      final reason = atRisk
          ? 'Partial minimum'
          : extra > 0.01
          ? 'Minimum covered + extra to ${card.apr.toStringAsFixed(1)}% APR'
          : 'Upcoming minimum';
      allocations.add(
        PaymentAllocation(
          cardId: card.id,
          cardName: card.name,
          accentColor: card.accentColor,
          dueDate: card.nextDueDate(now),
          daysUntilDue: daysUntilDue,
          minimumAmount: minimum,
          extraAmount: extra,
          reason: reason,
          isAtRisk: atRisk,
          currency: card.currency,
          exchangeRateDopPerUsd: exchangeRateDopPerUsd,
        ),
      );
    }
    return PaymentPlan(
      paycheckAmount: budget,
      requiredMinimums: requiredMinimums,
      allocations: allocations,
    );
  }
}
