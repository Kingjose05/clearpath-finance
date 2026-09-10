import 'dart:math' as math;

import '../models.dart';
import 'bank_email_parser.dart';

class AnalyticsSnapshot {
  const AnalyticsSnapshot({
    required this.spending,
    required this.withdrawals,
    required this.income,
    required this.categoryTotals,
    required this.monthlyTotals,
    required this.topMerchant,
  });

  final double spending;
  final double withdrawals;
  final double income;
  final Map<SpendingCategory, double> categoryTotals;
  final Map<DateTime, double> monthlyTotals;
  final String? topMerchant;
}

AnalyticsSnapshot buildAnalytics(
  List<Purchase> transactions, {
  int months = 6,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final start = DateTime(today.year, today.month - months + 1);
  final inRange = transactions.where(
    (item) => !item.purchasedAt.isBefore(start),
  );
  final categories = <SpendingCategory, double>{};
  final monthTotals = <DateTime, double>{
    for (var index = months - 1; index >= 0; index--)
      DateTime(today.year, today.month - index): 0,
  };
  final merchants = <String, double>{};
  var spending = 0.0;
  var withdrawals = 0.0;
  var income = 0.0;
  for (final item in inRange) {
    if (item.kind == TransactionKind.income ||
        item.kind == TransactionKind.refund ||
        item.kind == TransactionKind.cardPayment ||
        item.kind == TransactionKind.adjustment) {
      if (item.kind == TransactionKind.income) income += item.amount;
      continue;
    }
    spending += item.amount;
    if (item.kind == TransactionKind.withdrawal) withdrawals += item.amount;
    final category =
        item.category == SpendingCategory.other &&
            item.kind == TransactionKind.purchase
        ? categorizeMerchant(item.merchant)
        : item.category;
    categories[category] = (categories[category] ?? 0) + item.amount;
    final month = DateTime(item.purchasedAt.year, item.purchasedAt.month);
    if (monthTotals.containsKey(month)) {
      monthTotals[month] = monthTotals[month]! + item.amount;
    }
    merchants[item.merchant] = (merchants[item.merchant] ?? 0) + item.amount;
  }
  final sortedCategories = categories.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final sortedMerchants = merchants.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return AnalyticsSnapshot(
    spending: spending,
    withdrawals: withdrawals,
    income: income,
    categoryTotals: Map.fromEntries(sortedCategories),
    monthlyTotals: monthTotals,
    topMerchant: sortedMerchants.isEmpty ? null : sortedMerchants.first.key,
  );
}

class DebtStrategyItem {
  const DebtStrategyItem({
    required this.id,
    required this.name,
    required this.balance,
    required this.apr,
    required this.minimum,
    required this.dueDay,
    required this.isLoan,
  });

  final String id;
  final String name;
  final double balance;
  final double apr;
  final double minimum;
  final int dueDay;
  final bool isLoan;
}

class DebtStrategy {
  const DebtStrategy({
    required this.targetMonths,
    required this.minimumMonths,
    required this.maximumMonths,
    required this.monthlyPayment,
    required this.paycheckFraction,
    required this.projectedInterest,
    required this.feasible,
    required this.allocations,
  });

  final int targetMonths;
  final int minimumMonths;
  final int maximumMonths;
  final double monthlyPayment;
  final double paycheckFraction;
  final double projectedInterest;
  final bool feasible;
  final List<DebtStrategyAllocation> allocations;
}

class DebtStrategyAllocation {
  const DebtStrategyAllocation({
    required this.id,
    required this.name,
    required this.amount,
    required this.dueDay,
    required this.reason,
  });

  final String id;
  final String name;
  final double amount;
  final int dueDay;
  final String reason;
}

DebtStrategy buildDebtStrategy({
  required List<CreditCard> cards,
  required List<Loan> loans,
  required double monthlySalary,
  required double essentialExpenses,
  required int targetMonths,
}) {
  final items = <DebtStrategyItem>[
    for (final card in cards.where(
      (card) => card.isCredit && card.totalOwed > 0,
    ))
      DebtStrategyItem(
        id: card.id,
        name: card.name,
        balance: card.totalOwed,
        apr: card.apr,
        minimum: math.min(
          card.totalOwed,
          card.minimumDue + card.installmentMonthlyPayment,
        ),
        dueDay: card.dueDay,
        isLoan: false,
      ),
    for (final loan in loans.where((loan) => loan.balance > 0))
      DebtStrategyItem(
        id: loan.id,
        name: loan.name,
        balance: loan.balance,
        apr: loan.apr,
        minimum: math.min(loan.balance, loan.minimumPayment),
        dueDay: loan.dueDay,
        isLoan: true,
      ),
  ]..sort((a, b) => b.apr.compareTo(a.apr));

  final minimums = items.fold(0.0, (sum, item) => sum + item.minimum);
  final disposable = math.max(0, monthlySalary - essentialExpenses).toDouble();
  final affordable = monthlySalary > 0 ? disposable : minimums;
  final fastestMonths = items.isEmpty
      ? 0
      : _monthsToPay(
          items,
          math.max(affordable, minimums),
          maxMonths: 360,
        ).months;
  final slowestMonths = items.isEmpty
      ? 0
      : _monthsToPay(items, minimums, maxMonths: 360).months;
  final minMonths = math.max(1, math.min(fastestMonths, 360));
  final maxMonths = math.max(minMonths, math.min(slowestMonths, 120));
  final selected = targetMonths.clamp(minMonths, maxMonths);
  final required = items.isEmpty
      ? 0.0
      : _paymentForMonths(items, selected, minimums);
  final simulation = _monthsToPay(items, required, maxMonths: 360);
  final allocations = _firstMonthAllocations(items, required);

  return DebtStrategy(
    targetMonths: selected,
    minimumMonths: minMonths,
    maximumMonths: maxMonths,
    monthlyPayment: required,
    paycheckFraction: monthlySalary <= 0 ? 0 : required / monthlySalary,
    projectedInterest: simulation.interest,
    feasible:
        items.isEmpty || monthlySalary <= 0 || required <= disposable + 0.01,
    allocations: allocations,
  );
}

double _paymentForMonths(
  List<DebtStrategyItem> items,
  int months,
  double minimums,
) {
  var low = minimums;
  var high = items.fold(0.0, (sum, item) => sum + item.balance) + minimums;
  for (var i = 0; i < 48; i++) {
    final mid = (low + high) / 2;
    final result = _monthsToPay(items, mid, maxMonths: months);
    if (result.remaining <= 0.01) {
      high = mid;
    } else {
      low = mid;
    }
  }
  return high;
}

({int months, double interest, double remaining}) _monthsToPay(
  List<DebtStrategyItem> items,
  double monthlyBudget, {
  required int maxMonths,
}) {
  final balances = {for (final item in items) item.id: item.balance};
  var interest = 0.0;
  var month = 0;
  while (month < maxMonths && balances.values.any((value) => value > 0.01)) {
    month++;
    for (final item in items) {
      final accrued = (balances[item.id] ?? 0) * item.apr / 1200;
      balances[item.id] = (balances[item.id] ?? 0) + accrued;
      interest += accrued;
    }
    var remainingBudget = monthlyBudget;
    for (final item in items) {
      final payment = math.min(item.minimum, balances[item.id] ?? 0).toDouble();
      balances[item.id] = math.max(0, (balances[item.id] ?? 0) - payment);
      remainingBudget -= payment;
    }
    for (final item in items) {
      if (remainingBudget <= 0) break;
      final payment = math
          .min(remainingBudget, balances[item.id] ?? 0)
          .toDouble();
      balances[item.id] = math.max(0, (balances[item.id] ?? 0) - payment);
      remainingBudget -= payment;
    }
  }
  return (
    months: month,
    interest: interest,
    remaining: balances.values.fold(0.0, (sum, value) => sum + value),
  );
}

List<DebtStrategyAllocation> _firstMonthAllocations(
  List<DebtStrategyItem> items,
  double budget,
) {
  var remaining = budget;
  final amounts = <String, double>{};
  for (final item in [...items]..sort((a, b) => a.dueDay.compareTo(b.dueDay))) {
    final amount = math.min(item.minimum, remaining).toDouble();
    amounts[item.id] = amount;
    remaining -= amount;
  }
  for (final item in items) {
    if (remaining <= 0) break;
    final extra = math
        .min(item.balance - (amounts[item.id] ?? 0), remaining)
        .toDouble();
    amounts[item.id] = (amounts[item.id] ?? 0) + extra;
    remaining -= extra;
  }
  return [
    for (final item in items.where((item) => (amounts[item.id] ?? 0) > 0))
      DebtStrategyAllocation(
        id: item.id,
        name: item.name,
        amount: amounts[item.id]!,
        dueDay: item.dueDay,
        reason: (amounts[item.id] ?? 0) > item.minimum + 0.01
            ? 'Minimum + avalanche extra (${item.apr.toStringAsFixed(1)}% APR)'
            : 'Required minimum',
      ),
  ];
}
