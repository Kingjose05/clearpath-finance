import 'dart:convert';

import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../models.dart';

class BankTransaction {
  const BankTransaction({
    required this.lastFour,
    required this.bank,
    required this.amount,
    required this.currency,
    required this.merchant,
    required this.date,
    this.accountType = AccountType.credit,
    this.needsReview = false,
    this.kind = TransactionKind.purchase,
    this.category = SpendingCategory.other,
    this.transferReference,
    this.counterpartyLastFour,
  });
  final String lastFour;
  final String bank;
  final double amount;
  final String currency;
  final String merchant;
  final DateTime date;
  final AccountType accountType;
  final bool needsReview;
  final TransactionKind kind;
  final SpendingCategory category;
  final String? transferReference;
  final String? counterpartyLastFour;
}

const _dominicanBankBrands = <String, String>{
  'banreservas': 'Banreservas',
  'bancopopular': 'Banco Popular',
  'popularenlinea': 'Banco Popular',
  'bpd.com.do': 'Banco Popular',
  'bhd': 'BHD',
  'scotiabank': 'Scotiabank',
  'apap': 'APAP',
  'asociacion popular': 'APAP',
  'acap': 'Asociación Cibao',
  'asociacion cibao': 'Asociación Cibao',
  'promerica': 'Banco Promerica',
  'bancocaribe': 'Banco Caribe',
  'banesco': 'Banesco',
  'asociacion la nacional': 'Asociación La Nacional',
  'bancoademi': 'Banco Ademi',
  'adopem': 'Banco Adopem',
  'bancosantacruz': 'Banco Santa Cruz',
  'banco santa cruz': 'Banco Santa Cruz',
  'qik': 'Qik Banco Digital',
  'lafise': 'Banco Lafise',
  'bancobdi': 'Banco BDI',
  'banco bdi': 'Banco BDI',
  'citibank': 'Citibank',
  'banco agricola': 'Banco Agrícola',
  'bagricola': 'Banco Agrícola',
  'bandex': 'Bandex',
  'banfondesa': 'Banfondesa',
  'motorcredito': 'Motor Crédito',
  'alaver': 'Alaver',
  'abonap': 'ABONAP',
  'jmmb': 'JMMB Bank',
  'bancofihogar': 'Banco Fihogar',
  'bancoconfisa': 'Banco Confisa',
  'bancoatlantico': 'Banco Atlántico',
  'bancovimenca': 'Banco Vimenca',
  'bancounion': 'Banco Unión',
  'asomoca': 'Asociación Mocana',
  'asociacion mocana': 'Asociación Mocana',
  'asociacion duarte': 'Asociación Duarte',
  'asociacion romana': 'Asociación Romana',
  'asociacion peravia': 'Asociación Peravia',
  'asociacion maguana': 'Asociación Maguana',
};

String _bankName(String sender, String content) {
  final haystack = _normalize('$sender $content');
  for (final entry in _dominicanBankBrands.entries) {
    if (haystack.contains(entry.key)) return entry.value;
  }
  if (!sender.contains('@')) return '';
  final domain = sender.split('@').last.split('.').first;
  if (domain.length < 2) return '';
  return '${domain[0].toUpperCase()}${domain.substring(1)}';
}

SpendingCategory categorizeMerchant(String value) {
  final text = _normalize(value);
  if (RegExp(
    r'uber|didi|indriver|cabify|taxi|metro|combustible|gasolina|shell|texaco|sunix|total',
  ).hasMatch(text)) {
    return SpendingCategory.transportation;
  }
  if (RegExp(
    r'supermercado|super market|nacional|jumbo|bravo|ole|sirena|pricesmart|mercado',
  ).hasMatch(text)) {
    return SpendingCategory.groceries;
  }
  if (RegExp(
    r'restaurant|restaurante|cafe|coffee|pedidosya|ubereats|payan|pizza|burger|kfc|mcdonald|wendy',
  ).hasMatch(text)) {
    return SpendingCategory.food;
  }
  if (RegExp(
    r'farmacia|medical|clinica|laboratorio|hospital|salud',
  ).hasMatch(text)) {
    return SpendingCategory.health;
  }
  if (RegExp(
    r'netflix|spotify|cinema|cine|youtube|hbo|disney|gaming',
  ).hasMatch(text)) {
    return SpendingCategory.entertainment;
  }
  if (RegExp(
    r'claro|altice|edenorte|edesur|internet|telefono|electricidad|agua',
  ).hasMatch(text)) {
    return SpendingCategory.bills;
  }
  if (RegExp(
    r'airbnb|hotel|airline|aerolinea|jetblue|arajet|booking',
  ).hasMatch(text)) {
    return SpendingCategory.travel;
  }
  if (RegExp(r'cajero|atm|retiro|avance de efectivo').hasMatch(text)) {
    return SpendingCategory.cash;
  }
  return SpendingCategory.shopping;
}

String messageHeader(gmail.Message message, String name) {
  for (final header
      in message.payload?.headers ?? <gmail.MessagePartHeader>[]) {
    if (header.name?.toLowerCase() == name.toLowerCase()) {
      return header.value ?? '';
    }
  }
  return '';
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll('á', 'a')
    .replaceAll('é', 'e')
    .replaceAll('í', 'i')
    .replaceAll('ó', 'o')
    .replaceAll('ú', 'u')
    .replaceAll('ñ', 'n')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _clean(String text) =>
    text.replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();

List<String> _parts(gmail.MessagePart? part, String type) {
  if (part == null) return [];
  final result = <String>[];
  if (part.mimeType == type ||
      (part.mimeType == null && type == 'text/plain')) {
    final data = part.body?.data;
    if (data != null) {
      try {
        final bytes = base64Url.decode(base64Url.normalize(data));
        try {
          result.add(utf8.decode(bytes));
        } on FormatException {
          result.add(latin1.decode(bytes));
        }
      } on FormatException {
        // Ignore invalid attachments; do not interpret binary files as purchases.
      }
    }
  }
  for (final child in part.parts ?? <gmail.MessagePart>[]) {
    result.addAll(_parts(child, type));
  }
  return result;
}

String _visibleText(dom.Node node) {
  if (node is dom.Text) return node.data;
  if (node is dom.Element &&
      ['script', 'style', 'head'].contains(node.localName)) {
    return '';
  }
  final text = node.nodes.map(_visibleText).join();
  if (node is dom.Element &&
      [
        'br',
        'p',
        'div',
        'tr',
        'td',
        'th',
        'li',
        'table',
      ].contains(node.localName)) {
    return '$text\n';
  }
  return text;
}

String? _cardNumber(String text) {
  // Only the suffix of a card identifier; never a year, phone or account number.
  for (final pattern in [
    r'(?:terminad[ao](?:\s+en)?|ending(?:\s+in)?)\s*[:#]?\s*(\d{4})(?!\d)',
    r'(?:tarjeta|visa|mastercard)[^\n#]{0,70}#\s*(\d{4})(?!\d)',
    r'(?:tarjeta|card|cuenta)[^\n]{0,70}?[*xX•●]{2,}\s*(\d{4})(?!\d)',
    r'(?:cuenta)[^\n]{0,70}?(\d{4})(?!\d)',
  ]) {
    final match = RegExp(pattern, caseSensitive: false).firstMatch(text);
    if (match != null) return match.group(1);
  }
  return null;
}

String? _counterpartyLastFour(String text, String ownLastFour) {
  final labeled = RegExp(
    r'(?:destino|origen|beneficiario|beneficiary|cuenta destino|cuenta origen|account destination|account origin)[^\n]{0,80}?(?:terminad[ao](?:\s+en)?|ending(?:\s+in)?|[*xX•●]{2,})?\s*[:#-]?\s*(\d{4})(?!\d)',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in labeled) {
    final value = match.group(1);
    if (value != null && value != ownLastFour) return value;
  }
  return null;
}

String? _transferReference(Map<String, String> fields, String text) {
  final field = _firstField(fields, text, const [
    'referencia',
    'reference',
    'transaction id',
    'transaction number',
    'numero de transaccion',
    'no. de transaccion',
    'tracking',
    'confirmation',
  ]).trim();
  final match = field.isNotEmpty
      ? RegExp(r'[A-Za-z0-9][A-Za-z0-9_-]{3,}').firstMatch(field)
      : RegExp(
          r'(?:referencia|reference|transaction\s*(?:id|number)|tracking|confirmation)\s*[:#-]?\s*([A-Za-z0-9][A-Za-z0-9_-]{3,})',
          caseSensitive: false,
        ).firstMatch(text);
  return match?.group(1)?.toUpperCase();
}

double? parseBankAmount(String text) {
  final match = RegExp(r'\d[\d.,]*').firstMatch(text);
  if (match == null) return null;
  var number = match.group(0)!;
  if (number.contains(',') && number.contains('.')) {
    number = number.lastIndexOf(',') > number.lastIndexOf('.')
        ? number.replaceAll('.', '').replaceAll(',', '.')
        : number.replaceAll(',', '');
  } else if (number.contains(',')) {
    number = RegExp(r',\d{2}$').hasMatch(number)
        ? number.replaceAll(',', '.')
        : number.replaceAll(',', '');
  }
  return double.tryParse(number);
}

String _field(Map<String, String> fields, String text, String name) {
  if (fields[name]?.isNotEmpty == true) return fields[name]!;
  final match = RegExp(
    '(?:^|\\n)\\s*$name\\s*:\\s*([^\\n]+)',
    caseSensitive: false,
  ).firstMatch(text);
  return match?.group(1)?.trim() ?? '';
}

String _firstField(
  Map<String, String> fields,
  String text,
  List<String> names,
) {
  for (final name in names) {
    final value = _field(fields, text, name);
    if (value.isNotEmpty) return value;
  }
  return '';
}

DateTime _date(String value, String time, DateTime fallback) {
  final day = RegExp(r'(\d{2})/(\d{2})/(\d{4})').firstMatch(value);
  if (day == null) return fallback;
  final clock = RegExp(
    r'(\d{1,2}):(\d{2})\s*(am|pm)?',
    caseSensitive: false,
  ).firstMatch('$value $time');
  var hour = int.tryParse(clock?.group(1) ?? '') ?? 0;
  if (clock?.group(3)?.toLowerCase() == 'pm' && hour < 12) hour += 12;
  if (clock?.group(3)?.toLowerCase() == 'am' && hour == 12) hour = 0;
  return DateTime(
    int.parse(day.group(3)!),
    int.parse(day.group(2)!),
    int.parse(day.group(1)!),
    hour,
    int.tryParse(clock?.group(2) ?? '') ?? 0,
  );
}

/// Parses actual bank fields. Email snippets and available balances are not amounts.
List<BankTransaction> parseBankTransactions(gmail.Message message) {
  final from = messageHeader(message, 'from').toLowerCase();
  final sender = RegExp(r'<([^>]+)>').firstMatch(from)?.group(1) ?? from.trim();
  final subject = _normalize(messageHeader(message, 'subject'));

  final htmlParts = _parts(message.payload, 'text/html');
  final doc = html.parse(htmlParts.join('\n'));
  final rawText = htmlParts.isNotEmpty
      ? _visibleText(doc.body!)
      : _parts(message.payload, 'text/plain').join('\n');
  final text = rawText
      .split('\n')
      .map(_clean)
      .where((line) => line.isNotEmpty)
      .join('\n');
  final normalizedText = _normalize(text);
  if (!RegExp(
    r'notificacion|notification|transaccion|transaction|consumo|purchase|retiro|withdrawal|pago|payment|deposito|deposit|transferencia|transfer|abono|credito|debito',
  ).hasMatch('$subject $normalizedText')) {
    return [];
  }
  final bank = _bankName(sender, '$subject $normalizedText');
  if (bank.isEmpty) return [];
  final lastFour = _cardNumber(text.replaceAll('\n', ' '));
  if (lastFour == null) return [];

  final records = <Map<String, String>>[];
  final fields = <String, String>{};
  const keys = {
    'fecha',
    'fecha de transaccion',
    'hora',
    'moneda',
    'monto',
    'comercio',
    'estado',
    'tipo',
    'cajero',
    'descripcion',
    'concepto',
    'valor',
    'importe',
    'debito',
    'credito',
    'detalle',
    'beneficiario',
    'origen',
    'destino',
    'date',
    'time',
    'currency',
    'amount',
    'merchant',
    'status',
    'transaction type',
    'referencia',
    'reference',
    'transaction id',
    'transaction number',
    'numero de transaccion',
    'no. de transaccion',
    'tracking',
    'confirmation',
  };
  for (final table in doc.querySelectorAll('table')) {
    List<String>? headers;
    for (final row in table.querySelectorAll('tr')) {
      var parent = row.parent;
      while (parent != null && parent.localName != 'table') {
        parent = parent.parent;
      }
      if (parent != table) continue;
      final cells = row.children
          .where((c) => c.localName == 'td' || c.localName == 'th')
          .map((c) => _clean(_visibleText(c)))
          .toList();
      final labels = cells
          .map((c) => _normalize(c).replaceAll(':', ''))
          .toList();
      if (labels.contains('monto') &&
          labels.contains('comercio') &&
          labels.contains('estado')) {
        headers = labels;
      } else if (headers != null && cells.length == headers.length) {
        records.add(Map.fromIterables(headers, cells));
      } else if (cells.length >= 2 && keys.contains(labels.first)) {
        fields[labels.first] = cells.skip(1).join(' ');
      }
    }
  }
  if (records.isEmpty) records.add(fields);
  final fallback = DateTime.fromMillisecondsSinceEpoch(
    int.tryParse(message.internalDate ?? '') ?? 0,
  );
  final result = <BankTransaction>[];
  for (final record in records) {
    final type = _normalize(
      _firstField(record, text, const ['tipo', 'transaction type']),
    );
    final context = '$subject $type $normalizedText';
    final kind =
        RegExp(r'retiro|cajero|\batm\b|avance de efectivo').hasMatch(context)
        ? TransactionKind.withdrawal
        : RegExp(
            r'pago (?:a |de )?(?:la )?tarjeta|abono (?:a |de )?(?:la )?tarjeta',
          ).hasMatch(context)
        ? TransactionKind.cardPayment
        : RegExp(
            r'nomina|salario|deposito de sueldo|pago de sueldo|credito de nomina',
          ).hasMatch(context)
        ? TransactionKind.income
        : RegExp(
            r'transferencia recibida|transferencia entrante|abono recibido|credito (?:a|en) (?:su )?cuenta|incoming transfer|ach credit',
          ).hasMatch(context)
        ? TransactionKind.transferIn
        : RegExp(
            r'transferencia enviada|transferencia saliente|debito (?:a|en) (?:su )?cuenta|outgoing transfer|ach debit',
          ).hasMatch(context)
        ? TransactionKind.transferOut
        : RegExp(r'reembolso|devolucion|refund').hasMatch(context)
        ? TransactionKind.refund
        : TransactionKind.purchase;
    final explicitDebit = RegExp(
      r'tarjeta (?:de )?debito|debit card|cuenta de ahorro|cuenta corriente|checking account|savings account',
    ).hasMatch(context);
    final explicitCredit = RegExp(
      r'tarjeta (?:de )?credito|credit card|balance al corte|pago minimo',
    ).hasMatch(context);
    final accountType =
        explicitDebit ||
            kind == TransactionKind.income ||
            kind == TransactionKind.transferIn ||
            kind == TransactionKind.transferOut
        ? AccountType.debit
        : AccountType.credit;
    var needsReview = !explicitDebit && !explicitCredit;
    final state = _normalize(
      _firstField(record, text, const ['estado', 'status']),
    );
    if (RegExp(
      r'rechazad|declined|cancelad|reversad|fallid|failed|pendiente|pending',
    ).hasMatch(state)) {
      continue;
    }
    final amountText = _firstField(record, text, const [
      'monto',
      'valor',
      'importe',
      'debito',
      'credito',
      'amount',
    ]);
    final amount = parseBankAmount(amountText);
    if (amount == null || amount <= 0) continue;
    final transferReference =
        kind == TransactionKind.transferIn ||
            kind == TransactionKind.transferOut
        ? _transferReference(record, text)
        : null;
    var merchant = _firstField(record, text, const ['comercio', 'merchant']);
    if (merchant.isEmpty) merchant = _field(record, text, 'cajero');
    if (merchant.isEmpty) merchant = _field(record, text, 'descripcion');
    if (merchant.isEmpty) merchant = _field(record, text, 'concepto');
    if (merchant.isEmpty) merchant = _field(record, text, 'detalle');
    if (merchant.isEmpty) merchant = _field(record, text, 'beneficiario');
    if (merchant.isEmpty && kind == TransactionKind.withdrawal) {
      merchant = 'Cash withdrawal';
    }
    if (merchant.isEmpty && kind == TransactionKind.cardPayment) {
      merchant = 'Card payment';
    }
    if (merchant.isEmpty && kind == TransactionKind.income) {
      merchant = 'Salary deposit';
    }
    if (merchant.isEmpty && kind == TransactionKind.transferIn) {
      merchant = 'Incoming transfer';
    }
    if (merchant.isEmpty && kind == TransactionKind.transferOut) {
      merchant = 'Outgoing transfer';
    }
    if (merchant.isEmpty) continue;
    final money = _normalize(
      '${_firstField(record, text, const ['moneda', 'currency'])} $amountText',
    );
    final currency = RegExp(r'\b(?:usd|us|dolar)').hasMatch(money)
        ? 'USD'
        : RegExp(r'\b(?:rd|dop|pesos)').hasMatch(money)
        ? 'DOP'
        : 'DOP';
    if (!RegExp(r'\b(?:usd|us|dolar|rd|dop|pesos)').hasMatch(money)) {
      needsReview = true;
    }
    result.add(
      BankTransaction(
        lastFour: lastFour,
        bank: bank,
        amount: amount,
        currency: currency,
        merchant: merchant,
        date: _date(
          _firstField(record, text, const [
            'fecha de transaccion',
            'fecha',
            'date',
          ]),
          _firstField(record, text, const ['hora', 'time']),
          fallback,
        ),
        accountType: accountType,
        needsReview: needsReview,
        kind: kind,
        transferReference: transferReference,
        counterpartyLastFour:
            kind == TransactionKind.transferIn ||
                kind == TransactionKind.transferOut
            ? _counterpartyLastFour(text, lastFour)
            : null,
        category: kind == TransactionKind.withdrawal
            ? SpendingCategory.cash
            : kind == TransactionKind.income
            ? SpendingCategory.income
            : kind == TransactionKind.transferIn ||
                  kind == TransactionKind.transferOut
            ? SpendingCategory.transfers
            : kind == TransactionKind.cardPayment
            ? SpendingCategory.payments
            : categorizeMerchant(merchant),
      ),
    );
  }
  return result;
}
