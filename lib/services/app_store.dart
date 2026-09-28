import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'local_data_cipher.dart';

class AppStore {
  AppStore(this._prefs);

  static const _storageKey = 'card_debt_planner_state_v1';

  final SharedPreferences _prefs;
  final LocalDataCipher _cipher = LocalDataCipher();

  DebtAppData _data = emptyDebtData();

  DebtAppData get data => _data;
  bool get hasEncryptedWebData =>
      LocalDataCipher.isEncrypted(_prefs.getString(_storageKey));

  Future<void> unlockWithPasscode(String passcode) async {
    if (kIsWeb) await _cipher.unlock(_prefs, passcode);
  }

  Future<void> load() async {
    final stored = _prefs.getString(_storageKey);
    if (kIsWeb && !_cipher.isUnlocked) {
      throw StateError('Unlock local data before loading it.');
    }
    if (stored == null) {
      _data = emptyDebtData();
      await save();
      return;
    }
    final wasPlainWeb = kIsWeb && !LocalDataCipher.isEncrypted(stored);
    try {
      final raw = wasPlainWeb || !kIsWeb
          ? stored
          : await _cipher.decrypt(stored);
      _data = DebtAppData.fromJson(
        Map<String, Object?>.from(jsonDecode(raw) as Map),
      );
      if (_isBundledSampleData(_data)) {
        _data = emptyDebtData(settings: _data.settings);
        await save();
      } else if (wasPlainWeb) {
        await save();
      }
    } catch (error) {
      throw StateError('Could not unlock saved data: $error');
    }
  }

  Future<void> save() async {
    final plain = jsonEncode(_data.toJson());
    await _prefs.setString(
      _storageKey,
      kIsWeb ? await _cipher.encrypt(plain) : plain,
    );
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
    if (purchases.isEmpty) return 0;

    var cards = [..._data.cards];
    var savedPurchases = [..._data.purchases];
    var logicalImports = 0;
    var changed = false;
    final calibration = _data.settings.lastCalibrationAt;
    bool affectsBalance(Purchase purchase) =>
        purchase.source != PurchaseSource.email ||
        calibration == null ||
        purchase.purchasedAt.isAfter(calibration);
    for (final purchase in purchases) {
      final existingMessageIndex = purchase.sourceMessageId == null
          ? -1
          : savedPurchases.indexWhere(
              (saved) => saved.sourceMessageId == purchase.sourceMessageId,
            );
      if (existingMessageIndex != -1) {
        final existing = savedPurchases[existingMessageIndex];
        // Re-read a notification that an older parser treated as a purchase.
        // Remove its one-sided effect before applying the two-sided transfer.
        if (!existing.isTransfer && purchase.isTransfer) {
          if (affectsBalance(existing)) {
            cards = _revertPurchaseFromCards(cards, existing);
            cards = _applyPurchaseToCards(cards, purchase);
          }
          savedPurchases[existingMessageIndex] = purchase;
          changed = true;
          continue;
        }
        // A previous version may have saved only the account named in a
        // transfer email. Re-reading it can now apply the missing leg safely.
        if (existing.isTransfer &&
            purchase.isTransfer &&
            existing.relatedCardId == null &&
            purchase.relatedCardId != null &&
            purchase.relatedCardId != existing.cardId) {
          final oppositeKind = purchase.kind == TransactionKind.transferOut
              ? TransactionKind.transferIn
              : TransactionKind.transferOut;
          if (affectsBalance(purchase)) {
            cards = _applyPurchaseToCards(
              cards,
              purchase.copyWith(
                cardId: purchase.relatedCardId!,
                kind: oppositeKind,
                clearRelatedCardId: true,
              ),
            );
          }
          savedPurchases[existingMessageIndex] = existing.copyWith(
            relatedCardId: purchase.relatedCardId,
          );
          changed = true;
        }
        continue;
      }
      if (purchase.source == PurchaseSource.email &&
          purchase.sourceMessageId != null &&
          purchase.kind == TransactionKind.cardPayment &&
          affectsBalance(purchase)) {
        final matches = <int>[];
        for (var index = 0; index < savedPurchases.length; index++) {
          final saved = savedPurchases[index];
          if (saved.source == PurchaseSource.manual &&
              saved.sourceMessageId == null &&
              saved.kind == TransactionKind.cardPayment &&
              saved.cardId == purchase.cardId &&
              saved.currency == purchase.currency &&
              (saved.amount - purchase.amount).abs() <= 0.01 &&
              (calibration == null || saved.purchasedAt.isAfter(calibration)) &&
              saved.purchasedAt.difference(purchase.purchasedAt).abs() <=
                  const Duration(days: 2)) {
            matches.add(index);
          }
        }
        if (matches.length == 1) {
          final index = matches.single;
          savedPurchases[index] = savedPurchases[index].copyWith(
            sourceMessageId: purchase.sourceMessageId,
          );
          changed = true;
          continue;
        }
      }
      final matchingIndex = _matchingTransferIndex(
        savedPurchases,
        purchase,
        calibration: calibration,
      );
      if (matchingIndex != -1) {
        final existing = savedPurchases[matchingIndex];
        // The first email may have been one-sided. Apply the missing account
        // leg when the second bank email arrives, but keep one logical record.
        if (existing.relatedCardId == null &&
            existing.cardId != purchase.cardId) {
          if (affectsBalance(purchase)) {
            cards = _applyPurchaseToCards(cards, purchase, applyRelated: false);
          }
          savedPurchases[matchingIndex] = existing.copyWith(
            relatedCardId: purchase.cardId,
          );
          changed = true;
        }
        continue;
      }
      if (affectsBalance(purchase)) {
        cards = _applyPurchaseToCards(cards, purchase);
      }
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

List<CreditCard> _revertPurchaseFromCards(
  List<CreditCard> cards,
  Purchase purchase,
) {
  List<CreditCard> revert(
    List<CreditCard> source,
    String cardId,
    Purchase transaction,
  ) => source.map((card) {
    if (card.id != cardId) return card;
    final amount = transaction.amount;
    final balance = card.isDebit
        ? switch (transaction.kind) {
            TransactionKind.income ||
            TransactionKind.transferIn ||
            TransactionKind.refund => math.max(0.0, card.balance - amount),
            TransactionKind.adjustment => card.balance,
            _ => card.balance + amount,
          }
        : switch (transaction.kind) {
            TransactionKind.cardPayment ||
            TransactionKind.transferIn ||
            TransactionKind.refund => card.balance + amount,
            TransactionKind.adjustment ||
            TransactionKind.income => card.balance,
            _ => math.max(0.0, card.balance - amount),
          };
    return card.copyWith(balance: balance);
  }).toList();

  var updated = revert(cards, purchase.cardId, purchase);
  if (purchase.isTransfer &&
      purchase.relatedCardId != null &&
      purchase.relatedCardId != purchase.cardId) {
    final oppositeKind = purchase.kind == TransactionKind.transferOut
        ? TransactionKind.transferIn
        : TransactionKind.transferOut;
    updated = revert(
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

int _matchingTransferIndex(
  List<Purchase> purchases,
  Purchase candidate, {
  DateTime? calibration,
}) {
  if (!candidate.isTransfer) return -1;
  for (var index = 0; index < purchases.length; index++) {
    final existing = purchases[index];
    if (!existing.isTransfer ||
        existing.cardId == candidate.cardId ||
        existing.currency != candidate.currency ||
        (existing.amount - candidate.amount).abs() > 0.01 ||
        (calibration != null &&
            existing.purchasedAt.isAfter(calibration) !=
                candidate.purchasedAt.isAfter(calibration)) ||
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
    // Do not merge unrelated transfers merely because amount and date match.
  }
  return -1;
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
