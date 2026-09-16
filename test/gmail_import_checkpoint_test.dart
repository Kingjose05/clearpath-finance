import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:card_debt_planner/models.dart';
import 'package:card_debt_planner/services/app_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a saved batch survives restart and cannot double-count debt on retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      await store.load();
      await store.upsertCard(
        const CreditCard(
          id: 'test-card',
          name: 'Test card',
          lastFour: '1234',
          balance: 0,
          creditLimit: 0,
          apr: 0,
          cutoffDay: 1,
          dueDay: 1,
          minimumDue: 0,
          accentColor: 0,
        ),
      );
      final purchase = Purchase(
        id: 'local-id',
        cardId: 'test-card',
        merchant: 'Test merchant',
        amount: 25,
        purchasedAt: DateTime(2026, 9, 9),
        source: PurchaseSource.email,
        sourceMessageId: 'gmail-message-id',
      );
      expect(await store.importPurchases([purchase]), 1);
      final resumed = AppStore(prefs);
      await resumed.load();
      expect(await resumed.importPurchases([purchase]), 0);
      expect(resumed.data.totalDebt, 25);
      expect(resumed.data.purchases.length, 1);
      // A partial import must not advance the successful sync cursor.
      expect(resumed.data.settings.lastEmailSyncAt, isNull);
    },
  );

  test('paired transfer emails update both debit balances once', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = AppStore(prefs);
    await store.load();
    await store.upsertCard(
      const CreditCard(
        id: 'bank-a',
        name: 'Bank A',
        lastFour: '1111',
        balance: 1000,
        creditLimit: 0,
        apr: 0,
        cutoffDay: 1,
        dueDay: 1,
        minimumDue: 0,
        accentColor: 0,
        accountType: AccountType.debit,
      ),
    );
    await store.upsertCard(
      const CreditCard(
        id: 'bank-b',
        name: 'Bank B',
        lastFour: '2222',
        balance: 500,
        creditLimit: 0,
        apr: 0,
        cutoffDay: 1,
        dueDay: 1,
        minimumDue: 0,
        accentColor: 0,
        accountType: AccountType.debit,
      ),
    );

    final sent = Purchase(
      id: 'sent',
      cardId: 'bank-a',
      merchant: 'Transfer to Bank B',
      amount: 100,
      purchasedAt: DateTime(2026, 9, 10),
      source: PurchaseSource.email,
      sourceMessageId: 'message-a',
      kind: TransactionKind.transferOut,
      category: SpendingCategory.transfers,
      transferReference: 'ABC-123',
    );
    final received = Purchase(
      id: 'received',
      cardId: 'bank-b',
      merchant: 'Transfer from Bank A',
      amount: 100,
      purchasedAt: DateTime(2026, 9, 10),
      source: PurchaseSource.email,
      sourceMessageId: 'message-b',
      kind: TransactionKind.transferIn,
      category: SpendingCategory.transfers,
      transferReference: 'ABC-123',
    );

    expect(await store.importPurchases([sent, received]), 1);
    expect(store.data.cardById('bank-a')!.balance, 900);
    expect(store.data.cardById('bank-b')!.balance, 600);
    expect(store.data.purchases, hasLength(1));
  });

  test(
    'a late second transfer email fills the missing debit leg once',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      await store.load();
      await store.upsertCard(
        const CreditCard(
          id: 'bank-a',
          name: 'Bank A',
          lastFour: '1111',
          balance: 1000,
          creditLimit: 0,
          apr: 0,
          cutoffDay: 1,
          dueDay: 1,
          minimumDue: 0,
          accentColor: 0,
          accountType: AccountType.debit,
        ),
      );
      await store.upsertCard(
        const CreditCard(
          id: 'bank-b',
          name: 'Bank B',
          lastFour: '2222',
          balance: 500,
          creditLimit: 0,
          apr: 0,
          cutoffDay: 1,
          dueDay: 1,
          minimumDue: 0,
          accentColor: 0,
          accountType: AccountType.debit,
        ),
      );
      final sent = Purchase(
        id: 'sent',
        cardId: 'bank-a',
        merchant: 'Transfer to Bank B',
        amount: 100,
        purchasedAt: DateTime(2026, 9, 10),
        source: PurchaseSource.email,
        sourceMessageId: 'message-a',
        kind: TransactionKind.transferOut,
        transferReference: 'LATE-123',
      );
      final received = sent.copyWith(
        id: 'received',
        cardId: 'bank-b',
        merchant: 'Transfer from Bank A',
        sourceMessageId: 'message-b',
        kind: TransactionKind.transferIn,
      );

      expect(await store.importPurchases([sent]), 1);
      expect(await store.importPurchases([received]), 0);
      expect(store.data.cardById('bank-a')!.balance, 900);
      expect(store.data.cardById('bank-b')!.balance, 600);
      expect(store.data.purchases, hasLength(1));
    },
  );
}
