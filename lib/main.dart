import 'dart:math' as math;
import 'dart:convert';

import 'package:background_fetch/background_fetch.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';
import 'services/app_store.dart';
import 'services/background_email_sync_service.dart';
import 'services/email_sync_service.dart';
import 'services/finance_insights.dart';
import 'services/notification_service.dart';
import 'services/outlook_auth_service.dart';
import 'services/payment_planner.dart';
import 'services/payoff_calendar.dart';
import 'services/statement_ocr.dart';
import 'services/statement_vision.dart';

const _ink = Color(0xFF16232C);
const _muted = Color(0xFF667784);
const _paper = Color(0xFFF4F7F9);
const _surface = Color(0xFFFFFFFF);
const _line = Color(0xFFDDE5EA);
const _teal = Color(0xFF087E73);
const _gold = Color(0xFFB45309);
const _coral = Color(0xFFDC2626);
const _green = Color(0xFF15803D);

final _money = NumberFormat.currency(symbol: 'RD\$', decimalDigits: 2);
final _dateShort = DateFormat.MMMd();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final store = AppStore(prefs);
  await store.load();
  if (!kIsWeb) {
    BackgroundFetch.registerHeadlessTask(backgroundFetchHeadlessTask);
  }

  runApp(
    AppLockGate(
      preferences: prefs,
      child: DebtPlannerApp(
        store: store,
        planner: const PaymentPlanner(),
        notifications: ReminderNotificationService(),
        emailSync: GmailPurchaseSyncService(),
        backgroundSync: const BackgroundEmailSyncService(),
      ),
    ),
  );
}

class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.preferences,
    required this.child,
  });

  final SharedPreferences preferences;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  static const _key = 'clearpath_local_lock_hash';
  final _passcode = TextEditingController();
  bool _loading = true;
  bool _hasPasscode = false;
  bool _unlocked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hasPasscode = widget.preferences.getString(_key)?.isNotEmpty == true;
    _loading = false;
  }

  @override
  void dispose() {
    _passcode.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final value = _passcode.text.trim();
    if (value.length < 4) {
      setState(() => _error = 'Use at least 4 characters.');
      return;
    }
    final hash = sha256.convert(utf8.encode(value)).toString();
    if (_hasPasscode && widget.preferences.getString(_key) != hash) {
      setState(() => _error = 'That passcode is not correct.');
      return;
    }
    if (!_hasPasscode) await widget.preferences.setString(_key, hash);
    if (mounted) setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _teal),
        scaffoldBackgroundColor: _paper,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 390),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: _loading
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 42,
                            color: _teal,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _hasPasscode
                                ? 'Unlock ClearPath'
                                : 'Protect ClearPath',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _hasPasscode
                                ? 'Enter your local passcode to continue.'
                                : 'Create a local passcode for this browser or device.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: _muted),
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: _passcode,
                            obscureText: true,
                            autofocus: true,
                            onSubmitted: (_) => _continue(),
                            decoration: InputDecoration(
                              labelText: _hasPasscode
                                  ? 'Passcode'
                                  : 'Create passcode',
                              errorText: _error,
                              prefixIcon: const Icon(Icons.key_outlined),
                            ),
                          ),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: _continue,
                            child: Text(
                              _hasPasscode ? 'Unlock' : 'Create and continue',
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Your financial data and connected-email tokens stay on this device. This passcode is never sent to ClearPath.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DebtPlannerApp extends StatelessWidget {
  const DebtPlannerApp({
    super.key,
    required this.store,
    required this.planner,
    required this.notifications,
    required this.emailSync,
    required this.backgroundSync,
  });

  final AppStore store;
  final PaymentPlanner planner;
  final ReminderNotificationService notifications;
  final GmailPurchaseSyncService emailSync;
  final BackgroundEmailSyncService backgroundSync;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClearPath Finance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _teal).copyWith(
          primary: _teal,
          secondary: _gold,
          tertiary: _coral,
          surface: _surface,
        ),
        scaffoldBackgroundColor: _paper,
        fontFamily: 'SF Pro Display',
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: _ink,
          displayColor: _ink,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _paper,
          foregroundColor: _ink,
          centerTitle: false,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: _surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: _line),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            backgroundColor: _ink,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            side: const BorderSide(color: _line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF7F9FA),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: _line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: _line),
          ),
        ),
      ),
      home: DebtPlannerHome(
        store: store,
        planner: planner,
        notifications: notifications,
        emailSync: emailSync,
        backgroundSync: backgroundSync,
      ),
    );
  }
}

class DebtPlannerHome extends StatefulWidget {
  const DebtPlannerHome({
    super.key,
    required this.store,
    required this.planner,
    required this.notifications,
    required this.emailSync,
    required this.backgroundSync,
  });

  final AppStore store;
  final PaymentPlanner planner;
  final ReminderNotificationService notifications;
  final GmailPurchaseSyncService emailSync;
  final BackgroundEmailSyncService backgroundSync;

  @override
  State<DebtPlannerHome> createState() => _DebtPlannerHomeState();
}

class _DebtPlannerHomeState extends State<DebtPlannerHome> {
  int _tabIndex = 0;
  bool _syncing = false;
  final _outlookAuth = OutlookAuthService();

  DebtAppData get data => widget.store.data;

  PaymentPlan get plan => widget.planner.buildPlan(
    cards: data.cards,
    loans: data.loans,
    paycheckAmount: data.latestPaycheck?.amount ?? data.totalMinimumDue,
    exchangeRateDopPerUsd: data.settings.exchangeRateDopPerUsd,
  );

  @override
  void initState() {
    super.initState();
    widget.emailSync.status.addListener(_syncStatusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refreshReminders();
      await _configureBackgroundSync();
      await _runOpeningEmailSyncIfDue();
    });
  }

  void _syncStatusChanged() {
    if (mounted) setState(() {});
  }

  DateTime _incrementalSyncStart() {
    final lastSync = data.settings.lastEmailSyncAt;
    final calibrated = data.settings.lastCalibrationAt;
    DateTime? latest;
    if (lastSync != null) latest = lastSync;
    if (calibrated != null && (latest == null || calibrated.isAfter(latest))) {
      latest = calibrated;
    }
    return (latest ?? DateTime.now().subtract(const Duration(days: 30)))
        .subtract(const Duration(days: 3));
  }

  @override
  void dispose() {
    widget.emailSync.status.removeListener(_syncStatusChanged);
    super.dispose();
  }

  Future<void> _saveEmailBatch(
    EmailSyncResult result, {
    bool allowDiscovery = false,
  }) async {
    final knownCards = data.cards;
    final remappedPurchases = result.purchases
        .map((purchase) {
          final discovered = result.discoveredCards.where(
            (card) => card.id == purchase.cardId,
          );
          final source = discovered.isEmpty ? null : discovered.first;
          final matching = source == null
              ? knownCards.where((card) => card.id == purchase.cardId)
              : knownCards.where(
                  (card) =>
                      card.currency == source.currency &&
                      card.accountType == source.accountType &&
                      card.matchesIdentifier(source.lastFour),
                );
          if (matching.isEmpty) return purchase;
          return purchase.copyWith(cardId: matching.first.id);
        })
        .where(
          (purchase) =>
              allowDiscovery ||
              knownCards.any((card) => card.id == purchase.cardId),
        )
        .toList();
    if (allowDiscovery) {
      for (final card in result.discoveredCards) {
        if (!data.cards.any((existing) => existing.id == card.id)) {
          await widget.store.upsertCard(card);
        }
      }
    }
    await widget.store.importPurchases(remappedPurchases);
    if (data.settings.monthlySalary <= 0) {
      final detectedIncome = result.purchases
          .where((item) => item.kind == TransactionKind.income)
          .fold(0.0, (largest, item) => math.max(largest, item.amount));
      if (detectedIncome > 0) {
        await widget.store.updateSettings(
          widget.store.data.settings.copyWith(monthlySalary: detectedIncome),
        );
      }
    }
  }

  Future<void> _refreshReminders({bool requestPermission = false}) async {
    if (requestPermission && data.settings.notificationsEnabled) {
      await widget.notifications.requestPermission();
    }
    await widget.notifications.refreshCardReminders(
      cards: data.cards,
      loans: data.loans,
      settings: data.settings,
      plan: plan,
    );
  }

  Future<void> _saveAndRefresh({bool requestPermission = false}) async {
    await _refreshReminders(requestPermission: requestPermission);
    if (mounted) setState(() {});
  }

  Future<void> _configureBackgroundSync() async {
    await widget.backgroundSync.configure();
    if (data.settings.backgroundEmailSyncEnabled) {
      await widget.backgroundSync.start();
    } else {
      await widget.backgroundSync.stop();
    }
  }

  Future<void> _runOpeningEmailSyncIfDue() async {
    if (!data.settings.emailSyncEnabled ||
        !data.settings.backgroundEmailSyncEnabled ||
        !await widget.emailSync.hasGoogleAccess()) {
      return;
    }
    await runDailySyncIfDue();
    await widget.store.load();
    await _saveAndRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardView(
        data: data,
        plan: plan,
        onAddPaycheck: _showPaycheckSheet,
        onSavePaycheck: _savePaycheckAmount,
        onApplyPlan: _applyCurrentPlan,
        onAddPurchase: () => _showPurchaseSheet(),
        onSyncEmail: _syncEmail,
        onCalibrate: _showCalibrationSheet,
        onImportStatements: _showStatementImportSheet,
        syncing: _syncing,
      ),
      CardsView(
        data: data,
        onEditCard: _showCardSheet,
        onAddCard: () => _showCardSheet(),
        onImportStatements: _showStatementImportSheet,
        onSyncEmail: _syncEmail,
        syncing: _syncing,
        onEditLoan: _showLoanSheet,
        onAddLoan: () => _showLoanSheet(),
      ),
      ActivityView(data: data, onAddPurchase: () => _showPurchaseSheet()),
      InsightsView(
        data: data,
        onEditProfile: _showFinancialProfileSheet,
        onEditBudget: _showPaymentBudgetSheet,
        onExportCalendar: _exportPaymentCalendar,
      ),
      SettingsView(
        data: data,
        syncing: _syncing,
        syncStatus: widget.emailSync.status.value,
        onNotificationsChanged: _setNotificationsEnabled,
        onTestNotification: _testNotification,
        onBackgroundEmailSyncChanged: _setBackgroundEmailSyncEnabled,
        onConnectEmail: _showEmailProviderSheet,
        onEmailSync: _syncEmail,
        onImportEmail: _importEmail,
        onRunBackgroundSyncNow: _runBackgroundSyncNow,
        onDisconnectEmail: _disconnectEmail,
        onResetData: _resetData,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ClearPath',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Add purchase',
            onPressed: () => _showPurchaseSheet(),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
          IconButton(
            tooltip: 'Add paycheck',
            onPressed: _showPaycheckSheet,
            icon: const Icon(Icons.add_card_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: pages[_tabIndex],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: _tabIndex,
        backgroundColor: _surface,
        indicatorColor: const Color(0xFFDDF3EE),
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.space_dashboard_outlined),
            selectedIcon: Icon(Icons.space_dashboard),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Accounts',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Insights',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Future<void> _showPaycheckSheet() async {
    final amountController = TextEditingController(
      text: data.latestPaycheck == null
          ? ''
          : data.latestPaycheck!.amount.toStringAsFixed(0),
    );
    final noteController = TextEditingController();
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) {
        return _SheetFrame(
          title: 'Add paycheck',
          children: [
            _MoneyField(controller: amountController, label: 'Amount'),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(labelText: 'Note'),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.check),
              label: const Text('Save paycheck'),
            ),
          ],
        );
      },
    );

    if (submitted != true) return;
    final amount = _parseMoney(amountController.text);
    if (amount <= 0) return;
    await widget.store.addPaycheck(
      Paycheck(
        id: newId('paycheck'),
        amount: amount,
        receivedAt: DateTime.now(),
        note: noteController.text.trim().isEmpty
            ? null
            : noteController.text.trim(),
      ),
    );
    await _saveAndRefresh();
    if (!mounted) return;
    _snack('Paycheck saved. Suggested payments updated.');
  }

  Future<void> _savePaycheckAmount(double amount) async {
    if (amount <= 0) return;
    await widget.store.addPaycheck(
      Paycheck(
        id: newId('paycheck'),
        amount: amount,
        receivedAt: DateTime.now(),
      ),
    );
    await _saveAndRefresh();
    if (mounted) _snack('Paycheck saved. Payment split updated.');
  }

  Future<void> _applyCurrentPlan() async {
    if (plan.allocations.isEmpty || plan.allocatedAmount <= 0) {
      _snack('No payment allocation is available yet.');
      return;
    }
    await widget.store.applyPaymentPlan(plan);
    await _saveAndRefresh();
    if (!mounted) return;
    _snack('Suggested payments were applied to your balances.');
  }

  Future<void> _showPurchaseSheet({CreditCard? initialCard}) async {
    if (data.cards.isEmpty) {
      _snack('Add one of your real accounts before adding transactions.');
      await _showCardSheet();
      return;
    }
    var selectedCard = initialCard ?? data.cards.first;
    var selectedKind = TransactionKind.purchase;
    var selectedCategory = SpendingCategory.other;
    final merchantController = TextEditingController();
    final amountController = TextEditingController();
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return _SheetFrame(
              title: 'Add transaction',
              children: [
                DropdownButtonFormField<CreditCard>(
                  initialValue: selectedCard,
                  decoration: const InputDecoration(labelText: 'Card'),
                  items: data.cards
                      .map(
                        (card) => DropdownMenuItem(
                          value: card,
                          child: Text('${card.name} ending ${card.lastFour}'),
                        ),
                      )
                      .toList(),
                  onChanged: (card) {
                    if (card != null) setLocalState(() => selectedCard = card);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<TransactionKind>(
                  initialValue: selectedKind,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: TransactionKind.values
                      .map(
                        (kind) => DropdownMenuItem(
                          value: kind,
                          child: Text(_transactionKindLabel(kind)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setLocalState(() => selectedKind = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<SpendingCategory>(
                  initialValue: selectedCategory,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: SpendingCategory.values
                      .map(
                        (category) => DropdownMenuItem(
                          value: category,
                          child: Text(_categoryLabel(category)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setLocalState(() => selectedCategory = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: merchantController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Merchant'),
                ),
                const SizedBox(height: 12),
                _MoneyField(controller: amountController, label: 'Amount'),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.add),
                  label: const Text('Save transaction'),
                ),
              ],
            );
          },
        );
      },
    );

    if (submitted != true) return;
    final amount = _parseMoney(amountController.text);
    if (amount <= 0 || merchantController.text.trim().isEmpty) return;
    await widget.store.addPurchase(
      Purchase(
        id: newId('purchase'),
        cardId: selectedCard.id,
        merchant: merchantController.text.trim(),
        amount: amount,
        purchasedAt: DateTime.now(),
        source: PurchaseSource.manual,
        kind: selectedKind,
        category: selectedKind == TransactionKind.withdrawal
            ? SpendingCategory.cash
            : selectedKind == TransactionKind.income
            ? SpendingCategory.income
            : selectedKind == TransactionKind.cardPayment
            ? SpendingCategory.payments
            : selectedCategory,
      ),
    );
    await _saveAndRefresh();
    if (!mounted) return;
    _snack('Transaction added to ${selectedCard.name}.');
  }

  Future<void> _showStatementImportSheet() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('Opening photo picker'),
          content: Row(
            children: [
              SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Text('Choose one or more statement screenshots.'),
              ),
            ],
          ),
        ),
      ),
    );
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (picked.isEmpty || !mounted) return;

    final ocr = const StatementOcrService();
    final vision = const StatementVisionService();
    final drafts = <StatementDraft>[];
    var unreadableImages = 0;
    var visionFailures = 0;
    final progress = ValueNotifier<String>('Preparing your screenshots...');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Analyzing statements'),
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (context, message, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 20),
                Text(message),
                const SizedBox(height: 6),
                const Text(
                  'AI is reading balances, currencies, dates, and cuotas.',
                  style: TextStyle(color: _muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      for (var index = 0; index < picked.length; index++) {
        final file = picked[index];
        progress.value =
            'Reading ${index + 1} of ${picked.length}: ${file.name}';
        String text = '';
        Uint8List? imageBytes;
        try {
          imageBytes = await file.readAsBytes();
        } catch (_) {
          // A platform may expose a path but deny a second read; OCR/manual
          // review can still proceed without an inline preview.
        }
        var visionDrafts = <StatementDraft>[];
        try {
          if (imageBytes != null && imageBytes.isNotEmpty) {
            visionDrafts = await vision.analyze(
              fileName: file.name,
              imageBytes: imageBytes,
            );
          }
        } catch (_) {
          visionFailures++;
          // Browser OCR remains a useful no-network fallback.
        }
        try {
          if (visionDrafts.isEmpty) {
            text = await ocr.extractText(file.path, imageBytes: imageBytes);
          }
        } catch (_) {
          // The editable review step remains available when recognition fails.
        }
        if (visionDrafts.isEmpty && text.trim().isEmpty) unreadableImages++;
        if (visionDrafts.isNotEmpty) {
          drafts.addAll(visionDrafts);
        } else {
          drafts.add(
            parseStatementText(
              fileName: file.name,
              text: text,
              imageBytes: imageBytes,
            ),
          );
        }
      }
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
    }

    final candidates = <_StatementCandidate>[];
    for (var index = 0; index < drafts.length; index++) {
      final draft = drafts[index];
      if (draft.hasDop || !draft.hasUsd) {
        candidates.add(
          _StatementCandidate.fromDraft(
            index: index,
            draft: draft,
            currency: 'DOP',
            existing: _matchingCard(draft.lastFour, 'DOP'),
          ),
        );
      }
      if (draft.hasUsd) {
        candidates.add(
          _StatementCandidate.fromDraft(
            index: index,
            draft: draft,
            currency: 'USD',
            existing: _matchingCard(draft.lastFour, 'USD'),
          ),
        );
      }
    }
    if (candidates.isEmpty) {
      // Web browsers do not expose native OCR. Still open a usable review form
      // for every chosen screenshot instead of silently doing nothing.
      for (var index = 0; index < drafts.length; index++) {
        candidates.add(
          _StatementCandidate.fromDraft(
            index: index,
            draft: drafts[index],
            currency: 'DOP',
            existing: null,
          ),
        );
      }
    }
    if (unreadableImages > 0 && mounted) {
      _snack(
        'Text recognition could not read $unreadableImages image${unreadableImages == 1 ? '' : 's'}. Check the image is sharp, then enter the visible values in the review form.',
      );
    }
    if (visionFailures > 0 && mounted) {
      _snack(
        'AI analysis was unavailable for $visionFailures image${visionFailures == 1 ? '' : 's'}; the browser OCR fallback was used. Check that your Cloudflare Worker is deployed with the updated code and OPENAI_API_KEY secret.',
      );
    }
    await _reviewStatementCandidates(candidates);
  }

  CreditCard? _matchingCard(String lastFour, String currency) {
    final normalizedLastFour = _normalizedLastFour(lastFour);
    if (normalizedLastFour.isEmpty) return null;
    for (final card in data.cards) {
      if (_normalizedLastFour(card.lastFour) == normalizedLastFour &&
          card.currency == currency) {
        return card;
      }
    }
    return null;
  }

  String _normalizedLastFour(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length <= 4) return digits;
    return digits.substring(digits.length - 4);
  }

  Future<void> _reviewStatementCandidates(
    List<_StatementCandidate> candidates,
  ) async {
    final names = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(text: candidate.name),
    };
    final lastFours = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(text: candidate.lastFour),
    };
    final balances = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(
          text: candidate.balance.toStringAsFixed(2),
        ),
    };
    final minimums = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(
          text: candidate.minimumDue.toStringAsFixed(2),
        ),
    };
    final installmentBalances = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(
          text: candidate.installmentBalance.toStringAsFixed(2),
        ),
    };
    final installmentPayments = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(
          text: candidate.installmentMonthlyPayment.toStringAsFixed(2),
        ),
    };
    final cutoffs = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(text: '${candidate.cutoffDay}'),
    };
    final dues = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(text: '${candidate.dueDay}'),
    };
    final types = {
      for (final candidate in candidates) candidate.key: candidate.accountType,
    };
    final associatedDebitCards = {
      for (final candidate in candidates)
        candidate.key: TextEditingController(
          text: candidate.source.associatedDebitCardLastFours.join(', '),
        ),
    };
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) => _SheetFrame(
          title: 'Review statement import',
          children: [
            const Text(
              'OCR is a starting point. Confirm every value before saving. Each currency is kept as its own account, and cuotas stay separate from revolving debt.',
              style: TextStyle(color: _muted),
            ),
            const SizedBox(height: 14),
            for (final candidate in candidates) ...[
              if (candidate.source.imageBytes != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    candidate.source.imageBytes!,
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${candidate.source.fileName} · ${candidate.currency}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  if (candidate.source.rawText.isNotEmpty)
                    _StatusChip(
                      label:
                          candidate.source.analysisSource ==
                              StatementAnalysisSource.ai
                          ? 'AI read'
                          : 'OCR read',
                      color: _teal,
                    ),
                ],
              ),
              if (candidate.source.currentTotalDop != null)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    'Detected current total: ${_currencyMoney(candidate.source.currentTotalDop!, 'DOP')}. Revolving and cuota values below are kept separate.',
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: names[candidate.key],
                      decoration: const InputDecoration(
                        labelText: 'Account name',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 105,
                    child: TextField(
                      controller: lastFours[candidate.key],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Last four'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<AccountType>(
                segments: const [
                  ButtonSegment(
                    value: AccountType.debit,
                    label: Text('Debit / cash'),
                    icon: Icon(Icons.account_balance_wallet_outlined),
                  ),
                  ButtonSegment(
                    value: AccountType.credit,
                    label: Text('Credit card'),
                    icon: Icon(Icons.credit_card),
                  ),
                ],
                selected: {types[candidate.key]!},
                onSelectionChanged: (value) =>
                    setLocalState(() => types[candidate.key] = value.first),
              ),
              const SizedBox(height: 10),
              _MoneyField(
                controller: balances[candidate.key]!,
                label: types[candidate.key] == AccountType.debit
                    ? 'Available balance (${candidate.currency})'
                    : candidate.currency == 'USD'
                    ? 'Statement balance (USD)'
                    : 'Revolving balance (DOP)',
              ),
              if (types[candidate.key] == AccountType.credit) ...[
                const SizedBox(height: 10),
                _MoneyField(
                  controller: minimums[candidate.key]!,
                  label: 'Minimum payment (${candidate.currency})',
                ),
              ],
              if (types[candidate.key] == AccountType.debit) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: associatedDebitCards[candidate.key],
                  keyboardType: TextInputType.text,
                  decoration: const InputDecoration(
                    labelText: 'Associated debit-card last four',
                  ),
                ),
              ],
              if (types[candidate.key] == AccountType.credit &&
                  candidate.currency == 'DOP') ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MoneyField(
                        controller: installmentBalances[candidate.key]!,
                        label: 'Separate cuota balance',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MoneyField(
                        controller: installmentPayments[candidate.key]!,
                        label: 'Monthly cuota',
                      ),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Leave cuota balance at the estimated amount if the statement only shows the monthly installment; it will not be added to revolving debt.',
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                ),
              ],
              if (types[candidate.key] == AccountType.credit) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _NumberField(
                        controller: cutoffs[candidate.key]!,
                        label: 'Cutoff day',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _NumberField(
                        controller: dues[candidate.key]!,
                        label: 'Due day',
                      ),
                    ),
                  ],
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Divider(height: 1),
              ),
            ],
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Save confirmed balances'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true) return;
    for (final candidate in candidates) {
      final enteredLastFour = _normalizedLastFour(
        lastFours[candidate.key]!.text,
      );
      // Look up again at save time. A matching account may have been created
      // earlier in this same import batch or corrected in the review form.
      final existing =
          _matchingCard(enteredLastFour, candidate.currency) ??
          candidate.existing;
      final balance = _parseMoney(balances[candidate.key]!.text);
      final accountId = existing?.id ?? newId('card');
      final debitCardIdentifiers = types[candidate.key] == AccountType.debit
          ? {
              ...?existing?.associatedDebitCardLastFours,
              ...associatedDebitCards[candidate.key]!.text
                  .split(',')
                  .map(_normalizedLastFour)
                  .where((value) => value.length == 4),
            }.toList()
          : const <String>[];
      await widget.store.upsertCard(
        CreditCard(
          id: accountId,
          name: names[candidate.key]!.text.trim().isEmpty
              ? candidate.name
              : names[candidate.key]!.text.trim(),
          lastFour: enteredLastFour,
          balance: balance,
          creditLimit:
              existing?.creditLimit ??
              (types[candidate.key] == AccountType.credit
                  ? math.max(balance, 1)
                  : 0),
          apr: existing?.apr ?? 0,
          cutoffDay: _parseDay(cutoffs[candidate.key]!.text),
          dueDay: _parseDay(dues[candidate.key]!.text),
          minimumDue: types[candidate.key] == AccountType.credit
              ? _parseMoney(minimums[candidate.key]!.text)
              : 0,
          accentColor: existing?.accentColor ?? _teal.toARGB32(),
          lastPaymentDate: existing?.lastPaymentDate,
          reminderDaysBefore:
              existing?.reminderDaysBefore ??
              data.settings.defaultReminderDaysBefore,
          emailMatchTerms: existing?.emailMatchTerms ?? const [],
          associatedDebitCardLastFours: debitCardIdentifiers,
          accountType: types[candidate.key]!,
          currency: candidate.currency,
          installmentBalance:
              types[candidate.key] == AccountType.credit &&
                  candidate.currency == 'DOP'
              ? _parseMoney(installmentBalances[candidate.key]!.text)
              : 0,
          installmentMonthlyPayment:
              types[candidate.key] == AccountType.credit &&
                  candidate.currency == 'DOP'
              ? _parseMoney(installmentPayments[candidate.key]!.text)
              : 0,
          calibratedCutoffDate: candidate.source.cutoffDate,
          calibratedDueDate: candidate.source.dueDate,
          needsReview: false,
        ),
      );
      await widget.store.linkDebitCardIdentifiers(
        accountId,
        debitCardIdentifiers,
      );
    }
    await widget.store.updateSettings(
      widget.store.data.settings.copyWith(lastCalibrationAt: DateTime.now()),
    );
    await _saveAndRefresh();
    if (mounted) {
      _snack('Statement values saved. Future email updates start here.');
    }
    for (final controller in [
      ...names.values,
      ...lastFours.values,
      ...balances.values,
      ...minimums.values,
      ...installmentBalances.values,
      ...installmentPayments.values,
      ...cutoffs.values,
      ...dues.values,
      ...associatedDebitCards.values,
    ]) {
      controller.dispose();
    }
  }

  Future<void> _showCalibrationSheet() async {
    if (data.cards.isEmpty) {
      _snack('Import or add an account before calibration.');
      return;
    }
    final balances = {
      for (final account in data.cards)
        account.id: TextEditingController(
          text: account.balance.toStringAsFixed(2),
        ),
    };
    final minimums = {
      for (final account in data.cards)
        account.id: TextEditingController(
          text: account.minimumDue.toStringAsFixed(2),
        ),
    };
    final installments = {
      for (final account in data.cards)
        account.id: TextEditingController(
          text: account.installmentBalance.toStringAsFixed(2),
        ),
    };
    final installmentPayments = {
      for (final account in data.cards)
        account.id: TextEditingController(
          text: account.installmentMonthlyPayment.toStringAsFixed(2),
        ),
    };
    final cutoffs = {
      for (final account in data.cards)
        account.id: TextEditingController(text: '${account.cutoffDay}'),
    };
    final dues = {
      for (final account in data.cards)
        account.id: TextEditingController(text: '${account.dueDay}'),
    };
    final types = {
      for (final account in data.cards) account.id: account.accountType,
    };
    final currencies = {
      for (final account in data.cards) account.id: account.currency,
    };
    final exchangeRate = TextEditingController(
      text: data.settings.exchangeRateDopPerUsd.toStringAsFixed(2),
    );

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) => _SheetFrame(
          title: 'Calibrate accounts',
          children: [
            const Text(
              'Use the balances in your banking apps or latest statements. New email activity will be counted from this calibration forward.',
              style: TextStyle(color: _muted),
            ),
            const SizedBox(height: 14),
            _MoneyField(
              controller: exchangeRate,
              label: 'DOP per USD exchange rate',
            ),
            const SizedBox(height: 18),
            for (final account in data.cards) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      account.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (account.needsReview)
                    const _StatusChip(label: 'Review', color: _gold),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<AccountType>(
                segments: const [
                  ButtonSegment(
                    value: AccountType.credit,
                    label: Text('Credit'),
                    icon: Icon(Icons.credit_card),
                  ),
                  ButtonSegment(
                    value: AccountType.debit,
                    label: Text('Debit'),
                    icon: Icon(Icons.account_balance_wallet_outlined),
                  ),
                ],
                selected: {types[account.id]!},
                onSelectionChanged: (value) =>
                    setLocalState(() => types[account.id] = value.first),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: currencies[account.id],
                decoration: const InputDecoration(labelText: 'Currency'),
                items: const [
                  DropdownMenuItem(
                    value: 'DOP',
                    child: Text('DOP · Dominican pesos'),
                  ),
                  DropdownMenuItem(
                    value: 'USD',
                    child: Text('USD · US dollars'),
                  ),
                ],
                onChanged: (value) => setLocalState(
                  () => currencies[account.id] = value ?? 'DOP',
                ),
              ),
              const SizedBox(height: 10),
              _MoneyField(
                controller: balances[account.id]!,
                label: types[account.id] == AccountType.debit
                    ? 'Current available balance'
                    : 'Current revolving debt',
              ),
              if (types[account.id] == AccountType.credit) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MoneyField(
                        controller: installments[account.id]!,
                        label: 'Cuotas owed',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MoneyField(
                        controller: installmentPayments[account.id]!,
                        label: 'Monthly cuota',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _MoneyField(
                  controller: minimums[account.id]!,
                  label: 'Minimum payment',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _NumberField(
                        controller: cutoffs[account.id]!,
                        label: 'Cutoff day',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _NumberField(
                        controller: dues[account.id]!,
                        label: 'Payment day',
                      ),
                    ),
                  ],
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Divider(height: 1),
              ),
            ],
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.tune),
              label: const Text('Save calibration'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true) return;
    for (final account in [...data.cards]) {
      final type = types[account.id]!;
      await widget.store.upsertCard(
        account.copyWith(
          accountType: type,
          currency: currencies[account.id],
          balance: _parseMoney(balances[account.id]!.text),
          minimumDue: type == AccountType.credit
              ? _parseMoney(minimums[account.id]!.text)
              : 0,
          installmentBalance: type == AccountType.credit
              ? _parseMoney(installments[account.id]!.text)
              : 0,
          installmentMonthlyPayment: type == AccountType.credit
              ? _parseMoney(installmentPayments[account.id]!.text)
              : 0,
          cutoffDay: _parseDay(cutoffs[account.id]!.text),
          dueDay: _parseDay(dues[account.id]!.text),
          needsReview: false,
        ),
      );
    }
    await widget.store.updateSettings(
      widget.store.data.settings.copyWith(
        lastCalibrationAt: DateTime.now(),
        exchangeRateDopPerUsd: math.max(1, _parseMoney(exchangeRate.text)),
      ),
    );
    await _saveAndRefresh();
    if (mounted) _snack('Accounts calibrated. Future updates start here.');
  }

  Future<void> _showCardSheet([CreditCard? card]) async {
    final isNew = card == null;
    final name = TextEditingController(text: card?.name ?? '');
    final lastFour = TextEditingController(text: card?.lastFour ?? '');
    final balance = TextEditingController(
      text: (card?.balance ?? 0).toStringAsFixed(2),
    );
    final limit = TextEditingController(
      text: (card?.creditLimit ?? 0).toStringAsFixed(0),
    );
    final apr = TextEditingController(
      text: (card?.apr ?? 0).toStringAsFixed(1),
    );
    final cutoff = TextEditingController(
      text: (card?.cutoffDay ?? 15).toString(),
    );
    final due = TextEditingController(text: (card?.dueDay ?? 1).toString());
    final minDue = TextEditingController(
      text: (card?.minimumDue ?? 0).toStringAsFixed(0),
    );
    final remind = TextEditingController(
      text:
          (card?.reminderDaysBefore ?? data.settings.defaultReminderDaysBefore)
              .toString(),
    );
    final terms = TextEditingController(
      text: card?.emailMatchTerms.join(', ') ?? '',
    );
    final associatedDebitCards = TextEditingController(
      text: card?.associatedDebitCardLastFours.join(', ') ?? '',
    );
    var accent = card?.accentColor ?? _teal.toARGB32();
    var accountType = card?.accountType ?? AccountType.credit;
    var currency = card?.currency ?? 'DOP';
    final installmentBalance = TextEditingController(
      text: (card?.installmentBalance ?? 0).toStringAsFixed(2),
    );
    final installmentPayment = TextEditingController(
      text: (card?.installmentMonthlyPayment ?? 0).toStringAsFixed(2),
    );

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return _SheetFrame(
              title: isNew ? 'Add account' : 'Edit account',
              children: [
                TextField(
                  controller: name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Account name'),
                ),
                const SizedBox(height: 12),
                SegmentedButton<AccountType>(
                  segments: const [
                    ButtonSegment(
                      value: AccountType.credit,
                      icon: Icon(Icons.credit_card),
                      label: Text('Credit'),
                    ),
                    ButtonSegment(
                      value: AccountType.debit,
                      icon: Icon(Icons.account_balance_wallet_outlined),
                      label: Text('Debit'),
                    ),
                  ],
                  selected: {accountType},
                  onSelectionChanged: (value) =>
                      setLocalState(() => accountType = value.first),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: currency,
                  decoration: const InputDecoration(labelText: 'Currency'),
                  items: const [
                    DropdownMenuItem(
                      value: 'DOP',
                      child: Text('DOP · Dominican pesos'),
                    ),
                    DropdownMenuItem(
                      value: 'USD',
                      child: Text('USD · US dollars'),
                    ),
                  ],
                  onChanged: (value) =>
                      setLocalState(() => currency = value ?? 'DOP'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: lastFour,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Last four'),
                ),
                const SizedBox(height: 12),
                if (accountType == AccountType.debit)
                  _MoneyField(controller: balance, label: 'Available balance'),
                if (accountType == AccountType.debit)
                  const SizedBox(height: 12),
                if (accountType == AccountType.debit)
                  TextField(
                    controller: associatedDebitCards,
                    decoration: const InputDecoration(
                      labelText: 'Associated debit-card last four',
                    ),
                  ),
                if (accountType == AccountType.debit)
                  const SizedBox(height: 12),
                if (accountType == AccountType.credit)
                  Row(
                    children: [
                      Expanded(
                        child: _MoneyField(
                          controller: balance,
                          label: 'Balance',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MoneyField(controller: limit, label: 'Limit'),
                      ),
                    ],
                  ),
                if (accountType == AccountType.credit)
                  const SizedBox(height: 12),
                if (accountType == AccountType.credit)
                  Row(
                    children: [
                      Expanded(
                        child: _NumberField(controller: apr, label: 'APR %'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MoneyField(
                          controller: minDue,
                          label: 'Min due',
                        ),
                      ),
                    ],
                  ),
                if (accountType == AccountType.credit)
                  const SizedBox(height: 12),
                if (accountType == AccountType.credit)
                  Row(
                    children: [
                      Expanded(
                        child: _NumberField(
                          controller: cutoff,
                          label: 'Cutoff day',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _NumberField(controller: due, label: 'Due day'),
                      ),
                    ],
                  ),
                if (accountType == AccountType.credit)
                  const SizedBox(height: 12),
                if (accountType == AccountType.credit)
                  Row(
                    children: [
                      Expanded(
                        child: _MoneyField(
                          controller: installmentBalance,
                          label: 'Installments owed',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MoneyField(
                          controller: installmentPayment,
                          label: 'Monthly cuota',
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                _NumberField(controller: remind, label: 'Remind days before'),
                const SizedBox(height: 12),
                TextField(
                  controller: terms,
                  decoration: const InputDecoration(
                    labelText: 'Email match terms',
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  children:
                      [
                        _teal,
                        _gold,
                        _coral,
                        const Color(0xFF2563EB),
                        _green,
                      ].map((color) {
                        final selected = color.toARGB32() == accent;
                        return ChoiceChip(
                          label: const SizedBox.shrink(),
                          selected: selected,
                          avatar: CircleAvatar(backgroundColor: color),
                          onSelected: (_) =>
                              setLocalState(() => accent = color.toARGB32()),
                        );
                      }).toList(),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.save_outlined),
                  label: Text(isNew ? 'Add account' : 'Save account'),
                ),
              ],
            );
          },
        );
      },
    );

    if (submitted != true || name.text.trim().isEmpty) return;
    final accountId = card?.id ?? newId('card');
    final debitCardIdentifiers = accountType == AccountType.debit
        ? associatedDebitCards.text
              .split(',')
              .map(_normalizedLastFour)
              .where((value) => value.length == 4)
              .toSet()
              .toList()
        : const <String>[];
    await widget.store.upsertCard(
      CreditCard(
        id: accountId,
        name: name.text.trim(),
        lastFour: lastFour.text.trim(),
        balance: _parseMoney(balance.text),
        creditLimit: math.max(_parseMoney(limit.text), 1),
        apr: _parseMoney(apr.text),
        cutoffDay: _parseDay(cutoff.text),
        dueDay: _parseDay(due.text),
        minimumDue: _parseMoney(minDue.text),
        accentColor: accent,
        lastPaymentDate: card?.lastPaymentDate,
        reminderDaysBefore: math.max(0, int.tryParse(remind.text) ?? 3),
        emailMatchTerms: terms.text
            .split(',')
            .map((term) => term.trim())
            .where((term) => term.isNotEmpty)
            .toList(),
        associatedDebitCardLastFours: debitCardIdentifiers,
        accountType: accountType,
        currency: currency,
        installmentBalance: accountType == AccountType.credit
            ? _parseMoney(installmentBalance.text)
            : 0,
        installmentMonthlyPayment: accountType == AccountType.credit
            ? _parseMoney(installmentPayment.text)
            : 0,
        needsReview: false,
      ),
    );
    await widget.store.linkDebitCardIdentifiers(
      accountId,
      debitCardIdentifiers,
    );
    await _saveAndRefresh();
    if (!mounted) return;
    _snack(isNew ? 'Account added.' : 'Account saved.');
  }

  Future<void> _showLoanSheet([Loan? loan]) async {
    final name = TextEditingController(text: loan?.name ?? '');
    final balance = TextEditingController(
      text: (loan?.balance ?? 0).toStringAsFixed(2),
    );
    final apr = TextEditingController(
      text: (loan?.apr ?? 0).toStringAsFixed(2),
    );
    final minimum = TextEditingController(
      text: (loan?.minimumPayment ?? 0).toStringAsFixed(2),
    );
    final dueDay = TextEditingController(text: (loan?.dueDay ?? 1).toString());
    final reminder = TextEditingController(
      text: (loan?.reminderDaysBefore ?? 3).toString(),
    );
    var currency = loan?.currency ?? 'DOP';
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) => _SheetFrame(
        title: loan == null ? 'Add loan' : 'Edit loan',
        children: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Loan name'),
          ),
          const SizedBox(height: 12),
          _MoneyField(controller: balance, label: 'Balance owed'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: currency,
            decoration: const InputDecoration(labelText: 'Currency'),
            items: const [
              DropdownMenuItem(
                value: 'DOP',
                child: Text('DOP · Dominican pesos'),
              ),
              DropdownMenuItem(value: 'USD', child: Text('USD · US dollars')),
            ],
            onChanged: (value) => currency = value ?? 'DOP',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NumberField(controller: apr, label: 'APR %'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MoneyField(
                  controller: minimum,
                  label: 'Monthly minimum',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NumberField(controller: dueDay, label: 'Due day'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  controller: reminder,
                  label: 'Remind before',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save loan'),
          ),
        ],
      ),
    );
    if (submitted != true || name.text.trim().isEmpty) return;
    await widget.store.upsertLoan(
      Loan(
        id: loan?.id ?? newId('loan'),
        name: name.text.trim(),
        balance: _parseMoney(balance.text),
        apr: _parseMoney(apr.text),
        minimumPayment: _parseMoney(minimum.text),
        dueDay: _parseDay(dueDay.text),
        reminderDaysBefore: math.max(0, int.tryParse(reminder.text) ?? 3),
        currency: currency,
      ),
    );
    await _saveAndRefresh();
    if (mounted) _snack(loan == null ? 'Loan added.' : 'Loan updated.');
  }

  Future<void> _showFinancialProfileSheet() async {
    final salary = TextEditingController(
      text: data.settings.monthlySalary.toStringAsFixed(2),
    );
    final essentials = TextEditingController(
      text: data.settings.monthlyEssentialExpenses.toStringAsFixed(2),
    );
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) => _SheetFrame(
        title: 'Monthly money profile',
        children: [
          _MoneyField(controller: salary, label: 'Monthly take-home salary'),
          const SizedBox(height: 12),
          _MoneyField(
            controller: essentials,
            label: 'Essential monthly expenses',
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.auto_graph),
            label: const Text('Update payoff plan'),
          ),
        ],
      ),
    );
    if (submitted != true) return;
    await widget.store.updateSettings(
      data.settings.copyWith(
        monthlySalary: _parseMoney(salary.text),
        monthlyEssentialExpenses: _parseMoney(essentials.text),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _showPaymentBudgetSheet() async {
    var mode = data.settings.paymentBudgetMode;
    final amount = TextEditingController(
      text: data.settings.monthlyDebtBudget.toStringAsFixed(2),
    );
    var percent = data.settings.salaryDebtPercent.clamp(5, 100).toDouble();
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) => _SheetFrame(
          title: 'Payment commitment',
          children: [
            SegmentedButton<PaymentBudgetMode>(
              segments: const [
                ButtonSegment(
                  value: PaymentBudgetMode.amount,
                  icon: Icon(Icons.payments_outlined),
                  label: Text('Amount'),
                ),
                ButtonSegment(
                  value: PaymentBudgetMode.percent,
                  icon: Icon(Icons.percent),
                  label: Text('Salary %'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (value) =>
                  setLocalState(() => mode = value.first),
            ),
            const SizedBox(height: 18),
            if (mode == PaymentBudgetMode.amount)
              _MoneyField(controller: amount, label: 'DOP committed per month')
            else ...[
              Text(
                '${percent.toStringAsFixed(0)}% of salary · ${_money.format(data.settings.monthlySalary * percent / 100)} monthly',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              Slider(
                min: 5,
                max: 100,
                divisions: 19,
                value: percent,
                label: '${percent.toStringAsFixed(0)}%',
                onChanged: (value) => setLocalState(() => percent = value),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'ClearPath protects required payments first, then applies every extra peso to the highest APR.',
              style: TextStyle(color: _muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.auto_graph),
              label: const Text('Build payment calendar'),
            ),
          ],
        ),
      ),
    );
    if (submitted != true) return;
    await widget.store.updateSettings(
      data.settings.copyWith(
        paymentBudgetMode: mode,
        monthlyDebtBudget: _parseMoney(amount.text),
        salaryDebtPercent: percent,
      ),
    );
    await _saveAndRefresh();
  }

  Future<void> _exportPaymentCalendar() async {
    final budget = data.settings.plannedMonthlyDebtPayment > 0
        ? data.settings.plannedMonthlyDebtPayment
        : data.totalMinimumDue;
    final schedule = buildPayoffSchedule(
      cards: data.cards,
      loans: data.loans,
      monthlyBudgetDop: budget,
      exchangeRateDopPerUsd: data.settings.exchangeRateDopPerUsd,
    );
    if (schedule.months.isEmpty) {
      _snack('Add debt and a payment commitment before exporting.');
      return;
    }
    final bytes = Uint8List.fromList(
      utf8.encode(buildPayoffCalendarIcs(schedule)),
    );
    await SharePlus.instance.share(
      ShareParams(
        title: 'ClearPath payment calendar',
        subject: 'ClearPath payment calendar',
        text: 'Payment reminders generated by ClearPath Finance.',
        files: [
          XFile.fromData(
            bytes,
            mimeType: 'text/calendar',
            name: 'clearpath-payment-plan.ics',
          ),
        ],
        downloadFallbackEnabled: true,
      ),
    );
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    await widget.store.updateSettings(
      data.settings.copyWith(notificationsEnabled: enabled),
    );
    await _saveAndRefresh(requestPermission: enabled);
    if (!mounted) return;
    _snack(enabled ? 'Due-date reminders enabled.' : 'Reminders paused.');
  }

  Future<void> _testNotification() async {
    await widget.notifications.requestPermission();
    await widget.notifications.showTestReminder();
    if (!mounted) return;
    _snack('Test reminder sent.');
  }

  Future<void> _setBackgroundEmailSyncEnabled(bool enabled) async {
    await widget.store.updateSettings(
      data.settings.copyWith(backgroundEmailSyncEnabled: enabled),
    );
    if (enabled) {
      await widget.backgroundSync.start();
    } else {
      await widget.backgroundSync.stop();
    }
    await _saveAndRefresh();
    if (!mounted) return;
    _snack(enabled ? 'Daily email sync enabled.' : 'Daily email sync paused.');
  }

  Future<void> _showEmailProviderSheet() async {
    final provider = await showModalBottomSheet<EmailProvider>(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Connect email',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'ClearPath only requests read access needed to find bank alerts.',
                style: TextStyle(color: _muted),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.mail_outline, color: _coral),
                title: const Text('Gmail'),
                subtitle: const Text('Connect securely with Google'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, EmailProvider.gmail),
              ),
              ListTile(
                leading: const Icon(
                  Icons.alternate_email,
                  color: Color(0xFF1264A3),
                ),
                title: const Text('Outlook / Microsoft 365'),
                subtitle: const Text('Microsoft Graph connection'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, EmailProvider.outlook),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_outlined, color: _muted),
                title: const Text('iCloud Mail'),
                subtitle: const Text('Apple-authorized mail connection'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, EmailProvider.icloud),
              ),
            ],
          ),
        ),
      ),
    );
    if (provider == null || !mounted) return;
    if (provider == EmailProvider.gmail) {
      await _configureGmailOAuth();
      return;
    }
    if (provider == EmailProvider.outlook) {
      await _configureOutlookOAuth();
      return;
    }
    final providerName = _emailProviderLabel(provider);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$providerName connection'),
        content: Text(
          'Apple does not allow a static browser app to connect directly to iCloud Mail over IMAP. A secure ClearPath mail bridge or the installed iPhone app is required. ClearPath will never ask for your main Apple Account password.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _configureOutlookOAuth() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final email = await _outlookAuth.connect();
      await widget.store.updateSettings(
        data.settings.copyWith(
          emailSyncEnabled: true,
          connectedEmailProvider: EmailProvider.outlook,
          connectedEmail: email,
          lastEmailSyncStatus:
              'Outlook connected. Transaction import is being enabled next.',
        ),
      );
      await _saveAndRefresh();
      if (mounted) {
        _snack('Outlook connected${email == null ? '' : ' as $email'}.');
      }
    } catch (error) {
      if (mounted) _snack('Outlook connection failed: $error');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _configureGmailOAuth() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final result = await widget.emailSync.connectWithGoogle(
        data.cards,
        excludedMessageIds: data.purchases
            .map((purchase) => purchase.sourceMessageId)
            .whereType<String>()
            .toSet(),
      );
      final imported = await widget.store.importPurchases(result.purchases);
      await widget.store.updateSettings(
        widget.store.data.settings.copyWith(
          emailSyncEnabled: true,
          connectedEmailProvider: EmailProvider.gmail,
          backgroundEmailSyncEnabled: !kIsWeb,
          connectedEmail: result.accountEmail,
          lastEmailSyncStatus: imported == 0
              ? result.message
              : '$imported transactions imported',
        ),
      );
      if (!kIsWeb) await widget.backgroundSync.start();
      await _saveAndRefresh();
      if (!mounted) return;
      _snack(result.message);
      if (result.discoveredCards.isNotEmpty ||
          data.cards.any((account) => account.needsReview)) {
        setState(() => _syncing = false);
        await _showCalibrationSheet();
      }
    } catch (error) {
      if (!mounted) return;
      _snack('Gmail connection failed: $error');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _syncGmail() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      if (!await widget.emailSync.hasGoogleAccess()) {
        setState(() => _syncing = false);
        await _configureGmailOAuth();
        return;
      }
      final previousCount = data.purchases.length;
      final result = await widget.emailSync.syncRecentPurchases(
        data.cards,
        discoverCards: true,
        onBatch: _saveEmailBatch,
        since: _incrementalSyncStart(),
        excludedMessageIds: data.purchases
            .map((purchase) => purchase.sourceMessageId)
            .whereType<String>()
            .toSet(),
      );
      await _saveEmailBatch(result);
      final imported = data.purchases.length - previousCount;
      await widget.store.updateSettings(
        widget.store.data.settings.copyWith(
          emailSyncEnabled: true,
          connectedEmail: result.accountEmail,
          lastEmailSyncAt: DateTime.now(),
          lastEmailSyncStatus: imported == 0
              ? result.message
              : '$imported transactions imported',
        ),
      );
      await _saveAndRefresh();
      if (!mounted) return;
      _snack(
        imported == 0 ? result.message : '$imported transactions imported.',
      );
    } catch (error) {
      if (!mounted) return;
      _snack('Gmail sync failed: $error');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _syncEmail() async {
    if (data.settings.connectedEmailProvider == EmailProvider.outlook ||
        await _outlookAuth.hasAccess()) {
      await _syncOutlook(since: _incrementalSyncStart());
      return;
    }
    await _syncGmail();
  }

  Future<void> _importEmail() async {
    if (data.settings.connectedEmailProvider != EmailProvider.outlook &&
        !await _outlookAuth.hasAccess()) {
      await _importGmail();
      return;
    }
    if (!mounted) return;
    final today = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: today,
      initialDateRange: DateTimeRange(
        start: today.subtract(const Duration(days: 30)),
        end: today,
      ),
      helpText: 'Choose Outlook transaction date range',
    );
    if (range == null) return;
    await _syncOutlook(
      since: range.start,
      until: range.end.add(const Duration(days: 1)),
      allowDiscovery: true,
    );
  }

  Future<void> _syncOutlook({
    DateTime? since,
    DateTime? until,
    bool allowDiscovery = false,
  }) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final previousCount = data.purchases.length;
      final result = await _outlookAuth.syncRecentPurchases(
        data.cards,
        since: since,
        until: until,
        excludedMessageIds: data.purchases
            .map((item) => item.sourceMessageId)
            .whereType<String>()
            .toSet(),
      );
      await _saveEmailBatch(result, allowDiscovery: allowDiscovery);
      final imported = data.purchases.length - previousCount;
      await widget.store.updateSettings(
        data.settings.copyWith(
          emailSyncEnabled: true,
          connectedEmailProvider: EmailProvider.outlook,
          connectedEmail: result.accountEmail,
          lastEmailSyncAt: DateTime.now(),
          lastEmailSyncStatus: imported == 0
              ? result.message
              : '$imported transactions imported',
        ),
      );
      await _saveAndRefresh();
      if (mounted) _snack(result.message);
    } catch (error) {
      if (mounted) _snack('Outlook import failed: $error');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _runBackgroundSyncNow() async {
    setState(() => _syncing = true);
    try {
      final imported = await runDailySyncIfDue(force: true);
      await widget.store.load();
      await _saveAndRefresh();
      if (!mounted) return;
      _snack(
        imported == 0
            ? 'Daily sync checked Gmail.'
            : 'Daily sync imported $imported transaction${imported == 1 ? '' : 's'}.',
      );
    } catch (error) {
      if (!mounted) return;
      _snack('Daily sync failed: $error');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _importGmail() async {
    if (_syncing) return;
    if (!await widget.emailSync.hasGoogleAccess()) {
      await _configureGmailOAuth();
      if (!await widget.emailSync.hasGoogleAccess()) return;
    }
    if (!mounted) return;

    final today = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: today,
      initialDateRange: DateTimeRange(
        start: today.subtract(const Duration(days: 30)),
        end: today,
      ),
      helpText: 'Choose transaction date range',
    );
    if (range == null || !mounted) return;

    setState(() => _syncing = true);
    try {
      final previousCount = data.purchases.length;
      final result = await widget.emailSync.syncRecentPurchases(
        data.cards,
        onBatch: _saveEmailBatch,
        since: range.start,
        until: range.end.add(const Duration(days: 1)),
        discoverCards: true,
        excludedMessageIds: data.purchases
            .map((purchase) => purchase.sourceMessageId)
            .whereType<String>()
            .toSet(),
      );
      await _saveEmailBatch(result, allowDiscovery: true);
      final imported = data.purchases.length - previousCount;
      await widget.store.updateSettings(
        widget.store.data.settings.copyWith(
          emailSyncEnabled: true,
          connectedEmail: result.accountEmail,
          lastEmailSyncAt: DateTime.now(),
          lastEmailSyncStatus:
              '${result.discoveredCards.length} card${result.discoveredCards.length == 1 ? '' : 's'} found, '
              '$imported purchase${imported == 1 ? '' : 's'} imported',
        ),
      );
      await _saveAndRefresh();
      if (!mounted) return;
      _snack(result.message);
      if (result.discoveredCards.isNotEmpty ||
          data.cards.any((account) => account.needsReview)) {
        setState(() => _syncing = false);
        await _showCalibrationSheet();
      }
    } catch (error) {
      if (mounted) _snack('Email import failed: $error');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _disconnectEmail() async {
    try {
      await widget.emailSync.disconnect();
    } catch (_) {
      // Local state still needs to be cleared if the platform sign-out is unavailable.
    }
    await widget.store.updateSettings(
      data.settings.copyWith(
        emailSyncEnabled: false,
        backgroundEmailSyncEnabled: false,
        clearConnectedEmail: true,
        clearConnectedEmailProvider: true,
        clearLastEmailSyncAt: true,
        clearLastBackgroundEmailSyncAt: true,
        clearLastEmailSyncStatus: true,
      ),
    );
    await widget.backgroundSync.stop();
    await _saveAndRefresh();
    if (!mounted) return;
    _snack('Email sync disconnected.');
  }

  Future<void> _resetData() async {
    await widget.emailSync.disconnect();
    await widget.store.clearData();
    await _saveAndRefresh();
    if (!mounted) return;
    _snack('All local data cleared.');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

class DashboardView extends StatelessWidget {
  const DashboardView({
    super.key,
    required this.data,
    required this.plan,
    required this.onAddPaycheck,
    required this.onSavePaycheck,
    required this.onApplyPlan,
    required this.onAddPurchase,
    required this.onSyncEmail,
    required this.onCalibrate,
    required this.onImportStatements,
    required this.syncing,
  });

  final DebtAppData data;
  final PaymentPlan plan;
  final VoidCallback onAddPaycheck;
  final ValueChanged<double> onSavePaycheck;
  final VoidCallback onApplyPlan;
  final VoidCallback onAddPurchase;
  final VoidCallback onSyncEmail;
  final VoidCallback onCalibrate;
  final VoidCallback onImportStatements;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final nextDue = [...data.cards.where((card) => card.isCredit)]
      ..sort(
        (a, b) => a
            .nextDueDate(DateTime.now())
            .compareTo(b.nextDueDate(DateTime.now())),
      );
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        _DashboardHero(
          data: data,
          plan: plan,
          onAddPaycheck: onAddPaycheck,
          onApplyPlan: onApplyPlan,
          onSyncEmail: onSyncEmail,
          syncing: syncing,
        ),
        const SizedBox(height: 12),
        _PaymentSplitCalculator(
          data: data,
          plan: plan,
          onSavePaycheck: onSavePaycheck,
        ),
        if (data.cards.isNotEmpty &&
            (data.settings.lastCalibrationAt == null ||
                data.cards.any((account) => account.needsReview))) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onCalibrate,
            icon: const Icon(Icons.tune),
            label: const Text('Calibrate balances and dates'),
          ),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onImportStatements,
          icon: const Icon(Icons.document_scanner_outlined),
          label: const Text('Import statement screenshots'),
        ),
        const SizedBox(height: 18),
        _SectionHeader(
          title: 'Pay today',
          trailing: _money.format(plan.allocatedAmount),
        ),
        const SizedBox(height: 8),
        _PaymentPlanPanel(plan: plan),
        const SizedBox(height: 18),
        _SectionHeader(
          title: 'Accounts',
          trailing: '${data.cards.length} active',
        ),
        const SizedBox(height: 8),
        _CardsSummaryPanel(cards: data.cards),
        const SizedBox(height: 18),
        _SectionHeader(
          title: 'Due timeline',
          trailing: nextDue.isEmpty
              ? ''
              : 'Next ${_dateShort.format(nextDue.first.nextDueDate(DateTime.now()))}',
        ),
        const SizedBox(height: 8),
        _DueTimeline(cards: data.cards.where((card) => card.isCredit).toList()),
        const SizedBox(height: 18),
        _SectionHeader(
          title: 'Recent activity',
          trailing: TextButton.icon(
            onPressed: onAddPurchase,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ),
        const SizedBox(height: 8),
        _PurchaseList(data: data, purchases: data.recentPurchases(limit: 5)),
      ],
    );
  }
}

class _PaymentSplitCalculator extends StatefulWidget {
  const _PaymentSplitCalculator({
    required this.data,
    required this.plan,
    required this.onSavePaycheck,
  });

  final DebtAppData data;
  final PaymentPlan plan;
  final ValueChanged<double> onSavePaycheck;

  @override
  State<_PaymentSplitCalculator> createState() =>
      _PaymentSplitCalculatorState();
}

class _PaymentSplitCalculatorState extends State<_PaymentSplitCalculator> {
  late final TextEditingController _amount;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(
      text: widget.plan.paycheckAmount > 0
          ? widget.plan.paycheckAmount.toStringAsFixed(2)
          : '',
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entered = _parseMoney(_amount.text);
    final preview = const PaymentPlanner().buildPlan(
      cards: widget.data.cards,
      loans: widget.data.loans,
      paycheckAmount: entered,
      exchangeRateDopPerUsd: widget.data.settings.exchangeRateDopPerUsd,
    );
    return _Panel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.call_split_outlined, color: _teal),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Split a paycheck',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                ),
                Text(
                  '${preview.allocations.length} targets',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Minimums and overdue amounts first, then the highest APR debt. USD is converted using your saved rate.',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _MoneyField(
                    controller: _amount,
                    label: 'Paycheck available (DOP)',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: entered <= 0
                      ? null
                      : () => widget.onSavePaycheck(entered),
                  child: const Text('Calculate'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SplitSummary(
                    label: 'Minimums first',
                    value: _money.format(preview.requiredMinimums),
                    color: preview.coversMinimums ? _teal : _coral,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SplitSummary(
                    label: preview.coversMinimums
                        ? 'Extra avalanche'
                        : 'Shortfall',
                    value: _money.format(
                      preview.coversMinimums
                          ? preview.unallocatedAmount
                          : preview.shortfall,
                    ),
                    color: preview.coversMinimums ? _green : _coral,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SplitSummary extends StatelessWidget {
  const _SplitSummary({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _DashboardHero extends StatelessWidget {
  const _DashboardHero({
    required this.data,
    required this.plan,
    required this.onAddPaycheck,
    required this.onApplyPlan,
    required this.onSyncEmail,
    required this.syncing,
  });

  final DebtAppData data;
  final PaymentPlan plan;
  final VoidCallback onAddPaycheck;
  final VoidCallback onApplyPlan;
  final VoidCallback onSyncEmail;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final latestPaycheck = data.latestPaycheck;
    return Container(
      decoration: BoxDecoration(
        color: _ink,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Paycheck Command Center',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _StatusChip(
                label: data.settings.emailSyncEnabled ? 'Sync active' : 'Local',
                color: data.settings.emailSyncEnabled ? _green : _gold,
                dark: true,
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Update from email',
                onPressed: data.settings.emailSyncEnabled && !syncing
                    ? onSyncEmail
                    : null,
                color: Colors.white,
                icon: syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.sync),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            _money.format(data.totalDebt),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Total debt across cards and loans',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _HeroStat(
                  label: 'Latest paycheck',
                  value: latestPaycheck == null
                      ? 'Not set'
                      : _money.format(latestPaycheck.amount),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroStat(
                  label: 'Minimums',
                  value: _money.format(data.totalMinimumDue),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onAddPaycheck,
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('Add paycheck'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: _ink,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                tooltip: 'Apply suggested payments',
                onPressed: plan.allocations.isEmpty ? null : onApplyPlan,
                style: IconButton.styleFrom(
                  backgroundColor: plan.coversMinimums ? _teal : _coral,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.check_circle_outline),
              ),
            ],
          ),
          if (data.settings.emailSyncEnabled) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: syncing ? null : onSyncEmail,
                icon: syncing
                    ? const SizedBox(
                        height: 17,
                        width: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(
                  syncing
                      ? 'Updating current balances...'
                      : 'Sync current balances',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.42)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.68),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentPlanPanel extends StatelessWidget {
  const _PaymentPlanPanel({required this.plan});

  final PaymentPlan plan;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        children: [
          if (!plan.coversMinimums)
            _WarningRow(
              text: '${_money.format(plan.shortfall)} short of all minimums',
            ),
          for (final allocation in plan.allocations) ...[
            _PaymentAllocationRow(allocation: allocation),
            if (allocation != plan.allocations.last) const Divider(height: 1),
          ],
          if (plan.allocations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'Add your real cards and your next paycheck to generate a payment split.',
              ),
            ),
          if (plan.unallocatedAmount > 0.01)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Row(
                children: [
                  const Icon(Icons.savings_outlined, color: _green, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_money.format(plan.unallocatedAmount)} left after paying balances',
                      style: const TextStyle(
                        color: _green,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PaymentAllocationRow extends StatelessWidget {
  const _PaymentAllocationRow({required this.allocation});

  final PaymentAllocation allocation;

  @override
  Widget build(BuildContext context) {
    final color = Color(allocation.accentColor);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 50,
            decoration: BoxDecoration(
              color: allocation.isAtRisk ? _coral : color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${allocation.cardName}${allocation.isLoan ? ' · Loan' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  '${allocation.reason} · due ${_dateShort.format(allocation.dueDate)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _money.format(allocation.totalAmount),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              if (allocation.currency == 'USD')
                Text(
                  'US\$${allocation.nativeAmount.toStringAsFixed(2)}',
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              Text(
                allocation.daysUntilDue < 0
                    ? '${allocation.daysUntilDue.abs()}d overdue'
                    : '${allocation.daysUntilDue}d left',
                style: TextStyle(
                  color: allocation.daysUntilDue <= 3 ? _coral : _muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFFFFEEEE),
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: _coral, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: _coral,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardsSummaryPanel extends StatelessWidget {
  const _CardsSummaryPanel({required this.cards});

  final List<CreditCard> cards;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return const _EmptyPanel(
        icon: Icons.credit_card_outlined,
        title: 'No cards yet',
        message: 'Add your real credit cards to start tracking balances.',
      );
    }
    return _Panel(
      child: Column(
        children: [
          for (final card in cards) ...[
            _CardSummaryRow(card: card),
            if (card != cards.last) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _CardSummaryRow extends StatelessWidget {
  const _CardSummaryRow({required this.card});

  final CreditCard card;

  @override
  Widget build(BuildContext context) {
    final color = Color(card.accentColor);
    final due = card.nextDueDate(DateTime.now());
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: color.withValues(alpha: 0.12),
                child: Icon(
                  card.isCredit
                      ? Icons.credit_card
                      : Icons.account_balance_wallet_outlined,
                  size: 16,
                  color: color,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${card.name} · ${card.lastFour}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                _currencyMoney(
                  card.isCredit ? card.totalOwed : card.balance,
                  card.currency,
                ),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ],
          ),
          if (card.isCredit) const SizedBox(height: 10),
          if (card.isCredit)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: card.utilization,
                minHeight: 7,
                backgroundColor: const Color(0xFFEAF0EC),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          if (card.isCredit) const SizedBox(height: 8),
          Row(
            children: [
              Text(
                card.isCredit
                    ? '${(card.utilization * 100).round()}% used'
                    : 'Available balance',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const Spacer(),
              if (card.isCredit)
                Text(
                  'Cutoff ${card.cutoffDay} · Due ${_dateShort.format(due)}',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DueTimeline extends StatelessWidget {
  const _DueTimeline({required this.cards});

  final List<CreditCard> cards;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return const _EmptyPanel(
        icon: Icons.event_available_outlined,
        title: 'No due dates yet',
        message: 'Due dates appear after you add your cards.',
      );
    }
    final sorted = [...cards]
      ..sort(
        (a, b) => a
            .nextDueDate(DateTime.now())
            .compareTo(b.nextDueDate(DateTime.now())),
      );
    return SizedBox(
      height: 106,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: sorted.length,
        separatorBuilder: (context, index) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final card = sorted[index];
          final color = Color(card.accentColor);
          final due = card.nextDueDate(DateTime.now());
          return Container(
            width: 132,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.notifications_active_outlined,
                      size: 16,
                      color: color,
                    ),
                    const Spacer(),
                    Text(
                      '${card.daysUntilDue(DateTime.now())}d',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  _dateShort.format(due),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  card.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class CardsView extends StatelessWidget {
  const CardsView({
    super.key,
    required this.data,
    required this.onEditCard,
    required this.onAddCard,
    required this.onImportStatements,
    required this.onSyncEmail,
    required this.syncing,
    required this.onEditLoan,
    required this.onAddLoan,
  });

  final DebtAppData data;
  final ValueChanged<CreditCard> onEditCard;
  final VoidCallback onAddCard;
  final VoidCallback onImportStatements;
  final VoidCallback onSyncEmail;
  final bool syncing;
  final ValueChanged<Loan> onEditLoan;
  final VoidCallback onAddLoan;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        _SectionHeader(
          title: 'Cards & accounts',
          trailing: FilledButton.icon(
            onPressed: onAddCard,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Account'),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onImportStatements,
          icon: const Icon(Icons.document_scanner_outlined),
          label: const Text('Import or update from screenshots'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: syncing ? null : onSyncEmail,
          icon: syncing
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
          label: Text(syncing ? 'Updating from email...' : 'Update from email'),
        ),
        const SizedBox(height: 12),
        if (data.cards.isEmpty)
          const _EmptyPanel(
            icon: Icons.add_card_outlined,
            title: 'Start with your real accounts',
            message:
                'Add credit and debit cards, or import them securely from email.',
          ),
        for (final card in data.cards) ...[
          _CardDetailPanel(card: card, onTap: () => onEditCard(card)),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        _SectionHeader(
          title: 'Loans',
          trailing: TextButton.icon(
            onPressed: onAddLoan,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Loan'),
          ),
        ),
        const SizedBox(height: 8),
        if (data.loans.isEmpty)
          const _EmptyPanel(
            icon: Icons.account_balance_outlined,
            title: 'No loans added',
            message: 'Add a loan to include it in your payoff strategy.',
          ),
        for (final loan in data.loans) ...[
          _LoanPanel(loan: loan, onTap: () => onEditLoan(loan)),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _CardDetailPanel extends StatelessWidget {
  const _CardDetailPanel({required this.card, required this.onTap});

  final CreditCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(card.accentColor);
    final due = card.nextDueDate(DateTime.now());
    final cutoff = card.nextCutoffDate(DateTime.now());
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: _Panel(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      card.isCredit
                          ? Icons.credit_card
                          : Icons.account_balance_wallet_outlined,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          card.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 17,
                          ),
                        ),
                        Text(
                          'Ending ${card.lastFour}',
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.edit_outlined, color: _muted),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _MiniMetric(
                    label: card.isCredit ? 'Revolving' : 'Available',
                    value: _currencyMoney(card.balance, card.currency),
                  ),
                  _MiniMetric(
                    label: card.isCredit ? 'Installments' : 'Type',
                    value: card.isCredit
                        ? _currencyMoney(card.installmentBalance, card.currency)
                        : 'Debit',
                  ),
                  _MiniMetric(
                    label: card.isCredit ? 'APR' : 'Last four',
                    value: card.isCredit
                        ? '${card.apr.toStringAsFixed(1)}%'
                        : card.lastFour,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (card.isCredit)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: card.utilization,
                    minHeight: 8,
                    backgroundColor: const Color(0xFFEAF0EC),
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              if (card.isCredit) const SizedBox(height: 12),
              if (card.isCredit)
                Row(
                  children: [
                    _DatePill(
                      label: 'Cutoff',
                      value: _dateShort.format(cutoff),
                    ),
                    const SizedBox(width: 8),
                    _DatePill(label: 'Due', value: _dateShort.format(due)),
                    const Spacer(),
                    Text(
                      'Reminder ${card.reminderDaysBefore}d',
                      style: const TextStyle(
                        color: _muted,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              if (card.isDebit &&
                  card.associatedDebitCardLastFours.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Debit cards: ${card.associatedDebitCardLastFours.map((value) => '•••• $value').join('  ')}',
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LoanPanel extends StatelessWidget {
  const _LoanPanel({required this.loan, required this.onTap});

  final Loan loan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: _Panel(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFFE8F0FF),
                child: Icon(
                  Icons.account_balance_outlined,
                  color: Color(0xFF2457A7),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loan.name,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      '${loan.apr.toStringAsFixed(1)}% APR · ${loan.currency} · due day ${loan.dueDay}',
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _currencyMoney(loan.balance, loan.currency),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    '${_currencyMoney(loan.minimumPayment, loan.currency)}/mo',
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 3),
          Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class ActivityView extends StatelessWidget {
  const ActivityView({
    super.key,
    required this.data,
    required this.onAddPurchase,
  });

  final DebtAppData data;
  final VoidCallback onAddPurchase;

  @override
  Widget build(BuildContext context) {
    final purchases = [...data.purchases]
      ..sort((a, b) => b.purchasedAt.compareTo(a.purchasedAt));
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        _SectionHeader(
          title: 'Transactions',
          trailing: FilledButton.icon(
            onPressed: onAddPurchase,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ),
        const SizedBox(height: 10),
        _PurchaseList(data: data, purchases: purchases),
        const SizedBox(height: 18),
        _SectionHeader(
          title: 'Payments',
          trailing: '${data.payments.length} recorded',
        ),
        const SizedBox(height: 8),
        _Panel(
          child: Column(
            children: [
              if (data.payments.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('Applied payments will appear here.'),
                )
              else
                for (final payment in data.payments) ...[
                  _PaymentHistoryRow(data: data, payment: payment),
                  if (payment != data.payments.last) const Divider(height: 1),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PurchaseList extends StatelessWidget {
  const _PurchaseList({required this.data, required this.purchases});

  final DebtAppData data;
  final List<Purchase> purchases;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        children: [
          if (purchases.isEmpty)
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text('No purchases yet.'),
            )
          else
            for (final purchase in purchases) ...[
              _PurchaseRow(data: data, purchase: purchase),
              if (purchase != purchases.last) const Divider(height: 1),
            ],
        ],
      ),
    );
  }
}

class _PurchaseRow extends StatelessWidget {
  const _PurchaseRow({required this.data, required this.purchase});

  final DebtAppData data;
  final Purchase purchase;

  @override
  Widget build(BuildContext context) {
    final card = data.cardById(purchase.cardId);
    final color = Color(card?.accentColor ?? 0xFF66757F);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(
              purchase.source == PurchaseSource.email
                  ? _transactionKindIcon(purchase.kind)
                  : Icons.edit_note_outlined,
              color: color,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  purchase.merchant,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  '${card?.name ?? 'Unknown card'} · ${_dateShort.format(purchase.purchasedAt)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${purchase.kind == TransactionKind.income || purchase.kind == TransactionKind.transferIn || purchase.kind == TransactionKind.refund || purchase.kind == TransactionKind.cardPayment ? '+' : '-'}${_currencyMoney(purchase.amount, purchase.currency)}',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color:
                      purchase.kind == TransactionKind.income ||
                          purchase.kind == TransactionKind.refund
                      ? _green
                      : _ink,
                ),
              ),
              Text(
                _categoryLabel(purchase.category),
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
              if (purchase.needsReview)
                const Text(
                  'Review',
                  style: TextStyle(color: _gold, fontSize: 12),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaymentHistoryRow extends StatelessWidget {
  const _PaymentHistoryRow({required this.data, required this.payment});

  final DebtAppData data;
  final CardPayment payment;

  @override
  Widget build(BuildContext context) {
    final card = data.cardById(payment.cardId);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline, color: _green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card?.name ?? 'Unknown card',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  '${payment.note} · ${_dateShort.format(payment.paidAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            _money.format(payment.amount),
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class InsightsView extends StatelessWidget {
  const InsightsView({
    super.key,
    required this.data,
    required this.onEditProfile,
    required this.onEditBudget,
    required this.onExportCalendar,
  });

  final DebtAppData data;
  final VoidCallback onEditProfile;
  final VoidCallback onEditBudget;
  final VoidCallback onExportCalendar;

  @override
  Widget build(BuildContext context) {
    final analytics = buildAnalytics(data.purchases);
    final hasSalary = data.settings.monthlySalary > 0;
    final committed = data.settings.plannedMonthlyDebtPayment > 0
        ? data.settings.plannedMonthlyDebtPayment
        : data.totalMinimumDue;
    final schedule = buildPayoffSchedule(
      cards: data.cards,
      loans: data.loans,
      monthlyBudgetDop: committed,
      exchangeRateDopPerUsd: data.settings.exchangeRateDopPerUsd,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        const _SectionHeader(title: 'Insights'),
        const SizedBox(height: 10),
        _InsightsSummary(analytics: analytics),
        const SizedBox(height: 18),
        const _SectionHeader(
          title: 'Spending by category',
          trailing: 'Last 6 months',
        ),
        const SizedBox(height: 8),
        _CategoryChart(analytics: analytics),
        const SizedBox(height: 18),
        const _SectionHeader(title: 'Monthly spending'),
        const SizedBox(height: 8),
        _MonthlyChart(values: analytics.monthlyTotals),
        const SizedBox(height: 18),
        const _SectionHeader(title: 'Top places'),
        const SizedBox(height: 8),
        _SimpleRankedChart(values: analytics.merchantTotals),
        const SizedBox(height: 18),
        const _SectionHeader(title: 'Spending by day'),
        const SizedBox(height: 8),
        _WeekdayChart(values: analytics.weekdayTotals),
        const SizedBox(height: 22),
        _SectionHeader(
          title: 'Debt-free plan',
          trailing: TextButton.icon(
            onPressed: onEditProfile,
            icon: const Icon(Icons.edit_outlined, size: 17),
            label: Text(hasSalary ? 'Edit income' : 'Set income'),
          ),
        ),
        const SizedBox(height: 8),
        _PayoffPlannerCard(
          data: data,
          schedule: schedule,
          onEditBudget: onEditBudget,
          onExportCalendar: onExportCalendar,
        ),
      ],
    );
  }
}

class _InsightsSummary extends StatelessWidget {
  const _InsightsSummary({required this.analytics});

  final AnalyticsSnapshot analytics;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _InsightMetric(
            icon: Icons.shopping_bag_outlined,
            label: 'Spent',
            value: _money.format(analytics.spending),
            color: const Color(0xFF2457A7),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _InsightMetric(
            icon: Icons.local_atm_outlined,
            label: 'Cash out',
            value: _money.format(analytics.withdrawals),
            color: _gold,
          ),
        ),
      ],
    );
  }
}

class _InsightMetric extends StatelessWidget {
  const _InsightMetric({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 21),
            const SizedBox(height: 12),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _CategoryChart extends StatelessWidget {
  const _CategoryChart({required this.analytics});

  final AnalyticsSnapshot analytics;

  @override
  Widget build(BuildContext context) {
    final entries = analytics.categoryTotals.entries.take(6).toList();
    if (entries.isEmpty) {
      return const _EmptyPanel(
        icon: Icons.donut_large_outlined,
        title: 'No categorized spending yet',
        message:
            'Import email transactions or add one manually to populate analytics.',
      );
    }
    final maxValue = entries.first.value;
    return _Panel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (final entry in entries) ...[
              Row(
                children: [
                  SizedBox(
                    width: 104,
                    child: Row(
                      children: [
                        Icon(
                          _categoryIcon(entry.key),
                          size: 17,
                          color: _categoryColor(entry.key),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _categoryLabel(entry.key),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: maxValue <= 0 ? 0 : entry.value / maxValue,
                        minHeight: 9,
                        backgroundColor: const Color(0xFFF0F3F2),
                        color: _categoryColor(entry.key),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  SizedBox(
                    width: 74,
                    child: Text(
                      _money.format(entry.value),
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              if (entry != entries.last) const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}

class _MonthlyChart extends StatelessWidget {
  const _MonthlyChart({required this.values});

  final Map<DateTime, double> values;

  @override
  Widget build(BuildContext context) {
    final maxValue = values.values.fold(0.0, math.max);
    return _Panel(
      child: SizedBox(
        height: 178,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final entry in values.entries)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          entry.value <= 0 ? '' : _compactMoney(entry.value),
                          style: const TextStyle(
                            fontSize: 9,
                            color: _muted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 350),
                          height: maxValue <= 0
                              ? 4
                              : math.max(4, 104 * entry.value / maxValue),
                          decoration: BoxDecoration(
                            color: entry.key.month == DateTime.now().month
                                ? _teal
                                : const Color(0xFFB8D7D2),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          DateFormat.MMM().format(entry.key),
                          style: const TextStyle(fontSize: 10, color: _muted),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SimpleRankedChart extends StatelessWidget {
  const _SimpleRankedChart({required this.values});

  final Map<String, double> values;

  @override
  Widget build(BuildContext context) {
    final entries = values.entries.take(6).toList();
    if (entries.isEmpty) {
      return const _EmptyPanel(
        icon: Icons.storefront_outlined,
        title: 'No merchant data yet',
        message: 'Imported purchases will show your most-used places here.',
      );
    }
    final maxValue = entries.first.value;
    return _Panel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (final entry in entries) ...[
              Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(
                      entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 3,
                    child: LinearProgressIndicator(
                      value: maxValue <= 0 ? 0 : entry.value / maxValue,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                      color: _gold,
                      backgroundColor: const Color(0xFFF0F3F2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 72,
                    child: Text(
                      _compactMoney(entry.value),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              if (entry != entries.last) const SizedBox(height: 13),
            ],
          ],
        ),
      ),
    );
  }
}

class _WeekdayChart extends StatelessWidget {
  const _WeekdayChart({required this.values});

  final Map<int, double> values;

  @override
  Widget build(BuildContext context) {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final maxValue = values.values.fold(0.0, math.max);
    return _Panel(
      child: SizedBox(
        height: 142,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var day = 1; day <= 7; day++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: maxValue <= 0
                              ? 4
                              : math.max(4, 82 * (values[day] ?? 0) / maxValue),
                          decoration: BoxDecoration(
                            color: day >= 6 ? _gold : _teal,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          labels[day - 1],
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PayoffPlannerCard extends StatelessWidget {
  const _PayoffPlannerCard({
    required this.data,
    required this.schedule,
    required this.onEditBudget,
    required this.onExportCalendar,
  });

  final DebtAppData data;
  final PayoffSchedule schedule;
  final VoidCallback onEditBudget;
  final VoidCallback onExportCalendar;

  @override
  Widget build(BuildContext context) {
    if (data.totalDebt <= 0) {
      return const _EmptyPanel(
        icon: Icons.verified_outlined,
        title: 'No debt to schedule',
        message:
            'Add or import credit balances and loans to build a payoff plan.',
      );
    }
    final salaryMissing = data.settings.monthlySalary <= 0;
    final feasible =
        salaryMissing ||
        schedule.monthlyBudgetDop <=
            data.settings.monthlySalary -
                data.settings.monthlyEssentialExpenses +
                0.01;
    return _Panel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        schedule.completed
                            ? '${schedule.durationMonths} months'
                            : 'Plan needs adjustment',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        schedule.completed
                            ? 'Estimated debt-free timeline'
                            : 'Payment does not clear debt within 30 years',
                        style: TextStyle(
                          color: feasible ? _muted : _coral,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _money.format(schedule.monthlyBudgetDop),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const Text(
                      'per month',
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (salaryMissing)
              const _InlineNotice(
                icon: Icons.info_outline,
                text:
                    'Add your monthly salary and essential expenses to calculate paycheck impact.',
                color: _gold,
              )
            else
              _InlineNotice(
                icon: feasible
                    ? Icons.check_circle_outline
                    : Icons.warning_amber_rounded,
                text: feasible
                    ? '${(schedule.monthlyBudgetDop / data.settings.monthlySalary * 100).toStringAsFixed(1)}% of monthly take-home pay · about ${_money.format(schedule.totalInterestDop)} projected interest'
                    : 'This commitment is above income after essential expenses. Lower it or update income.',
                color: feasible ? _green : _coral,
              ),
            const SizedBox(height: 16),
            const Text(
              'Next payment cycle',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            if (schedule.months.isNotEmpty)
              for (final payment in schedule.months.first.payments) ...[
                Row(
                  children: [
                    Container(width: 3, height: 38, color: _teal),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            payment.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            'Pay ${_dateShort.format(payment.date)} · ${payment.reason}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      _currencyMoney(payment.nativeAmount, payment.currency),
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
                if (payment != schedule.months.first.payments.last)
                  const Divider(height: 18),
              ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onEditBudget,
                    icon: const Icon(Icons.tune),
                    label: const Text('Commitment'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onExportCalendar,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: const Text('Calendar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.data,
    required this.syncing,
    this.syncStatus = '',
    required this.onNotificationsChanged,
    required this.onTestNotification,
    required this.onBackgroundEmailSyncChanged,
    required this.onConnectEmail,
    required this.onEmailSync,
    required this.onImportEmail,
    required this.onRunBackgroundSyncNow,
    required this.onDisconnectEmail,
    required this.onResetData,
  });

  final DebtAppData data;
  final bool syncing;
  final String syncStatus;
  final ValueChanged<bool> onNotificationsChanged;
  final VoidCallback onTestNotification;
  final ValueChanged<bool> onBackgroundEmailSyncChanged;
  final VoidCallback onConnectEmail;
  final VoidCallback onEmailSync;
  final VoidCallback onImportEmail;
  final VoidCallback onRunBackgroundSyncNow;
  final VoidCallback onDisconnectEmail;
  final VoidCallback onResetData;

  @override
  Widget build(BuildContext context) {
    final settings = data.settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
      children: [
        const _SectionHeader(title: 'Settings'),
        const SizedBox(height: 10),
        _Panel(
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                title: const Text(
                  'Due-date reminders',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text('Suggested payment near each due date'),
                value: settings.notificationsEnabled,
                activeThumbColor: _teal,
                onChanged: onNotificationsChanged,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Send test reminder'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onTestNotification,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionHeader(title: 'Email sync'),
        const SizedBox(height: 8),
        _Panel(
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  settings.emailSyncEnabled
                      ? Icons.mark_email_read_outlined
                      : Icons.alternate_email,
                  color: settings.emailSyncEnabled ? _green : _muted,
                ),
                title: Text(
                  settings.connectedEmail ?? 'Email not connected',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  settings.emailSyncEnabled && settings.lastEmailSyncAt == null
                      ? 'Connected with ${_emailProviderLabel(settings.connectedEmailProvider)}'
                      : settings.lastEmailSyncAt == null
                      ? 'Choose Gmail, Outlook, or iCloud Mail'
                      : 'Last sync ${_dateShort.format(settings.lastEmailSyncAt!)}',
                ),
              ),
              if (settings.lastEmailSyncStatus != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 0, 14, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      settings.lastEmailSyncStatus!,
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ),
                ),
              const Divider(height: 1),
              ListTile(
                enabled: !syncing,
                leading: settings.emailSyncEnabled
                    ? const Icon(Icons.refresh)
                    : const Icon(Icons.login),
                title: Text(
                  settings.emailSyncEnabled
                      ? 'Change email connection'
                      : 'Connect email',
                ),
                subtitle: const Text('Choose your email provider securely'),
                trailing: const Icon(Icons.chevron_right),
                onTap: syncing ? null : onConnectEmail,
              ),
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                title: const Text(
                  'Daily background email sync',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  kIsWeb
                      ? 'Available in the installed iPhone app'
                      : settings.lastBackgroundEmailSyncAt == null
                      ? 'Runs when iOS grants Background App Refresh'
                      : 'Last background check ${_dateShort.format(settings.lastBackgroundEmailSyncAt!)}',
                ),
                value:
                    !kIsWeb &&
                    settings.emailSyncEnabled &&
                    settings.backgroundEmailSyncEnabled,
                activeThumbColor: _teal,
                onChanged: !kIsWeb && settings.emailSyncEnabled
                    ? onBackgroundEmailSyncChanged
                    : null,
              ),
              const Divider(height: 1),
              ListTile(
                enabled: !syncing,
                leading: syncing
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                title: Text(syncing ? 'Syncing email' : 'Update from email'),
                subtitle: syncing ? Text(syncStatus) : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: syncing ? null : onEmailSync,
              ),
              ListTile(
                enabled: !syncing && settings.emailSyncEnabled,
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Import cards & purchases'),
                subtitle: const Text(
                  'Choose a range; detect cards from email last four digits',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: !syncing && settings.emailSyncEnabled
                    ? onImportEmail
                    : null,
              ),
              ListTile(
                enabled: !syncing && !kIsWeb && settings.emailSyncEnabled,
                leading: const Icon(Icons.update),
                title: const Text('Run daily sync now'),
                trailing: const Icon(Icons.chevron_right),
                onTap: !syncing && !kIsWeb && settings.emailSyncEnabled
                    ? onRunBackgroundSyncNow
                    : null,
              ),
              if (settings.emailSyncEnabled)
                ListTile(
                  leading: const Icon(Icons.link_off, color: _coral),
                  title: const Text('Disconnect email'),
                  onTap: syncing ? null : onDisconnectEmail,
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionHeader(title: 'Data'),
        const SizedBox(height: 8),
        _Panel(
          child: ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Clear all local data'),
            subtitle: const Text('Cards, purchases, paychecks, and payments'),
            trailing: const Icon(Icons.chevron_right),
            onTap: syncing ? null : onResetData,
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: child,
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: _muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: const TextStyle(color: _muted, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Object? trailing;

  @override
  Widget build(BuildContext context) {
    final trailingWidget = trailing is Widget
        ? trailing as Widget
        : Text(
            trailing?.toString() ?? '',
            style: const TextStyle(
              color: _muted,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          );
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
          ),
        ),
        trailingWidget,
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
    this.dark = false,
  });

  final String label;
  final Color color;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: dark
            ? color.withValues(alpha: 0.22)
            : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: dark ? Colors.white : color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DatePill extends StatelessWidget {
  const _DatePill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label $value',
        style: const TextStyle(
          color: _ink,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 16, 18, bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _MoneyField extends StatelessWidget {
  const _MoneyField({
    required this.controller,
    required this.label,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, prefixText: '\$ '),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
    );
  }
}

double _parseMoney(String value) {
  return double.tryParse(
        value.replaceAll(',', '').replaceAll('\$', '').trim(),
      ) ??
      0;
}

String _currencyMoney(double value, String currency) {
  if (currency.toUpperCase() == 'USD') {
    return NumberFormat.currency(
      symbol: 'US\$',
      decimalDigits: 2,
    ).format(value);
  }
  return _money.format(value);
}

int _parseDay(String value) {
  final parsed = int.tryParse(value.trim()) ?? 1;
  return parsed.clamp(1, 31);
}

String _emailProviderLabel(EmailProvider? provider) => switch (provider) {
  EmailProvider.gmail => 'Gmail',
  EmailProvider.outlook => 'Outlook',
  EmailProvider.icloud => 'iCloud Mail',
  null => 'email',
};

String _transactionKindLabel(TransactionKind kind) => switch (kind) {
  TransactionKind.purchase => 'Purchase',
  TransactionKind.withdrawal => 'Cash withdrawal',
  TransactionKind.cardPayment => 'Card payment',
  TransactionKind.income => 'Income / salary',
  TransactionKind.transferIn => 'Transfer received',
  TransactionKind.transferOut => 'Transfer sent',
  TransactionKind.adjustment => 'Balance correction',
  TransactionKind.refund => 'Refund',
};

IconData _transactionKindIcon(TransactionKind kind) => switch (kind) {
  TransactionKind.purchase => Icons.shopping_bag_outlined,
  TransactionKind.withdrawal => Icons.local_atm_outlined,
  TransactionKind.cardPayment => Icons.credit_score_outlined,
  TransactionKind.income => Icons.payments_outlined,
  TransactionKind.transferIn => Icons.south_west,
  TransactionKind.transferOut => Icons.north_east,
  TransactionKind.adjustment => Icons.tune_outlined,
  TransactionKind.refund => Icons.keyboard_return_outlined,
};

String _categoryLabel(SpendingCategory category) => switch (category) {
  SpendingCategory.food => 'Food',
  SpendingCategory.transportation => 'Transport',
  SpendingCategory.groceries => 'Groceries',
  SpendingCategory.shopping => 'Shopping',
  SpendingCategory.bills => 'Bills',
  SpendingCategory.health => 'Health',
  SpendingCategory.entertainment => 'Entertainment',
  SpendingCategory.travel => 'Travel',
  SpendingCategory.cash => 'Cash',
  SpendingCategory.income => 'Income',
  SpendingCategory.payments => 'Payments',
  SpendingCategory.transfers => 'Transfers',
  SpendingCategory.other => 'Other',
};

IconData _categoryIcon(SpendingCategory category) => switch (category) {
  SpendingCategory.food => Icons.restaurant_outlined,
  SpendingCategory.transportation => Icons.directions_car_outlined,
  SpendingCategory.groceries => Icons.local_grocery_store_outlined,
  SpendingCategory.shopping => Icons.shopping_bag_outlined,
  SpendingCategory.bills => Icons.receipt_long_outlined,
  SpendingCategory.health => Icons.health_and_safety_outlined,
  SpendingCategory.entertainment => Icons.movie_outlined,
  SpendingCategory.travel => Icons.flight_outlined,
  SpendingCategory.cash => Icons.local_atm_outlined,
  SpendingCategory.income => Icons.payments_outlined,
  SpendingCategory.payments => Icons.credit_score_outlined,
  SpendingCategory.transfers => Icons.swap_horiz,
  SpendingCategory.other => Icons.category_outlined,
};

Color _categoryColor(SpendingCategory category) => switch (category) {
  SpendingCategory.food => const Color(0xFFE0563F),
  SpendingCategory.transportation => const Color(0xFF2457A7),
  SpendingCategory.groceries => const Color(0xFF228B5B),
  SpendingCategory.shopping => const Color(0xFF8A56A6),
  SpendingCategory.bills => const Color(0xFFCF7B1E),
  SpendingCategory.health => const Color(0xFFCF3F69),
  SpendingCategory.entertainment => const Color(0xFF7651C8),
  SpendingCategory.travel => const Color(0xFF178CA4),
  SpendingCategory.cash => const Color(0xFF6D7680),
  SpendingCategory.income => _green,
  SpendingCategory.payments => _teal,
  SpendingCategory.transfers => const Color(0xFF476B5D),
  SpendingCategory.other => _muted,
};

String _compactMoney(double value) {
  if (value >= 1000000) return 'RD\$${(value / 1000000).toStringAsFixed(1)}m';
  if (value >= 1000) return 'RD\$${(value / 1000).toStringAsFixed(0)}k';
  return 'RD\$${value.toStringAsFixed(0)}';
}

class _StatementCandidate {
  _StatementCandidate({
    required this.index,
    required this.source,
    required this.currency,
    required this.accountType,
    required this.name,
    required this.lastFour,
    required this.balance,
    required this.minimumDue,
    required this.installmentBalance,
    required this.installmentMonthlyPayment,
    required this.cutoffDay,
    required this.dueDay,
    required this.existing,
  });

  factory _StatementCandidate.fromDraft({
    required int index,
    required StatementDraft draft,
    required String currency,
    required CreditCard? existing,
  }) {
    final statementBalance = currency == 'USD'
        ? draft.statementBalanceUsd
        : draft.statementBalanceDop;
    final availableBalance = currency == 'USD'
        ? draft.availableBalanceUsd
        : draft.availableBalanceDop;
    final minimum = currency == 'USD'
        ? draft.minimumDueUsd
        : draft.minimumDueDop;
    final currentTotal = draft.currentTotalDop;
    final currentTotalForCurrency = currency == 'USD'
        ? draft.currentTotalUsd
        : currentTotal;
    final monthlyCuota = currency == 'DOP'
        ? draft.installmentMonthlyPayment ??
              existing?.installmentMonthlyPayment ??
              0
        : 0;
    // A statement balance minus the current balance is not a reliable cuota
    // total. Keep cuotas only when the statement explicitly reports them.
    final installmentBalance =
        draft.installmentBalance ?? existing?.installmentBalance ?? 0;
    final resolvedLastFour = draft.lastFour.isEmpty
        ? existing?.lastFour ?? ''
        : draft.lastFour;
    final importedName = [
      if (draft.bankName.trim().isNotEmpty) draft.bankName.trim(),
      if (draft.accountName.trim().isNotEmpty) draft.accountName.trim(),
      if (resolvedLastFour.isNotEmpty) resolvedLastFour,
    ].join(' - ');
    return _StatementCandidate(
      index: index,
      source: draft,
      currency: currency,
      accountType: existing?.accountType ?? draft.accountType,
      name: importedName.isEmpty ? 'Imported account $currency' : importedName,
      lastFour: resolvedLastFour,
      balance: draft.accountType == AccountType.debit
          ? availableBalance ??
                currentTotalForCurrency ??
                existing?.balance ??
                0
          : currentTotalForCurrency ??
                statementBalance ??
                existing?.balance ??
                0,
      minimumDue: minimum ?? existing?.minimumDue ?? 0,
      installmentBalance: installmentBalance.toDouble(),
      installmentMonthlyPayment: monthlyCuota.toDouble(),
      cutoffDay: draft.cutoffDate?.day ?? existing?.cutoffDay ?? 1,
      dueDay: draft.dueDate?.day ?? existing?.dueDay ?? 1,
      existing: existing,
    );
  }

  final int index;
  final StatementDraft source;
  final String currency;
  final AccountType accountType;
  final String name;
  final String lastFour;
  final double balance;
  final double minimumDue;
  final double installmentBalance;
  final double installmentMonthlyPayment;
  final int cutoffDay;
  final int dueDay;
  final CreditCard? existing;

  String get key => '$index-$currency';
}
