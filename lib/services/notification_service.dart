import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models.dart';
import 'payment_planner.dart';

class ReminderNotificationService {
  ReminderNotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    await _setLocalTimezone();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      ),
    );
    _initialized = true;
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (kIsWeb) return true;

    final android = await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    final ios = await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    final mac = await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    return android ?? ios ?? mac ?? true;
  }

  Future<void> refreshCardReminders({
    required List<CreditCard> cards,
    List<Loan> loans = const [],
    required AppSettings settings,
    required PaymentPlan plan,
  }) async {
    await initialize();
    if (kIsWeb) return;
    await _cancelCardReminders(cards);
    await _cancelLoanReminders(loans);
    if (!settings.notificationsEnabled) return;

    for (final card in cards.where((card) => card.balance > 0.01)) {
      await _scheduleReminderForCard(card, settings, plan);
    }
    for (final loan in loans.where((loan) => loan.balance > 0.01)) {
      await _scheduleReminderForLoan(loan, settings);
    }
  }

  Future<void> _scheduleReminderForLoan(Loan loan, AppSettings settings) async {
    final now = DateTime.now();
    final dueDate = nextMonthlyDate(loan.dueDay, now);
    var reminderDate = DateTime(
      dueDate.year,
      dueDate.month,
      dueDate.day,
      settings.reminderHour,
    ).subtract(Duration(days: loan.reminderDaysBefore));
    if (!reminderDate.isAfter(now)) {
      reminderDate = now.add(const Duration(minutes: 2));
    }
    await _plugin.zonedSchedule(
      id: _loanReminderId(loan),
      title: 'Loan payment due soon',
      body:
          '${NumberFormat.simpleCurrency().format(math.min(loan.minimumPayment, loan.balance))} suggested for ${loan.name}. Due ${DateFormat.MMMd().format(dueDate)}.',
      scheduledDate: tz.TZDateTime.from(reminderDate, tz.local),
      notificationDetails: _notificationDetails(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'loan:${loan.id}',
    );
  }

  Future<void> showTestReminder() async {
    await initialize();
    await _plugin.show(
      id: 999901,
      title: 'Credit card reminder',
      body: 'Your suggested payment is ready in ClearPath.',
      notificationDetails: _notificationDetails(),
      payload: 'test-reminder',
    );
  }

  Future<void> _scheduleReminderForCard(
    CreditCard card,
    AppSettings settings,
    PaymentPlan plan,
  ) async {
    final now = DateTime.now();
    final dueDate = card.nextDueDate(now);
    final daysBefore = math.max(0, card.reminderDaysBefore);
    var reminderDate = DateTime(
      dueDate.year,
      dueDate.month,
      dueDate.day,
      settings.reminderHour,
    ).subtract(Duration(days: daysBefore));
    if (!reminderDate.isAfter(now)) {
      reminderDate = now.add(const Duration(minutes: 2));
    }

    final allocation = plan.allocationForCard(card.id);
    final amount =
        allocation?.totalAmount ?? math.min(card.minimumDue, card.balance);
    final amountText = NumberFormat.simpleCurrency().format(amount);
    final dueText = DateFormat.MMMd().format(dueDate);
    final body =
        '$amountText suggested for ${card.name} ending ${card.lastFour}. Due $dueText.';

    await _plugin.zonedSchedule(
      id: _reminderId(card, offset: 0),
      title: 'Payment due soon',
      body: body,
      scheduledDate: tz.TZDateTime.from(reminderDate, tz.local),
      notificationDetails: _notificationDetails(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'card:${card.id}',
    );

    final dueDayDate = DateTime(
      dueDate.year,
      dueDate.month,
      dueDate.day,
      settings.reminderHour,
    );
    if (dueDayDate.isAfter(now)) {
      await _plugin.zonedSchedule(
        id: _reminderId(card, offset: 1),
        title: '${card.name} is due today',
        body: body,
        scheduledDate: tz.TZDateTime.from(dueDayDate, tz.local),
        notificationDetails: _notificationDetails(),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'card:${card.id}',
      );
    }
  }

  Future<void> _cancelCardReminders(List<CreditCard> cards) async {
    for (final card in cards) {
      await _plugin.cancel(id: _reminderId(card, offset: 0));
      await _plugin.cancel(id: _reminderId(card, offset: 1));
    }
  }

  Future<void> _cancelLoanReminders(List<Loan> loans) async {
    for (final loan in loans) {
      await _plugin.cancel(id: _loanReminderId(loan));
    }
  }

  NotificationDetails _notificationDetails() {
    const android = AndroidNotificationDetails(
      'card_due_reminders',
      'Card due reminders',
      channelDescription:
          'Reminders for upcoming credit card payment due dates.',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    );
    const darwin = DarwinNotificationDetails(
      threadIdentifier: 'card_due_reminders',
      interruptionLevel: InterruptionLevel.active,
    );
    return const NotificationDetails(
      android: android,
      iOS: darwin,
      macOS: darwin,
    );
  }

  int _reminderId(CreditCard card, {required int offset}) {
    final hash = card.id.codeUnits.fold<int>(0, (value, unit) => value + unit);
    return 70000 + hash + offset;
  }

  int _loanReminderId(Loan loan) {
    final hash = loan.id.codeUnits.fold<int>(0, (value, unit) => value + unit);
    return 90000 + hash;
  }

  Future<void> _setLocalTimezone() async {
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezone.identifier));
    } catch (_) {
      try {
        tz.setLocalLocation(tz.getLocation('America/Santo_Domingo'));
      } catch (_) {
        tz.setLocalLocation(tz.UTC);
      }
    }
  }
}
