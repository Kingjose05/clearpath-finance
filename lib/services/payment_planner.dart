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
    this.isLoan = false,
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
  final bool isLoan;

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

  PaymentAllocation? allocationForLoan(String loanId) {
    for (final allocation in allocations) {
      if (allocation.isLoan && allocation.cardId == loanId) return allocation;
    }
    return null;
  }
}

class PaymentPlanner {
  const PaymentPlanner();

  PaymentPlan buildPlan({
    required List<CreditCard> cards,
    List<Loan> loans = const [],
    required double paycheckAmount,
    double exchangeRateDopPerUsd = 60,
    DateTime? now,
  }) {
    final budget = math.max(0, paycheckAmount).toDouble();
    final today = now ?? DateTime.now();
    final activeCards = cards
        .where((card) => card.isCredit && card.totalOwed > 0.01)
        .toList();
    final activeLoans = loans.where((loan) => loan.balance > 0.01).toList();
    final exchangeRate = math.max(1, exchangeRateDopPerUsd).toDouble();
    final minimums = <String, double>{
      for (final card in activeCards)
        card.id: amountInDop(
          math.min(card.minimumDue, card.balance) +
              math.min(card.installmentMonthlyPayment, card.installmentBalance),
          card.currency,
          exchangeRate,
        ),
      for (final loan in activeLoans)
        loan.id: amountInDop(
          math.min(loan.minimumPayment, loan.balance),
          loan.currency,
          exchangeRate,
        ),
    };
    final requiredMinimums = minimums.values.fold(
      0.0,
      (sum, value) => sum + value,
    );
    var remaining = budget;
    final payments = <String, double>{};

    final dueTargets =
        <_DebtTarget>[
          ...activeCards.map(
            (card) => _DebtTarget(
              id: card.id,
              name: card.name,
              accentColor: card.accentColor,
              dueDate: card.nextDueDate(today),
              apr: card.apr,
              currency: card.currency,
              balanceDop: amountInDop(
                card.totalOwed,
                card.currency,
                exchangeRate,
              ),
              isLoan: false,
            ),
          ),
          ...activeLoans.map(
            (loan) => _DebtTarget(
              id: loan.id,
              name: loan.name,
              accentColor: 0xFF2457A7,
              dueDate: nextMonthlyDate(loan.dueDay, today),
              apr: loan.apr,
              currency: loan.currency,
              balanceDop: amountInDop(
                loan.balance,
                loan.currency,
                exchangeRate,
              ),
              isLoan: true,
            ),
          ),
        ]..sort((a, b) {
          final dueCompare = a.dueDate.compareTo(b.dueDate);
          return dueCompare != 0 ? dueCompare : b.apr.compareTo(a.apr);
        });
    for (final target in dueTargets) {
      final paid = math.min(minimums[target.id] ?? 0, remaining).toDouble();
      payments[target.id] = paid;
      remaining -= paid;
    }

    final byPriority = [...dueTargets]
      ..sort((a, b) {
        final aprCompare = b.apr.compareTo(a.apr);
        if (aprCompare != 0) return aprCompare;
        return a.dueDate.compareTo(b.dueDate);
      });
    for (final target in byPriority) {
      if (remaining <= 0.01) break;
      final alreadyPaid = payments[target.id] ?? 0;
      final extra = math
          .min(math.max(0, target.balanceDop - alreadyPaid), remaining)
          .toDouble();
      payments[target.id] = alreadyPaid + extra;
      remaining -= extra;
    }

    final allocations = <PaymentAllocation>[];
    for (final target in dueTargets) {
      final total = payments[target.id] ?? 0;
      if (total <= 0.01) continue;
      final minimum = math.min(total, minimums[target.id] ?? 0).toDouble();
      final extra = math.max(0, total - minimum).toDouble();
      final daysUntilDue = target.dueDate.difference(dateOnly(today)).inDays;
      final atRisk = minimum + 0.01 < (minimums[target.id] ?? 0);
      final reason = atRisk
          ? 'Partial minimum'
          : extra > 0.01
          ? 'Minimum covered + extra to ${target.apr.toStringAsFixed(1)}% APR'
          : 'Upcoming minimum';
      allocations.add(
        PaymentAllocation(
          cardId: target.id,
          cardName: target.name,
          accentColor: target.accentColor,
          dueDate: target.dueDate,
          daysUntilDue: daysUntilDue,
          minimumAmount: minimum,
          extraAmount: extra,
          reason: reason,
          isAtRisk: atRisk,
          currency: target.currency,
          exchangeRateDopPerUsd: exchangeRate,
          isLoan: target.isLoan,
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

class _DebtTarget {
  const _DebtTarget({
    required this.id,
    required this.name,
    required this.accentColor,
    required this.dueDate,
    required this.apr,
    required this.currency,
    required this.balanceDop,
    required this.isLoan,
  });

  final String id;
  final String name;
  final int accentColor;
  final DateTime dueDate;
  final double apr;
  final String currency;
  final double balanceDop;
  final bool isLoan;
}
