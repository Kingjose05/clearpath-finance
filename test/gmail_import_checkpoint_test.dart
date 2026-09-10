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
}
