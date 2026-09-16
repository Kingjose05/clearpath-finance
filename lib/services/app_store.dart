import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'payment_planner.dart';

class AppStore {
  AppStore(this._prefs);

  static const _storageKey = 'card_debt_planner_state_v1';

  final SharedPreferences _prefs;

  DebtAppData _data = emptyDebtData();

  DebtAppData get data => _data;

  Future<void> load() async {
    final raw = _prefs.getString(_storageKey);
    if (raw == null) {
      _data = emptyDebtData();
      await save();
      return;
    }
    try {
      _data = DebtAppData.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map),
      );
      if (_isBundledSampleData(_data)) {
        _data = emptyDebtData(settings: _data.settings);
        await save();
      }
    } catch (_) {
      _data = emptyDebtData();
      await save();
    }
  }

  Future<void> save() async {
    await _prefs.setString(_storageKey, jsonEncode(_data.toJson()));
  }

  Future<void> clearData() async {
    _data = emptyDebtData(settings: _data.settings);
    await save();
  }

  Future<void> updateSettings(AppSettings settings) async {
    _data = _data.copyWith(settings: settings);
    await save();
  }

  Future<void> upsertCard(CreditCard card) async {
    final cards = [..._data.cards];
    final index = cards.indexWhere((item) => item.id == card.id);
    if (index == -1) {
      cards.add(card);
    } else {
      cards[index] = card;
    }
    _data = _data.copyWith(cards: cards);
    await save();
  }

  Future<void> upsertLoan(Loan loan) async {
    final loans = [..._data.loans];
    final index = loans.indexWhere((item) => item.id == loan.id);
    if (index == -1) {
      loans.add(loan);
    } else {
      loans[index] = loan;
    }
    _data = _data.copyWith(loans: loans);
    await save();
  }

  Future<void> addPurchase(Purchase purchase) async {
    final cards = _data.cards.map((card) {
      if (card.id != purchase.cardId) return card;
      final balance = _balanceAfterTransaction(card, purchase);
      return card.copyWith(balance: balance);
    }).toList();
    _data = _data.copyWith(
      cards: cards,
      purchases: [purchase, ..._data.purchases],
    );
    await save();
  }

  Future<int> importPurchases(List<Purchase> purchases) async {
    final seenMessageIds = _data.purchases
        .map((purchase) => purchase.sourceMessageId)
        .whereType<String>()
        .toSet();
    final fresh = purchases
        .where(
          (purchase) =>
              purchase.sourceMessageId == null ||
              !seenMessageIds.contains(purchase.sourceMessageId),
        )
        .toList();
    if (fresh.isEmpty) return 0;

    var cards = [..._data.cards];
    for (final purchase in fresh) {
      cards = cards.map((card) {
        if (card.id != purchase.cardId) return card;
        return card.copyWith(balance: _balanceAfterTransaction(card, purchase));
      }).toList();
    }

    _data = _data.copyWith(
      cards: cards,
      purchases: [...fresh, ..._data.purchases],
    );
    await save();
    return fresh.length;
  }

  Future<void> addPaycheck(Paycheck paycheck) async {
    _data = _data.copyWith(paychecks: [paycheck, ..._data.paychecks]);
    await save();
  }

  Future<void> applyPaymentPlan(PaymentPlan plan) async {
    final now = DateTime.now();
    final paymentRecords = <CardPayment>[];
    final cards = _data.cards.map((card) {
      final allocation = plan.allocationForCard(card.id);
      if (allocation == null || allocation.totalAmount <= 0) return card;
      final paymentAmount = math.min(card.totalOwed, allocation.nativeAmount);
      final revolvingPayment = math.min(card.balance, paymentAmount);
      final installmentPayment = math.min(
        card.installmentBalance,
        paymentAmount - revolvingPayment,
      );
      paymentRecords.add(
        CardPayment(
          id: newId('pay'),
          cardId: card.id,
          amount: paymentAmount,
          paidAt: now,
          note: allocation.reason,
        ),
      );
      return card.copyWith(
        balance: math.max(0, card.balance - revolvingPayment),
        installmentBalance: math.max(
          0,
          card.installmentBalance - installmentPayment,
        ),
        lastPaymentDate: now,
      );
    }).toList();
    final loans = _data.loans.map((loan) {
      final allocation = plan.allocationForLoan(loan.id);
      if (allocation == null || allocation.totalAmount <= 0) return loan;
      final paymentAmount = math.min(loan.balance, allocation.nativeAmount);
      return loan.copyWith(balance: math.max(0, loan.balance - paymentAmount));
    }).toList();
    _data = _data.copyWith(
      cards: cards,
      loans: loans,
      payments: [...paymentRecords, ..._data.payments],
    );
    await save();
  }
}

double _balanceAfterTransaction(CreditCard account, Purchase transaction) {
  final amount = transaction.amount;
  if (account.isDebit) {
    return switch (transaction.kind) {
      TransactionKind.income ||
      TransactionKind.transferIn ||
      TransactionKind.refund => account.balance + amount,
      TransactionKind.adjustment => amount,
      _ => math.max(0, account.balance - amount),
    };
  }
  return switch (transaction.kind) {
    TransactionKind.cardPayment ||
    TransactionKind.transferIn ||
    TransactionKind.refund => math.max(0, account.balance - amount),
    TransactionKind.adjustment => amount,
    TransactionKind.income => account.balance,
    _ => account.balance + amount,
  };
}

String newId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(9999)}';

DebtAppData emptyDebtData({AppSettings settings = const AppSettings()}) {
  return DebtAppData(
    cards: const [],
    purchases: const [],
    paychecks: const [],
    payments: const [],
    settings: settings.copyWith(
      emailSyncEnabled: false,
      backgroundEmailSyncEnabled: false,
      clearConnectedEmail: true,
      clearConnectedEmailProvider: true,
      clearLastEmailSyncAt: true,
      clearLastBackgroundEmailSyncAt: true,
      clearLastEmailSyncStatus: true,
      clearLastCalibrationAt: true,
    ),
    loans: const [],
  );
}

bool _isBundledSampleData(DebtAppData data) {
  const sampleCardIds = {
    'card-visa-azul',
    'card-mastercard-gold',
    'card-cashback',
    'card-travel',
  };
  if (data.cards.any((card) => sampleCardIds.contains(card.id))) return true;
  if (data.paychecks.any((paycheck) => paycheck.id == 'paycheck-sample')) {
    return true;
  }
  return data.purchases.any(
    (purchase) => purchase.sourceMessageId?.startsWith('sample-') ?? false,
  );
}
