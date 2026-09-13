import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:card_debt_planner/services/bank_email_parser.dart';
import 'package:card_debt_planner/models.dart';

gmail.Message bankMessage({
  required String from,
  required String subject,
  required String body,
  String mimeType = 'text/plain',
}) {
  return gmail.Message(
    id: 'message-${subject.hashCode}',
    internalDate: '1788739200000',
    payload: gmail.MessagePart(
      mimeType: mimeType,
      headers: [
        gmail.MessagePartHeader(name: 'From', value: from),
        gmail.MessagePartHeader(name: 'Subject', value: subject),
      ],
      body: gmail.MessagePartBody(data: base64Url.encode(utf8.encode(body))),
    ),
  );
}

void main() {
  test('parses a BHD HTML transaction table and card suffix', () {
    final result = parseBankTransactions(
      bankMessage(
        from: 'BHD Alertas <alertas@bhd.com.do>',
        subject: 'BHD Notificación de Transacciones',
        mimeType: 'text/html',
        body: '''
        <table><tr><td>Fecha</td><td>Moneda</td><td>Monto</td><td>Comercio</td><td>Estado</td><td>Tipo</td></tr>
        <tr><td>09/09/2026 11:33 am</td><td>RD</td><td>\$369.00</td><td>SUPERMERCADO FORTUNA</td><td>Aprobada</td><td>Compra</td></tr></table>
        Te notificamos la transacción realizada con tu Tarjeta Mastercard Local # 9675
      ''',
      ),
    );
    expect(result, hasLength(1));
    expect(result.single.lastFour, '9675');
    expect(result.single.amount, 369);
    expect(result.single.merchant, 'SUPERMERCADO FORTUNA');
  });

  test('parses APAP plain numeric amount without using available balance', () {
    final result = parseBankTransactions(
      bankMessage(
        from: 'HOLAPAP <no-reply@apap.com.do>',
        subject: 'APAP, Notificaciones',
        body: '''
        Tu tarjeta de Crédito titular-Visa Gold APAP terminada en 2552 presenta una transacción.
        Fecha: 02/09/2026
        Hora: 22:48
        Moneda: RD pesos dominicanos
        Monto: 373.29
        Comercio: PedidosYa*Barra Payan
        Estado: APROBADA
        Balance disponible: RD\$65,397.38
      ''',
      ),
    );
    expect(result, hasLength(1));
    expect(result.single.lastFour, '2552');
    expect(result.single.amount, 373.29);
    expect(result.single.merchant, 'PedidosYa*Barra Payan');
  });

  test(
    'parses Banreservas approved consumption and ignores missing currency',
    () {
      final result = parseBankTransactions(
        bankMessage(
          from: 'notificaciones@banreservas.com',
          subject: 'Notificaciones Banreservas',
          body: '''
        Notificación de Consumo
        Su tarjeta ESTANDAR ••5949 presenta un consumo.
        Monto:
        DOP 325.00
        Estado:
        APROBADO
        Comercio:
        KAREN S EXQUISITECES SANTO DOMINGO DO
        Fecha de transacción:
        06/09/2026 19:33 PM
      ''',
        ),
      );
      expect(result, hasLength(1));
      expect(result.single.lastFour, '5949');
      expect(result.single.amount, 325);
    },
  );

  test('recognizes a debit-card cash withdrawal', () {
    final result = parseBankTransactions(
      bankMessage(
        from: 'BHD Alertas <alertas@bhd.com.do>',
        subject: 'BHD Notificación de Retiro',
        body: '''
        Tu tarjeta de débito terminada en 8141 presenta una transacción.
        Fecha: 09/09/2026
        Moneda: RD pesos dominicanos
        Monto: 2,000.00
        Comercio: CAJERO AUTOMATICO BHD
        Estado: APROBADA
        Tipo: Retiro en cajero
      ''',
      ),
    );
    expect(result, hasLength(1));
    expect(result.single.accountType, AccountType.debit);
    expect(result.single.kind, TransactionKind.withdrawal);
    expect(result.single.category, SpendingCategory.cash);
    expect(result.single.amount, 2000);
  });

  test('recognizes a card payment without a purchase status field', () {
    final result = parseBankTransactions(
      bankMessage(
        from: 'notificaciones@banreservas.com',
        subject: 'Notificaciones Banreservas - Pago de tarjeta',
        body: '''
        Pago de tarjeta confirmado
        Tarjeta terminada en 5949
        Monto: DOP 3,500.00
        Fecha: 10/09/2026
      ''',
      ),
    );
    expect(result, hasLength(1));
    expect(result.single.kind, TransactionKind.cardPayment);
    expect(result.single.amount, 3500);
  });

  test('supports another bank when its notification has structured fields', () {
    final result = parseBankTransactions(
      bankMessage(
        from: 'alerts@examplebank.com',
        subject: 'Card transaction approved',
        body: '''
        Your debit card ending in 7788 was used.
        Date: 10/09/2026
        Currency: DOP
        Amount: 850.00
        Merchant: TEST MARKET
        Status: Approved
        Transaction type: Purchase
      ''',
      ),
    );
    expect(result, hasLength(1));
    expect(result.single.bank, 'Examplebank');
    expect(result.single.accountType, AccountType.debit);
    expect(result.single.amount, 850);
  });

  test(
    'recognizes Banco Popular incoming transfers as debit-account money in',
    () {
      final result = parseBankTransactions(
        bankMessage(
          from: 'Banco Popular <alertas@bpd.com.do>',
          subject: 'Transferencia recibida',
          body: '''
        Crédito a su cuenta de ahorro terminada en 4412
        Monto: RD\$ 12,500.00
        Fecha: 11/09/2026
        Concepto: Transferencia recibida de Juan
      ''',
        ),
      );
      expect(result, hasLength(1));
      expect(result.single.bank, 'Banco Popular');
      expect(result.single.accountType, AccountType.debit);
      expect(result.single.kind, TransactionKind.transferIn);
    },
  );
}
