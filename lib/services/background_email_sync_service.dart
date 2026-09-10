import 'package:background_fetch/background_fetch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_store.dart';
import 'email_sync_service.dart';
import 'notification_service.dart';
import 'payment_planner.dart';

class BackgroundEmailSyncService {
  static const dailySyncTaskId = 'com.yolo.finance.debtplan.daily_gmail_sync';
  static const minSyncSpacing = Duration(hours: 20);

  const BackgroundEmailSyncService();

  Future<void> configure() async {
    if (kIsWeb) return;
    try {
      await BackgroundFetch.configure(
        BackgroundFetchConfig(
          minimumFetchInterval: 15,
          stopOnTerminate: false,
          startOnBoot: true,
          enableHeadless: true,
          requiredNetworkType: NetworkType.ANY,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresStorageNotLow: false,
          requiresDeviceIdle: false,
        ),
        (taskId) async {
          await runDailySyncIfDue();
          await BackgroundFetch.finish(taskId);
        },
        (taskId) async {
          await BackgroundFetch.finish(taskId);
        },
      );
    } catch (_) {
      // Background refresh can be unavailable in simulators, web previews, or
      // when the user disables Background App Refresh.
    }
  }

  Future<void> start() async {
    if (kIsWeb) return;
    try {
      await BackgroundFetch.start();
    } catch (_) {}
  }

  Future<void> stop() async {
    if (kIsWeb) return;
    try {
      await BackgroundFetch.stop();
    } catch (_) {}
  }
}

@pragma('vm:entry-point')
void backgroundFetchHeadlessTask(HeadlessEvent event) async {
  if (event.timeout) {
    await BackgroundFetch.finish(event.taskId);
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  await runDailySyncIfDue();
  await BackgroundFetch.finish(event.taskId);
}

Future<int> runDailySyncIfDue({bool force = false}) async {
  final prefs = await SharedPreferences.getInstance();
  final store = AppStore(prefs);
  await store.load();
  final data = store.data;
  final settings = data.settings;

  if (!settings.emailSyncEnabled || !settings.backgroundEmailSyncEnabled) {
    return 0;
  }
  if (!force &&
      settings.lastBackgroundEmailSyncAt != null &&
      DateTime.now().difference(settings.lastBackgroundEmailSyncAt!) <
          BackgroundEmailSyncService.minSyncSpacing) {
    return 0;
  }

  final emailSync = GmailPurchaseSyncService();
  if (!await emailSync.hasGoogleAccess()) {
    await store.updateSettings(
      settings.copyWith(
        emailSyncEnabled: false,
        lastEmailSyncStatus: 'Gmail needs authorization',
      ),
    );
    return 0;
  }

  try {
    final result = await emailSync.syncRecentPurchases(
      data.cards,
      discoverCards: true,
      since:
          settings.lastEmailSyncAt?.subtract(const Duration(days: 3)) ??
          DateTime.now().subtract(const Duration(days: 30)),
      excludedMessageIds: data.purchases
          .map((purchase) => purchase.sourceMessageId)
          .whereType<String>()
          .toSet(),
    );
    for (final card in result.discoveredCards) {
      if (!store.data.cards.any((existing) => existing.id == card.id)) {
        await store.upsertCard(card);
      }
    }
    final imported = await store.importPurchases(result.purchases);
    final refreshedData = store.data;
    await store.updateSettings(
      refreshedData.settings.copyWith(
        emailSyncEnabled: true,
        connectedEmail: result.accountEmail,
        lastEmailSyncAt: DateTime.now(),
        lastBackgroundEmailSyncAt: DateTime.now(),
        lastEmailSyncStatus: imported == 0
            ? 'Background sync checked Gmail'
            : 'Background sync imported $imported purchase${imported == 1 ? '' : 's'}',
      ),
    );

    final planner = const PaymentPlanner();
    final plan = planner.buildPlan(
      cards: store.data.cards,
      paycheckAmount:
          store.data.latestPaycheck?.amount ?? store.data.totalMinimumDue,
    );
    await ReminderNotificationService().refreshCardReminders(
      cards: store.data.cards,
      loans: store.data.loans,
      settings: store.data.settings,
      plan: plan,
    );
    return imported;
  } catch (error) {
    await store.updateSettings(
      store.data.settings.copyWith(
        lastBackgroundEmailSyncAt: DateTime.now(),
        lastEmailSyncStatus: 'Background sync failed: $error',
      ),
    );
    return 0;
  }
}
