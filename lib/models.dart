import 'dart:math' as math;

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

int daysInMonth(int year, int month) {
  final firstOfNextMonth = month == 12
      ? DateTime(year + 1, 1)
      : DateTime(year, month + 1);
  return firstOfNextMonth.subtract(const Duration(days: 1)).day;
}

DateTime monthlyDate(int year, int month, int day, {int hour = 9}) {
  final safeDay = math.min(math.max(day, 1), daysInMonth(year, month));
  return DateTime(year, month, safeDay, hour);
}

DateTime nextMonthlyDate(int day, DateTime from, {int hour = 9}) {
  final today = dateOnly(from);
  var candidate = monthlyDate(from.year, from.month, day, hour: hour);
  if (dateOnly(candidate).isBefore(today)) {
    final nextMonth = from.month == 12 ? 1 : from.month + 1;
    final nextYear = from.month == 12 ? from.year + 1 : from.year;
    candidate = monthlyDate(nextYear, nextMonth, day, hour: hour);
  }
  return candidate;
}

double moneyFromJson(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

double amountInDop(double amount, String currency, double exchangeRate) =>
    currency.toUpperCase() == 'USD' ? amount * exchangeRate : amount;

enum PurchaseSource {
  manual,
  email;

  static PurchaseSource fromJson(String? value) {
    return PurchaseSource.values.firstWhere(
      (source) => source.name == value,
      orElse: () => PurchaseSource.manual,
    );
  }
}

enum AccountType {
  credit,
  debit;

  static AccountType fromJson(String? value) => AccountType.values.firstWhere(
    (type) => type.name == value,
    orElse: () => AccountType.credit,
  );
}

enum EmailProvider {
  gmail,
  outlook,
  icloud;

  static EmailProvider? fromJson(String? value) {
    if (value == null) return null;
    for (final provider in EmailProvider.values) {
      if (provider.name == value) return provider;
    }
    return null;
  }
}

enum PaymentBudgetMode {
  amount,
  percent;

  static PaymentBudgetMode fromJson(String? value) =>
      PaymentBudgetMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => PaymentBudgetMode.amount,
      );
}

enum TransactionKind {
  purchase,
  withdrawal,
  cardPayment,
  income,
  transferIn,
  transferOut,
  adjustment,
  refund;

  static TransactionKind fromJson(String? value) =>
      TransactionKind.values.firstWhere(
        (kind) => kind.name == value,
        orElse: () => TransactionKind.purchase,
      );
}

enum SpendingCategory {
  food,
  transportation,
  groceries,
  shopping,
  bills,
  health,
  entertainment,
  travel,
  cash,
  income,
  payments,
  transfers,
  other;

  static SpendingCategory fromJson(String? value) =>
      SpendingCategory.values.firstWhere(
        (category) => category.name == value,
        orElse: () => SpendingCategory.other,
      );
}

class CreditCard {
  const CreditCard({
    required this.id,
    required this.name,
    required this.lastFour,
    required this.balance,
    required this.creditLimit,
    required this.apr,
    required this.cutoffDay,
    required this.dueDay,
    required this.minimumDue,
    required this.accentColor,
    this.lastPaymentDate,
    this.reminderDaysBefore = 3,
    this.emailMatchTerms = const [],
    this.associatedDebitCardLastFours = const [],
    this.accountType = AccountType.credit,
    this.currency = 'DOP',
    this.installmentBalance = 0,
    this.installmentMonthlyPayment = 0,
    this.needsReview = false,
    this.calibratedCutoffDate,
    this.calibratedDueDate,
  });

  final String id;
  final String name;
  final String lastFour;
  final double balance;
  final double creditLimit;
  final double apr;
  final int cutoffDay;
  final int dueDay;
  final double minimumDue;
  final int accentColor;
  final DateTime? lastPaymentDate;
  final int reminderDaysBefore;
  final List<String> emailMatchTerms;

  /// Debit-card numbers that spend from this debit/checking account.
  /// They are identifiers only; they never represent a second balance.
  final List<String> associatedDebitCardLastFours;
  final AccountType accountType;
  final String currency;
  final double installmentBalance;
  final double installmentMonthlyPayment;
  final bool needsReview;
  final DateTime? calibratedCutoffDate;
  final DateTime? calibratedDueDate;

  bool get isCredit => accountType == AccountType.credit;
  bool get isDebit => accountType == AccountType.debit;
  double get totalOwed => isCredit ? balance + installmentBalance : 0;

  bool matchesIdentifier(String value) {
    final normalized = _lastFourDigits(value);
    if (normalized.isEmpty) return false;
    return _lastFourDigits(lastFour) == normalized ||
        (isDebit &&
            associatedDebitCardLastFours.any(
              (identifier) => _lastFourDigits(identifier) == normalized,
            ));
  }

  double get utilization {
    if (creditLimit <= 0) return 0;
    return (balance / creditLimit).clamp(0, 1);
  }

  DateTime nextDueDate(DateTime from) {
    final calibrated = calibratedDueDate;
    if (calibrated != null) {
      final age = dateOnly(from).difference(dateOnly(calibrated)).inDays;
      if (age <= 35) return dateOnly(calibrated);
    }
    return nextMonthlyDate(dueDay, from);
  }

  DateTime nextCutoffDate(DateTime from) {
    final calibrated = calibratedCutoffDate;
    if (calibrated != null) {
      final age = dateOnly(from).difference(dateOnly(calibrated)).inDays;
      if (age <= 35) return dateOnly(calibrated);
    }
    return nextMonthlyDate(cutoffDay, from);
  }

  int daysUntilDue(DateTime from) =>
      dateOnly(nextDueDate(from)).difference(dateOnly(from)).inDays;

  CreditCard copyWith({
    String? id,
    String? name,
    String? lastFour,
    double? balance,
    double? creditLimit,
    double? apr,
    int? cutoffDay,
    int? dueDay,
    double? minimumDue,
    int? accentColor,
    DateTime? lastPaymentDate,
    bool clearLastPaymentDate = false,
    int? reminderDaysBefore,
    List<String>? emailMatchTerms,
    List<String>? associatedDebitCardLastFours,
    AccountType? accountType,
    String? currency,
    double? installmentBalance,
    double? installmentMonthlyPayment,
    bool? needsReview,
    DateTime? calibratedCutoffDate,
    DateTime? calibratedDueDate,
    bool clearCalibratedDates = false,
  }) {
    return CreditCard(
      id: id ?? this.id,
      name: name ?? this.name,
      lastFour: lastFour ?? this.lastFour,
      balance: balance ?? this.balance,
      creditLimit: creditLimit ?? this.creditLimit,
      apr: apr ?? this.apr,
      cutoffDay: cutoffDay ?? this.cutoffDay,
      dueDay: dueDay ?? this.dueDay,
      minimumDue: minimumDue ?? this.minimumDue,
      accentColor: accentColor ?? this.accentColor,
      lastPaymentDate: clearLastPaymentDate
          ? null
          : lastPaymentDate ?? this.lastPaymentDate,
      reminderDaysBefore: reminderDaysBefore ?? this.reminderDaysBefore,
      emailMatchTerms: emailMatchTerms ?? this.emailMatchTerms,
      associatedDebitCardLastFours:
          associatedDebitCardLastFours ?? this.associatedDebitCardLastFours,
      accountType: accountType ?? this.accountType,
      currency: currency ?? this.currency,
      installmentBalance: installmentBalance ?? this.installmentBalance,
      installmentMonthlyPayment:
          installmentMonthlyPayment ?? this.installmentMonthlyPayment,
      needsReview: needsReview ?? this.needsReview,
      calibratedCutoffDate: clearCalibratedDates
          ? null
          : calibratedCutoffDate ?? this.calibratedCutoffDate,
      calibratedDueDate: clearCalibratedDates
          ? null
          : calibratedDueDate ?? this.calibratedDueDate,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'lastFour': lastFour,
    'balance': balance,
    'creditLimit': creditLimit,
    'apr': apr,
    'cutoffDay': cutoffDay,
    'dueDay': dueDay,
    'minimumDue': minimumDue,
    'accentColor': accentColor,
    'lastPaymentDate': lastPaymentDate?.toIso8601String(),
    'reminderDaysBefore': reminderDaysBefore,
    'emailMatchTerms': emailMatchTerms,
    'associatedDebitCardLastFours': associatedDebitCardLastFours,
    'accountType': accountType.name,
    'currency': currency,
    'installmentBalance': installmentBalance,
    'installmentMonthlyPayment': installmentMonthlyPayment,
    'needsReview': needsReview,
    'calibratedCutoffDate': calibratedCutoffDate?.toIso8601String(),
    'calibratedDueDate': calibratedDueDate?.toIso8601String(),
  };

  factory CreditCard.fromJson(Map<String, Object?> json) {
    return CreditCard(
      id: json['id'] as String,
      name: json['name'] as String,
      lastFour: json['lastFour'] as String? ?? '',
      balance: moneyFromJson(json['balance']),
      creditLimit: moneyFromJson(json['creditLimit']),
      apr: moneyFromJson(json['apr']),
      cutoffDay: json['cutoffDay'] as int? ?? 1,
      dueDay: json['dueDay'] as int? ?? 1,
      minimumDue: moneyFromJson(json['minimumDue']),
      accentColor: json['accentColor'] as int? ?? 0xFF0F766E,
      lastPaymentDate: json['lastPaymentDate'] is String
          ? DateTime.tryParse(json['lastPaymentDate'] as String)
          : null,
      reminderDaysBefore: json['reminderDaysBefore'] as int? ?? 3,
      emailMatchTerms: (json['emailMatchTerms'] as List<dynamic>? ?? const [])
          .map((term) => term.toString())
          .toList(),
      associatedDebitCardLastFours:
          (json['associatedDebitCardLastFours'] as List<dynamic>? ?? const [])
              .map((identifier) => identifier.toString())
              .toList(),
      accountType: AccountType.fromJson(json['accountType'] as String?),
      currency: json['currency'] as String? ?? 'DOP',
      installmentBalance: moneyFromJson(json['installmentBalance']),
      installmentMonthlyPayment: moneyFromJson(
        json['installmentMonthlyPayment'],
      ),
      needsReview: json['needsReview'] as bool? ?? false,
      calibratedCutoffDate: json['calibratedCutoffDate'] is String
          ? DateTime.tryParse(json['calibratedCutoffDate'] as String)
          : null,
      calibratedDueDate: json['calibratedDueDate'] is String
          ? DateTime.tryParse(json['calibratedDueDate'] as String)
          : null,
    );
  }
}

String _lastFourDigits(String value) {
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits.length <= 4) return digits;
  return digits.substring(digits.length - 4);
}

class Purchase {
  const Purchase({
    required this.id,
    required this.cardId,
    required this.merchant,
    required this.amount,
    required this.purchasedAt,
    required this.source,
    this.subject,
    this.sourceMessageId,
    this.needsReview = false,
    this.kind = TransactionKind.purchase,
    this.category = SpendingCategory.other,
    this.currency = 'DOP',
    this.transferReference,
    this.relatedCardId,
  });

  final String id;
  final String cardId;
  final String merchant;
  final double amount;
  final DateTime purchasedAt;
  final PurchaseSource source;
  final String? subject;
  final String? sourceMessageId;
  final bool needsReview;
  final TransactionKind kind;
  final SpendingCategory category;
  final String currency;
  final String? transferReference;
  final String? relatedCardId;

  Purchase copyWith({
    String? id,
    String? cardId,
    String? merchant,
    double? amount,
    DateTime? purchasedAt,
    PurchaseSource? source,
    String? subject,
    String? sourceMessageId,
    bool? needsReview,
    TransactionKind? kind,
    SpendingCategory? category,
    String? currency,
    String? transferReference,
    String? relatedCardId,
    bool clearRelatedCardId = false,
  }) {
    return Purchase(
      id: id ?? this.id,
      cardId: cardId ?? this.cardId,
      merchant: merchant ?? this.merchant,
      amount: amount ?? this.amount,
      purchasedAt: purchasedAt ?? this.purchasedAt,
      source: source ?? this.source,
      subject: subject ?? this.subject,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      needsReview: needsReview ?? this.needsReview,
      kind: kind ?? this.kind,
      category: category ?? this.category,
      currency: currency ?? this.currency,
      transferReference: transferReference ?? this.transferReference,
      relatedCardId: clearRelatedCardId
          ? null
          : relatedCardId ?? this.relatedCardId,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'cardId': cardId,
    'merchant': merchant,
    'amount': amount,
    'purchasedAt': purchasedAt.toIso8601String(),
    'source': source.name,
    'subject': subject,
    'sourceMessageId': sourceMessageId,
    'needsReview': needsReview,
    'kind': kind.name,
    'category': category.name,
    'currency': currency,
    'transferReference': transferReference,
    'relatedCardId': relatedCardId,
  };

  factory Purchase.fromJson(Map<String, Object?> json) {
    return Purchase(
      id: json['id'] as String,
      cardId: json['cardId'] as String,
      merchant: json['merchant'] as String? ?? 'Unknown merchant',
      amount: moneyFromJson(json['amount']),
      purchasedAt:
          DateTime.tryParse(json['purchasedAt'] as String? ?? '') ??
          DateTime.now(),
      source: PurchaseSource.fromJson(json['source'] as String?),
      subject: json['subject'] as String?,
      sourceMessageId: json['sourceMessageId'] as String?,
      needsReview: json['needsReview'] as bool? ?? false,
      kind: TransactionKind.fromJson(json['kind'] as String?),
      category: SpendingCategory.fromJson(json['category'] as String?),
      currency: json['currency'] as String? ?? 'DOP',
      transferReference: json['transferReference'] as String?,
      relatedCardId: json['relatedCardId'] as String?,
    );
  }
}

class Loan {
  const Loan({
    required this.id,
    required this.name,
    required this.balance,
    required this.apr,
    required this.minimumPayment,
    required this.dueDay,
    this.reminderDaysBefore = 3,
    this.currency = 'DOP',
  });

  final String id;
  final String name;
  final double balance;
  final double apr;
  final double minimumPayment;
  final int dueDay;
  final int reminderDaysBefore;
  final String currency;

  Loan copyWith({
    String? id,
    String? name,
    double? balance,
    double? apr,
    double? minimumPayment,
    int? dueDay,
    int? reminderDaysBefore,
    String? currency,
  }) => Loan(
    id: id ?? this.id,
    name: name ?? this.name,
    balance: balance ?? this.balance,
    apr: apr ?? this.apr,
    minimumPayment: minimumPayment ?? this.minimumPayment,
    dueDay: dueDay ?? this.dueDay,
    reminderDaysBefore: reminderDaysBefore ?? this.reminderDaysBefore,
    currency: currency ?? this.currency,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'balance': balance,
    'apr': apr,
    'minimumPayment': minimumPayment,
    'dueDay': dueDay,
    'reminderDaysBefore': reminderDaysBefore,
    'currency': currency,
  };

  factory Loan.fromJson(Map<String, Object?> json) => Loan(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Loan',
    balance: moneyFromJson(json['balance']),
    apr: moneyFromJson(json['apr']),
    minimumPayment: moneyFromJson(json['minimumPayment']),
    dueDay: json['dueDay'] as int? ?? 1,
    reminderDaysBefore: json['reminderDaysBefore'] as int? ?? 3,
    currency: json['currency'] as String? ?? 'DOP',
  );
}

class Paycheck {
  const Paycheck({
    required this.id,
    required this.amount,
    required this.receivedAt,
    this.note,
  });

  final String id;
  final double amount;
  final DateTime receivedAt;
  final String? note;

  Map<String, Object?> toJson() => {
    'id': id,
    'amount': amount,
    'receivedAt': receivedAt.toIso8601String(),
    'note': note,
  };

  factory Paycheck.fromJson(Map<String, Object?> json) {
    return Paycheck(
      id: json['id'] as String,
      amount: moneyFromJson(json['amount']),
      receivedAt:
          DateTime.tryParse(json['receivedAt'] as String? ?? '') ??
          DateTime.now(),
      note: json['note'] as String?,
    );
  }
}

class CardPayment {
  const CardPayment({
    required this.id,
    required this.cardId,
    required this.amount,
    required this.paidAt,
    required this.note,
  });

  final String id;
  final String cardId;
  final double amount;
  final DateTime paidAt;
  final String note;

  Map<String, Object?> toJson() => {
    'id': id,
    'cardId': cardId,
    'amount': amount,
    'paidAt': paidAt.toIso8601String(),
    'note': note,
  };

  factory CardPayment.fromJson(Map<String, Object?> json) {
    return CardPayment(
      id: json['id'] as String,
      cardId: json['cardId'] as String,
      amount: moneyFromJson(json['amount']),
      paidAt:
          DateTime.tryParse(json['paidAt'] as String? ?? '') ?? DateTime.now(),
      note: json['note'] as String? ?? 'Payment',
    );
  }
}

class AppSettings {
  const AppSettings({
    this.notificationsEnabled = true,
    this.emailSyncEnabled = false,
    this.backgroundEmailSyncEnabled = true,
    this.defaultReminderDaysBefore = 3,
    this.reminderHour = 9,
    this.connectedEmail,
    this.connectedEmailProvider,
    this.lastEmailSyncAt,
    this.lastBackgroundEmailSyncAt,
    this.lastEmailSyncStatus,
    this.monthlySalary = 0,
    this.monthlyEssentialExpenses = 0,
    this.targetPayoffMonths = 12,
    this.lastCalibrationAt,
    this.paymentBudgetMode = PaymentBudgetMode.percent,
    this.monthlyDebtBudget = 0,
    this.salaryDebtPercent = 25,
    this.exchangeRateDopPerUsd = 60,
  });

  final bool notificationsEnabled;
  final bool emailSyncEnabled;
  final bool backgroundEmailSyncEnabled;
  final int defaultReminderDaysBefore;
  final int reminderHour;
  final String? connectedEmail;
  final EmailProvider? connectedEmailProvider;
  final DateTime? lastEmailSyncAt;
  final DateTime? lastBackgroundEmailSyncAt;
  final String? lastEmailSyncStatus;
  final double monthlySalary;
  final double monthlyEssentialExpenses;
  final int targetPayoffMonths;
  final DateTime? lastCalibrationAt;
  final PaymentBudgetMode paymentBudgetMode;
  final double monthlyDebtBudget;
  final double salaryDebtPercent;
  final double exchangeRateDopPerUsd;

  double get plannedMonthlyDebtPayment => switch (paymentBudgetMode) {
    PaymentBudgetMode.amount => monthlyDebtBudget,
    PaymentBudgetMode.percent => monthlySalary * salaryDebtPercent / 100,
  };

  AppSettings copyWith({
    bool? notificationsEnabled,
    bool? emailSyncEnabled,
    bool? backgroundEmailSyncEnabled,
    int? defaultReminderDaysBefore,
    int? reminderHour,
    String? connectedEmail,
    bool clearConnectedEmail = false,
    EmailProvider? connectedEmailProvider,
    bool clearConnectedEmailProvider = false,
    DateTime? lastEmailSyncAt,
    bool clearLastEmailSyncAt = false,
    DateTime? lastBackgroundEmailSyncAt,
    bool clearLastBackgroundEmailSyncAt = false,
    String? lastEmailSyncStatus,
    bool clearLastEmailSyncStatus = false,
    double? monthlySalary,
    double? monthlyEssentialExpenses,
    int? targetPayoffMonths,
    DateTime? lastCalibrationAt,
    bool clearLastCalibrationAt = false,
    PaymentBudgetMode? paymentBudgetMode,
    double? monthlyDebtBudget,
    double? salaryDebtPercent,
    double? exchangeRateDopPerUsd,
  }) {
    return AppSettings(
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      emailSyncEnabled: emailSyncEnabled ?? this.emailSyncEnabled,
      backgroundEmailSyncEnabled:
          backgroundEmailSyncEnabled ?? this.backgroundEmailSyncEnabled,
      defaultReminderDaysBefore:
          defaultReminderDaysBefore ?? this.defaultReminderDaysBefore,
      reminderHour: reminderHour ?? this.reminderHour,
      connectedEmail: clearConnectedEmail
          ? null
          : connectedEmail ?? this.connectedEmail,
      connectedEmailProvider: clearConnectedEmailProvider
          ? null
          : connectedEmailProvider ?? this.connectedEmailProvider,
      lastEmailSyncAt: clearLastEmailSyncAt
          ? null
          : lastEmailSyncAt ?? this.lastEmailSyncAt,
      lastBackgroundEmailSyncAt: clearLastBackgroundEmailSyncAt
          ? null
          : lastBackgroundEmailSyncAt ?? this.lastBackgroundEmailSyncAt,
      lastEmailSyncStatus: clearLastEmailSyncStatus
          ? null
          : lastEmailSyncStatus ?? this.lastEmailSyncStatus,
      monthlySalary: monthlySalary ?? this.monthlySalary,
      monthlyEssentialExpenses:
          monthlyEssentialExpenses ?? this.monthlyEssentialExpenses,
      targetPayoffMonths: targetPayoffMonths ?? this.targetPayoffMonths,
      lastCalibrationAt: clearLastCalibrationAt
          ? null
          : lastCalibrationAt ?? this.lastCalibrationAt,
      paymentBudgetMode: paymentBudgetMode ?? this.paymentBudgetMode,
      monthlyDebtBudget: monthlyDebtBudget ?? this.monthlyDebtBudget,
      salaryDebtPercent: salaryDebtPercent ?? this.salaryDebtPercent,
      exchangeRateDopPerUsd:
          exchangeRateDopPerUsd ?? this.exchangeRateDopPerUsd,
    );
  }

  Map<String, Object?> toJson() => {
    'notificationsEnabled': notificationsEnabled,
    'emailSyncEnabled': emailSyncEnabled,
    'backgroundEmailSyncEnabled': backgroundEmailSyncEnabled,
    'defaultReminderDaysBefore': defaultReminderDaysBefore,
    'reminderHour': reminderHour,
    'connectedEmail': connectedEmail,
    'connectedEmailProvider': connectedEmailProvider?.name,
    'lastEmailSyncAt': lastEmailSyncAt?.toIso8601String(),
    'lastBackgroundEmailSyncAt': lastBackgroundEmailSyncAt?.toIso8601String(),
    'lastEmailSyncStatus': lastEmailSyncStatus,
    'monthlySalary': monthlySalary,
    'monthlyEssentialExpenses': monthlyEssentialExpenses,
    'targetPayoffMonths': targetPayoffMonths,
    'lastCalibrationAt': lastCalibrationAt?.toIso8601String(),
    'paymentBudgetMode': paymentBudgetMode.name,
    'monthlyDebtBudget': monthlyDebtBudget,
    'salaryDebtPercent': salaryDebtPercent,
    'exchangeRateDopPerUsd': exchangeRateDopPerUsd,
  };

  factory AppSettings.fromJson(Map<String, Object?> json) {
    return AppSettings(
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      emailSyncEnabled: json['emailSyncEnabled'] as bool? ?? false,
      backgroundEmailSyncEnabled:
          json['backgroundEmailSyncEnabled'] as bool? ?? true,
      defaultReminderDaysBefore: json['defaultReminderDaysBefore'] as int? ?? 3,
      reminderHour: json['reminderHour'] as int? ?? 9,
      connectedEmail: json['connectedEmail'] as String?,
      connectedEmailProvider: EmailProvider.fromJson(
        json['connectedEmailProvider'] as String?,
      ),
      lastEmailSyncAt: json['lastEmailSyncAt'] is String
          ? DateTime.tryParse(json['lastEmailSyncAt'] as String)
          : null,
      lastBackgroundEmailSyncAt: json['lastBackgroundEmailSyncAt'] is String
          ? DateTime.tryParse(json['lastBackgroundEmailSyncAt'] as String)
          : null,
      lastEmailSyncStatus: json['lastEmailSyncStatus'] as String?,
      monthlySalary: moneyFromJson(json['monthlySalary']),
      monthlyEssentialExpenses: moneyFromJson(json['monthlyEssentialExpenses']),
      targetPayoffMonths: json['targetPayoffMonths'] as int? ?? 12,
      lastCalibrationAt: json['lastCalibrationAt'] is String
          ? DateTime.tryParse(json['lastCalibrationAt'] as String)
          : null,
      paymentBudgetMode: PaymentBudgetMode.fromJson(
        json['paymentBudgetMode'] as String?,
      ),
      monthlyDebtBudget: moneyFromJson(json['monthlyDebtBudget']),
      salaryDebtPercent: moneyFromJson(json['salaryDebtPercent']) == 0
          ? 25
          : moneyFromJson(json['salaryDebtPercent']),
      exchangeRateDopPerUsd: moneyFromJson(json['exchangeRateDopPerUsd']) == 0
          ? 60
          : moneyFromJson(json['exchangeRateDopPerUsd']),
    );
  }
}

class DebtAppData {
  const DebtAppData({
    required this.cards,
    required this.purchases,
    required this.paychecks,
    required this.payments,
    required this.settings,
    this.loans = const [],
  });

  final List<CreditCard> cards;
  final List<Purchase> purchases;
  final List<Paycheck> paychecks;
  final List<CardPayment> payments;
  final AppSettings settings;
  final List<Loan> loans;

  double get totalDebt =>
      cards.fold(
        0.0,
        (total, card) =>
            total +
            amountInDop(
              card.totalOwed,
              card.currency,
              settings.exchangeRateDopPerUsd,
            ),
      ) +
      loans.fold(
        0.0,
        (total, loan) =>
            total +
            amountInDop(
              loan.balance,
              loan.currency,
              settings.exchangeRateDopPerUsd,
            ),
      );

  double get availableCash => cards
      .where((card) => card.isDebit)
      .fold(
        0.0,
        (total, card) =>
            total +
            amountInDop(
              card.balance,
              card.currency,
              settings.exchangeRateDopPerUsd,
            ),
      );

  double get totalMinimumDue =>
      cards
          .where((card) => card.isCredit)
          .fold(
            0.0,
            (total, card) =>
                total +
                amountInDop(
                  math.min(card.minimumDue, card.balance) +
                      math.min(
                        card.installmentMonthlyPayment,
                        card.installmentBalance,
                      ),
                  card.currency,
                  settings.exchangeRateDopPerUsd,
                ),
          ) +
      loans.fold(
        0.0,
        (total, loan) =>
            total +
            amountInDop(
              math.min(loan.minimumPayment, loan.balance),
              loan.currency,
              settings.exchangeRateDopPerUsd,
            ),
      );

  Paycheck? get latestPaycheck {
    if (paychecks.isEmpty) return null;
    final sorted = [...paychecks]
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return sorted.first;
  }

  List<Purchase> recentPurchases({int limit = 6}) {
    final sorted = [...purchases]
      ..sort((a, b) => b.purchasedAt.compareTo(a.purchasedAt));
    return sorted.take(limit).toList();
  }

  CreditCard? cardById(String cardId) {
    for (final card in cards) {
      if (card.id == cardId) return card;
    }
    return null;
  }

  DebtAppData copyWith({
    List<CreditCard>? cards,
    List<Purchase>? purchases,
    List<Paycheck>? paychecks,
    List<CardPayment>? payments,
    AppSettings? settings,
    List<Loan>? loans,
  }) {
    return DebtAppData(
      cards: cards ?? this.cards,
      purchases: purchases ?? this.purchases,
      paychecks: paychecks ?? this.paychecks,
      payments: payments ?? this.payments,
      settings: settings ?? this.settings,
      loans: loans ?? this.loans,
    );
  }

  Map<String, Object?> toJson() => {
    'cards': cards.map((card) => card.toJson()).toList(),
    'purchases': purchases.map((purchase) => purchase.toJson()).toList(),
    'paychecks': paychecks.map((paycheck) => paycheck.toJson()).toList(),
    'payments': payments.map((payment) => payment.toJson()).toList(),
    'settings': settings.toJson(),
    'loans': loans.map((loan) => loan.toJson()).toList(),
  };

  factory DebtAppData.fromJson(Map<String, Object?> json) {
    return DebtAppData(
      cards: (json['cards'] as List<dynamic>? ?? const [])
          .map(
            (card) =>
                CreditCard.fromJson(Map<String, Object?>.from(card as Map)),
          )
          .toList(),
      purchases: (json['purchases'] as List<dynamic>? ?? const [])
          .map(
            (purchase) =>
                Purchase.fromJson(Map<String, Object?>.from(purchase as Map)),
          )
          .toList(),
      paychecks: (json['paychecks'] as List<dynamic>? ?? const [])
          .map(
            (paycheck) =>
                Paycheck.fromJson(Map<String, Object?>.from(paycheck as Map)),
          )
          .toList(),
      payments: (json['payments'] as List<dynamic>? ?? const [])
          .map(
            (payment) =>
                CardPayment.fromJson(Map<String, Object?>.from(payment as Map)),
          )
          .toList(),
      settings: json['settings'] is Map
          ? AppSettings.fromJson(
              Map<String, Object?>.from(json['settings'] as Map),
            )
          : const AppSettings(),
      loans: (json['loans'] as List<dynamic>? ?? const [])
          .map((loan) => Loan.fromJson(Map<String, Object?>.from(loan as Map)))
          .toList(),
    );
  }
}
