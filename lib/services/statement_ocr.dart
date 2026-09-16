// ignore_for_file: deprecated_member_use

import 'dart:typed_data';

import 'statement_ocr_platform.dart'
    if (dart.library.io) 'statement_ocr_native.dart';

import '../models.dart';

class StatementDraft {
  const StatementDraft({
    required this.fileName,
    required this.rawText,
    this.imageBytes,
    this.bankName = '',
    this.lastFour = '',
    this.accountType = AccountType.credit,
    this.availableBalanceDop,
    this.availableBalanceUsd,
    this.currentTotalDop,
    this.statementBalanceDop,
    this.minimumDueDop,
    this.statementBalanceUsd,
    this.minimumDueUsd,
    this.installmentBalance,
    this.installmentMonthlyPayment,
    this.cutoffDate,
    this.dueDate,
  });

  final String fileName;
  final String rawText;
  final Uint8List? imageBytes;
  final String bankName;
  final String lastFour;
  final AccountType accountType;
  final double? availableBalanceDop;
  final double? availableBalanceUsd;
  final double? currentTotalDop;
  final double? statementBalanceDop;
  final double? minimumDueDop;
  final double? statementBalanceUsd;
  final double? minimumDueUsd;
  final double? installmentBalance;
  final double? installmentMonthlyPayment;
  final DateTime? cutoffDate;
  final DateTime? dueDate;

  bool get hasDop =>
      currentTotalDop != null ||
      statementBalanceDop != null ||
      minimumDueDop != null ||
      availableBalanceDop != null;

  bool get hasUsd =>
      statementBalanceUsd != null ||
      minimumDueUsd != null ||
      availableBalanceUsd != null;
}

class StatementOcrService {
  const StatementOcrService();

  Future<String> extractText(String? path) => extractStatementText(path);
}

StatementDraft parseStatementText({
  required String fileName,
  required String text,
  Uint8List? imageBytes,
}) {
  final normalized = text.replaceAll('\u00a0', ' ').replaceAll('\r', '\n');
  final upper = normalized.toUpperCase();
  final bankName = upper.contains('APAP')
      ? 'APAP'
      : upper.contains('BHD')
      ? 'BHD'
      : _firstNonEmpty(
              _matchText(normalized, [
                RegExp(
                  r'\b([A-Z][A-Z0-9& ]{2,24})\b(?:\s+(?:VISA|MASTERCARD))?',
                ),
              ]),
            ) ??
            '';
  final lastFour = _lastFour(normalized);
  final currentTotalDop = _amountAfter(normalized, [
    'current total',
    'total actual',
    'saldo actual',
    'balance actual',
    'total a pagar',
  ]);
  final availableBalanceDop = _amountAfter(normalized, [
    'available balance',
    'available funds',
    'saldo disponible',
    'balance disponible',
    'balance actual',
    'saldo actual',
  ]);
  final statementBalanceDop = _amountAfter(normalized, [
    'statement balance',
    'saldo al corte',
    'balance al corte',
    'saldo del estado',
    'cutoff balance',
  ]);
  final minimumDueDop = _amountAfter(normalized, [
    'minimum payment',
    'minimum due',
    'pago minimo',
    'pago mínimo',
    'minimo a pagar',
    'mínimo a pagar',
    'pago requerido',
  ]);
  final usdNumbers = _currencyAmounts(normalized, 'USD');
  final installmentMonthlyPayment = _amountAfter(normalized, [
    'installment amount due',
    'installment payment',
    'monthly installment',
    'cuota mensual',
    'cuota a pagar',
    'mas limite',
    'más limite',
  ]);
  final installmentBalance = _amountAfter(normalized, [
    'installment balance',
    'saldo de cuotas',
    'cuotas pendientes',
  ]);
  final isDebit = RegExp(
    r'debit|debit card|tarjeta de debito|cuenta de ahorro|cuenta corriente|checking|savings|available balance|saldo disponible|available funds',
    caseSensitive: false,
  ).hasMatch(normalized);

  return StatementDraft(
    fileName: fileName,
    rawText: normalized,
    imageBytes: imageBytes,
    bankName: bankName,
    lastFour: lastFour,
    accountType: isDebit ? AccountType.debit : AccountType.credit,
    availableBalanceDop: availableBalanceDop,
    availableBalanceUsd: isDebit && usdNumbers.isNotEmpty
        ? usdNumbers.first
        : null,
    currentTotalDop: currentTotalDop,
    statementBalanceDop: statementBalanceDop,
    minimumDueDop: minimumDueDop,
    statementBalanceUsd: usdNumbers.isEmpty ? null : usdNumbers.first,
    minimumDueUsd: usdNumbers.length < 2 ? null : usdNumbers[1],
    installmentBalance: installmentBalance,
    installmentMonthlyPayment: installmentMonthlyPayment,
    cutoffDate: _dateAfter(normalized, [
      'statement closing',
      'closing date',
      'fecha de corte',
      'cutoff',
    ]),
    dueDate: _dateAfter(normalized, [
      'payment due',
      'due date',
      'fecha de pago',
      'vencimiento',
    ]),
  );
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

Iterable<String?> _matchText(String text, List<RegExp> expressions) sync* {
  for (final expression in expressions) {
    final match = expression.firstMatch(text);
    if (match != null && match.groupCount > 0) yield match.group(1);
  }
}

String _lastFour(String text) {
  final labeled = RegExp(
    r'(?:ending|last\s*4|last\s*four|terminad[oa]s?\s*en|ultimos?\s*4|últimos?\s*4)\D{0,10}(\d{4})',
    caseSensitive: false,
  ).firstMatch(text);
  if (labeled != null) return labeled.group(1)!;
  return '';
}

double? _amountAfter(String text, List<String> labels) {
  for (final label in labels) {
    final escaped = RegExp.escape(label);
    final match = RegExp(
      '$escaped[^\\d]{0,36}([\\d.,]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      final amount = _parseAmount(match.group(1)!);
      if (amount != null) return amount;
    }
  }
  return null;
}

List<double> _currencyAmounts(String text, String currency) {
  final prefixed = RegExp(
    '(?:${RegExp.escape(currency)}|US\\\$|d[oó]lares?)[^\\d]{0,24}([\\d.,]+)',
    caseSensitive: false,
  ).allMatches(text);
  final suffixed = RegExp(
    '([\\d.,]+)[^\\d]{0,4}(?:${RegExp.escape(currency)}|US\\\$)',
    caseSensitive: false,
  ).allMatches(text);
  final values = [
    ...prefixed,
    ...suffixed,
  ].map((match) => _parseAmount(match.group(1)!)).whereType<double>().toList();
  return values.fold<List<double>>([], (unique, value) {
    if (!unique.any((existing) => (existing - value).abs() < 0.005)) {
      unique.add(value);
    }
    return unique;
  });
}

DateTime? _dateAfter(String text, List<String> labels) {
  for (final label in labels) {
    final numericMatch = RegExp(
      '${RegExp.escape(label)}[^\\d]{0,24}(\\d{1,2}[/-]\\d{1,2}[/-]\\d{2,4})',
      caseSensitive: false,
    ).firstMatch(text);
    if (numericMatch != null) {
      final parts = numericMatch
          .group(1)!
          .split(RegExp(r'[/-]'))
          .map(int.parse)
          .toList();
      final year = parts[2] < 100 ? 2000 + parts[2] : parts[2];
      final parsed = DateTime.tryParse(
        '${year.toString().padLeft(4, '0')}-${parts[1].toString().padLeft(2, '0')}-${parts[0].toString().padLeft(2, '0')}',
      );
      if (parsed != null) return parsed;
    }
    final namedMatch = RegExp(
      '${RegExp.escape(label)}[^0-9]{0,24}?([A-Za-z]{3,9})\\s+(\\d{1,2}),?\\s+(\\d{4})',
      caseSensitive: false,
    ).firstMatch(text);
    if (namedMatch == null) continue;
    final month = _monthNumber(namedMatch.group(1)!);
    final parsed = month == null
        ? null
        : DateTime.tryParse(
            '${namedMatch.group(3)}-${month.toString().padLeft(2, '0')}-${namedMatch.group(2)!.padLeft(2, '0')}',
          );
    if (parsed != null) return parsed;
  }
  return null;
}

int? _monthNumber(String value) {
  const months = {
    'JAN': 1,
    'JANUARY': 1,
    'FEB': 2,
    'FEBRUARY': 2,
    'MAR': 3,
    'MARCH': 3,
    'APR': 4,
    'APRIL': 4,
    'MAY': 5,
    'JUN': 6,
    'JUNE': 6,
    'JUL': 7,
    'JULY': 7,
    'AUG': 8,
    'AUGUST': 8,
    'SEP': 9,
    'SEPT': 9,
    'SEPTEMBER': 9,
    'OCT': 10,
    'OCTOBER': 10,
    'NOV': 11,
    'NOVEMBER': 11,
    'DEC': 12,
    'DECEMBER': 12,
  };
  return months[value.toUpperCase()];
}

double? _parseAmount(String raw) {
  var value = raw.replaceAll(RegExp(r'[^0-9,.-]'), '');
  if (value.isEmpty) return null;
  final comma = value.lastIndexOf(',');
  final dot = value.lastIndexOf('.');
  if (comma >= 0 && dot >= 0) {
    if (comma > dot) {
      value = value.replaceAll('.', '').replaceFirst(',', '.');
    } else {
      value = value.replaceAll(',', '');
    }
  } else if (comma >= 0 && value.length - comma - 1 == 2) {
    value = value.replaceFirst(',', '.');
  } else {
    value = value.replaceAll(',', '');
  }
  return double.tryParse(value);
}
