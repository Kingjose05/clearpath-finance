import 'dart:math' as math;

import '../models.dart';

class ScheduledPayment {
  const ScheduledPayment({
    required this.debtId,
    required this.name,
    required this.date,
    required this.amountDop,
    required this.nativeAmount,
    required this.currency,
    required this.reason,
  });

  final String debtId;
  final String name;
  final DateTime date;
  final double amountDop;
  final double nativeAmount;
  final String currency;
  final String reason;
}

class PayoffMonth {
  const PayoffMonth({required this.month, required this.payments});

  final DateTime month;
  final List<ScheduledPayment> payments;

  double get totalDop =>
      payments.fold(0, (total, payment) => total + payment.amountDop);
}

class PayoffSchedule {
  const PayoffSchedule({
    required this.monthlyBudgetDop,
    required this.months,
    required this.totalInterestDop,
    required this.completed,
    required this.minimumsCovered,
  });

  final double monthlyBudgetDop;
  final List<PayoffMonth> months;
  final double totalInterestDop;
  final bool completed;
  final bool minimumsCovered;

  int get durationMonths => months.length;
  DateTime? get debtFreeDate => completed && months.isNotEmpty
      ? months.last.payments
            .map((payment) => payment.date)
            .reduce((a, b) => a.isAfter(b) ? a : b)
      : null;
}

class _DebtState {
  _DebtState({
    required this.id,
    required this.name,
    required this.balanceDop,
    required this.apr,
    required this.minimumDop,
    required this.dueDay,
    required this.currency,
  });

  final String id;
  final String name;
  double balanceDop;
  final double apr;
  final double minimumDop;
  final int dueDay;
  final String currency;
}

PayoffSchedule buildPayoffSchedule({
  required List<CreditCard> cards,
  required List<Loan> loans,
  required double monthlyBudgetDop,
  required double exchangeRateDopPerUsd,
  DateTime? startDate,
  int maxMonths = 360,
}) {
  final exchangeRate = math.max(1, exchangeRateDopPerUsd).toDouble();
  final states = <_DebtState>[
    for (final card in cards.where(
      (card) => card.isCredit && card.totalOwed > 0.01,
    ))
      _DebtState(
        id: card.id,
        name: card.name,
        balanceDop: amountInDop(card.totalOwed, card.currency, exchangeRate),
        apr: math.max(0, card.apr).toDouble(),
        minimumDop: amountInDop(
          math.min(
            card.totalOwed,
            card.minimumDue + card.installmentMonthlyPayment,
          ),
          card.currency,
          exchangeRate,
        ),
        dueDay: card.dueDay,
        currency: card.currency,
      ),
    for (final loan in loans.where((loan) => loan.balance > 0.01))
      _DebtState(
        id: loan.id,
        name: loan.name,
        balanceDop: loan.balance,
        apr: math.max(0, loan.apr).toDouble(),
        minimumDop: math.min(loan.balance, loan.minimumPayment).toDouble(),
        dueDay: loan.dueDay,
        currency: 'DOP',
      ),
  ];
  final budget = math.max(0, monthlyBudgetDop).toDouble();
  final firstMonth = startDate ?? DateTime.now();
  final months = <PayoffMonth>[];
  var totalInterest = 0.0;
  var minimumsCovered = true;

  for (
    var index = 0;
    index < maxMonths && states.any((state) => state.balanceDop > 0.01);
    index++
  ) {
    final year = firstMonth.year + (firstMonth.month - 1 + index) ~/ 12;
    final monthNumber = (firstMonth.month - 1 + index) % 12 + 1;
    final month = DateTime(year, monthNumber);
    for (final state in states.where((state) => state.balanceDop > 0.01)) {
      final interest = state.balanceDop * state.apr / 1200;
      state.balanceDop += interest;
      totalInterest += interest;
    }

    var remainingBudget = budget;
    final paid = <String, double>{};
    final activeByDue =
        states.where((state) => state.balanceDop > 0.01).toList()
          ..sort((a, b) => a.dueDay.compareTo(b.dueDay));
    for (final state in activeByDue) {
      final required = math.min(state.minimumDop, state.balanceDop).toDouble();
      final payment = math.min(required, remainingBudget).toDouble();
      paid[state.id] = payment;
      state.balanceDop -= payment;
      remainingBudget -= payment;
      if (payment + 0.01 < required) minimumsCovered = false;
    }

    final avalanche = states.where((state) => state.balanceDop > 0.01).toList()
      ..sort((a, b) {
        final aprOrder = b.apr.compareTo(a.apr);
        return aprOrder != 0 ? aprOrder : a.dueDay.compareTo(b.dueDay);
      });
    for (final state in avalanche) {
      if (remainingBudget <= 0.01) break;
      final extra = math.min(state.balanceDop, remainingBudget).toDouble();
      paid[state.id] = (paid[state.id] ?? 0) + extra;
      state.balanceDop -= extra;
      remainingBudget -= extra;
    }

    final payments = <ScheduledPayment>[];
    for (final state in activeByDue) {
      final amountDop = paid[state.id] ?? 0;
      if (amountDop <= 0.01) continue;
      final nativeAmount = state.currency == 'USD'
          ? amountDop / exchangeRate
          : amountDop;
      payments.add(
        ScheduledPayment(
          debtId: state.id,
          name: state.name,
          date: monthlyDate(year, monthNumber, state.dueDay),
          amountDop: amountDop,
          nativeAmount: nativeAmount,
          currency: state.currency,
          reason: amountDop > state.minimumDop + 0.01
              ? 'Minimum plus highest-interest extra'
              : 'Protect required payment',
        ),
      );
    }
    months.add(PayoffMonth(month: month, payments: payments));
    if (budget <= 0.01) break;
  }

  return PayoffSchedule(
    monthlyBudgetDop: budget,
    months: months,
    totalInterestDop: totalInterest,
    completed: states.every((state) => state.balanceDop <= 0.01),
    minimumsCovered: minimumsCovered,
  );
}

String buildPayoffCalendarIcs(PayoffSchedule schedule) {
  final buffer = StringBuffer()
    ..writeln('BEGIN:VCALENDAR')
    ..writeln('VERSION:2.0')
    ..writeln('PRODID:-//ClearPath Finance//Payment Plan//EN')
    ..writeln('CALSCALE:GREGORIAN')
    ..writeln('METHOD:PUBLISH');
  for (final month in schedule.months) {
    for (final payment in month.payments) {
      final date = _icsDate(payment.date);
      final amount = payment.currency == 'USD'
          ? 'USD ${payment.nativeAmount.toStringAsFixed(2)}'
          : 'DOP ${payment.nativeAmount.toStringAsFixed(2)}';
      buffer
        ..writeln('BEGIN:VEVENT')
        ..writeln('UID:${payment.debtId}-$date@clearpath-finance')
        ..writeln('DTSTAMP:${_icsUtc(DateTime.now())}')
        ..writeln('DTSTART;VALUE=DATE:$date')
        ..writeln('SUMMARY:${_icsEscape('Pay $amount to ${payment.name}')}')
        ..writeln('DESCRIPTION:${_icsEscape(payment.reason)}')
        ..writeln('BEGIN:VALARM')
        ..writeln('TRIGGER:-P3D')
        ..writeln('ACTION:DISPLAY')
        ..writeln(
          'DESCRIPTION:${_icsEscape('Payment due soon: ${payment.name}')}',
        )
        ..writeln('END:VALARM')
        ..writeln('END:VEVENT');
    }
  }
  buffer.writeln('END:VCALENDAR');
  return buffer.toString();
}

String _icsDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}'
    '${value.month.toString().padLeft(2, '0')}'
    '${value.day.toString().padLeft(2, '0')}';

String _icsUtc(DateTime value) {
  final utc = value.toUtc();
  return '${_icsDate(utc)}T'
      '${utc.hour.toString().padLeft(2, '0')}'
      '${utc.minute.toString().padLeft(2, '0')}'
      '${utc.second.toString().padLeft(2, '0')}Z';
}

String _icsEscape(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll(',', '\\,')
    .replaceAll(';', '\\;')
    .replaceAll('\n', '\\n');
