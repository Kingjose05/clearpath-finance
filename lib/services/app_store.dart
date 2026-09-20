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

  Future<void> linkDebitCardIdentifiers(
    String accountId,
    Iterable<String> identifiers,
  ) async {
    final account = _data.cards.where((card) => card.id == accountId);
    if (account.isEmpty || !account.first.isDebit) return;
    final parent = account.first;
    final linked = identifiers
        .map(_lastFour)
        .where((value) => value.length == 4)
        .toSet();
    if (linked.isEmpty) return;

    final duplicateIds = _data.cards
        .where(
          (card) =>
              card.id != parent.id &&
              card.isDebit &&
              card.currency == parent.currency &&
              linked.any(card.matchesIdentifier),
        )
        .map((card) => card.id)
        .toSet();
    if (duplicateIds.isEmpty) return;

    _data = _data.copyWith(
      cards: _data.cards
          .where((card) => !duplicateIds.contains(card.id))
          .toList(),
      purchases: _data.purchases
          .map(
            (purchase) => purchase.copyWith(
              cardId: duplicateIds.contains(purchase.cardId)
                  ? parent.id
                  : purchase.cardId,
              relatedCardId: duplicateIds.contains(purchase.relatedCardId)
                  ? parent.id
                  : purchase.relatedCardId,
            ),
          )
          .toList(),
    );
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
    final cards = _applyPurchaseToCards([..._data.cards], purchase);
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
    var savedPurchases = [..._data.purchases];
    var logicalImports = 0;
    var changed = false;
    for (final purchase in fresh) {
      final matchingIndex = _matchingTransferIndex(savedPurchases, purchase);
      if (matchingIndex != -1) {
        final existing = savedPurchases[matchingIndex];
        // The first email may have been one-sided. Apply the missing account
        // leg when the second bank email arrives, but keep one logical record.
        if (existing.relatedCardId == null &&
            existing.cardId != purchase.cardId) {
          cards = _applyPurchaseToCards(cards, purchase, applyRelated: false);
          savedPurchases[matchingIndex] = existing.copyWith(
            relatedCardId: purchase.cardId,
          );
          changed = true;
        }
        continue;
      }
      cards = _applyPurchaseToCards(cards, purchase);
      savedPurchases = [purchase, ...savedPurchases];
      logicalImports++;
      changed = true;
    }

    if (!changed) return 0;
    _data = _data.copyWith(cards: cards, purchases: savedPurchases);
    await save();
    return logicalImports;
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

List<CreditCard> _applyPurchaseToCards(
  List<CreditCard> cards,
  Purchase purchase, {
  bool applyRelated = true,
}) {
  List<CreditCard> update(
    List<CreditCard> source,
    String cardId,
    Purchase transaction,
  ) {
    return source.map((card) {
      if (card.id != cardId) return card;
      return card.copyWith(
        balance: _balanceAfterTransaction(card, transaction),
      );
    }).toList();
  }

  var updated = update(cards, purchase.cardId, purchase);
  if (applyRelated &&
      purchase.isTransfer &&
      purchase.relatedCardId != null &&
      purchase.relatedCardId != purchase.cardId) {
    final oppositeKind = purchase.kind == TransactionKind.transferOut
        ? TransactionKind.transferIn
        : TransactionKind.transferOut;
    updated = update(
      updated,
      purchase.relatedCardId!,
      purchase.copyWith(
        cardId: purchase.relatedCardId!,
        kind: oppositeKind,
        clearRelatedCardId: true,
      ),
    );
  }
  return updated;
}

String _lastFour(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 4) return digits;
  return digits.substring(digits.length - 4);
}

int _matchingTransferIndex(List<Purchase> purchases, Purchase candidate) {
  if (!candidate.isTransfer) return -1;
  for (var index = 0; index < purchases.length; index++) {
    final existing = purchases[index];
    if (!existing.isTransfer ||
        existing.cardId == candidate.cardId ||
        existing.currency != candidate.currency ||
        (existing.amount - candidate.amount).abs() > 0.01 ||
        existing.kind == candidate.kind) {
      continue;
    }
    final dateGap = existing.purchasedAt
        .difference(candidate.purchasedAt)
        .abs();
    if (dateGap > const Duration(days: 2)) continue;
    if (existing.transferReference != null &&
        candidate.transferReference != null) {
      if (existing.transferReference == candidate.transferReference) {
        return index;
      }
      continue;
    }
    if (existing.relatedCardId == candidate.cardId ||
        candidate.relatedCardId == existing.cardId) {
      return index;
    }
    if (_relatedTransferDescriptions(existing.merchant, candidate.merchant)) {
      return index;
    }
    // A same-day, same-currency, same-amount pair with opposite directions
    // is the common bank-email fallback when neither bank exposes a reference.
    return index;
  }
  return -1;
}

bool _relatedTransferDescriptions(String left, String right) {
  final ignored = {
    'transfer',
    'transferencia',
    'received',
    'recibida',
    'recibido',
    'incoming',
    'outgoing',
    'enviada',
    'enviado',
    'to',
    'from',
    'a',
    'de',
  };
  final leftWords = left
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.length >= 4 && !ignored.contains(word))
      .toSet();
  final rightWords = right
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.length >= 4 && !ignored.contains(word))
      .toSet();
  return leftWords.intersection(rightWords).isNotEmpty;
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

extension on Purchase {
  bool get isTransfer =>
      kind == TransactionKind.transferIn || kind == TransactionKind.transferOut;
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
