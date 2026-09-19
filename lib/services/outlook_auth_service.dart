import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'app_store.dart';
import 'bank_email_parser.dart';
import 'email_sync_service.dart';
import 'oauth_popup.dart';

class OutlookAuthException implements Exception {
  const OutlookAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OutlookAuthService {
  OutlookAuthService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'outlook_access_token';
  static const _expiryKey = 'outlook_access_token_expiry';
  static const _emailKey = 'outlook_account_email';
  static const _clientId = String.fromEnvironment('MICROSOFT_OAUTH_CLIENT_ID');
  static const _authorize =
      'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  static const _token =
      'https://login.microsoftonline.com/common/oauth2/v2.0/token';
  static const _ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  final FlutterSecureStorage _storage;

  Future<String?> connect() async {
    if (!kIsWeb) {
      throw const OutlookAuthException(
        'Outlook sign-in is available in the web app.',
      );
    }
    final clientId = _clientId.isNotEmpty
        ? _clientId
        : webMicrosoftClientIdFromPage();
    final redirect = currentWebOAuthRedirectUri();
    if (clientId == null || clientId.isEmpty || redirect == null) {
      throw const OutlookAuthException(
        'Microsoft sign-in is not configured for this build.',
      );
    }
    final verifier = _random(64);
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final state = 'outlook.${_random(24)}';
    final uri = Uri.parse(_authorize).replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirect.toString(),
        'response_mode': 'query',
        'scope': 'openid profile offline_access User.Read Mail.Read',
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );
    final result = await openOAuthPopup(uri);
    if (result.cancelled) {
      throw const OutlookAuthException('Microsoft sign-in was cancelled.');
    }
    if (result.error != null && result.error!.isNotEmpty) {
      throw OutlookAuthException(result.error!);
    }
    if (result.state != state || result.authorizationCode == null) {
      throw const OutlookAuthException(
        'Microsoft sign-in did not return a valid authorization code.',
      );
    }
    final response = await http.post(
      Uri.parse(_token),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': clientId,
        'grant_type': 'authorization_code',
        'code': result.authorizationCode!,
        'redirect_uri': redirect.toString(),
        'code_verifier': verifier,
      },
    );
    final payload = _body(response);
    if (response.statusCode != 200) {
      throw OutlookAuthException(
        payload['error_description']?.toString() ??
            'Microsoft did not authorize mail access.',
      );
    }
    final token = payload['access_token']?.toString();
    if (token == null || token.isEmpty) {
      throw const OutlookAuthException(
        'Microsoft did not return an access token.',
      );
    }
    await _storage.write(key: _tokenKey, value: token, iOptions: _ios);
    await _storage.write(
      key: _expiryKey,
      value: DateTime.now()
          .add(
            Duration(
              seconds:
                  int.tryParse(payload['expires_in']?.toString() ?? '') ?? 3600,
            ),
          )
          .toIso8601String(),
      iOptions: _ios,
    );
    final profile = await http.get(
      Uri.parse(
        'https://graph.microsoft.com/v1.0/me?\$select=mail,userPrincipalName',
      ),
      headers: {'Authorization': 'Bearer $token'},
    );
    final body = _body(profile);
    final email =
        body['mail']?.toString() ?? body['userPrincipalName']?.toString();
    if (email != null && email.isNotEmpty) {
      await _storage.write(key: _emailKey, value: email, iOptions: _ios);
    }
    return email;
  }

  Future<EmailSyncResult> syncRecentPurchases(
    List<CreditCard> cards, {
    DateTime? since,
    DateTime? until,
    Set<String> excludedMessageIds = const {},
  }) async {
    final token = await _storage.read(key: _tokenKey, iOptions: _ios);
    final rawExpiry = await _storage.read(key: _expiryKey, iOptions: _ios);
    final expiry = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    if (token == null ||
        token.isEmpty ||
        expiry == null ||
        expiry.isBefore(DateTime.now().add(const Duration(minutes: 2)))) {
      throw const OutlookAuthException(
        'Outlook access expired. Connect Outlook again, then import.',
      );
    }
    final query = <String, String>{
      r'$top': '100',
      r'$select': 'id,subject,from,receivedDateTime,body',
      r'$orderby': 'receivedDateTime desc',
    };
    if (since != null) {
      query[r'$filter'] =
          'receivedDateTime ge ${since.toUtc().toIso8601String()}';
    }
    final response = await http.get(
      Uri.https('graph.microsoft.com', '/v1.0/me/messages', query),
      headers: {
        'Authorization': 'Bearer $token',
        'Prefer': 'outlook.body-content-type="text"',
      },
    );
    final payload = _body(response);
    if (response.statusCode != 200) {
      throw OutlookAuthException(
        payload['error']?['message']?.toString() ??
            'Outlook could not read messages.',
      );
    }
    final knownCards = [...cards];
    final discovered = <String, CreditCard>{};
    final purchases = <Purchase>[];
    for (final raw in (payload['value'] as List? ?? const [])) {
      final message = Map<String, dynamic>.from(raw as Map);
      final id = message['id']?.toString();
      if (id == null || excludedMessageIds.contains(id)) continue;
      final received =
          DateTime.tryParse(message['receivedDateTime']?.toString() ?? '') ??
          DateTime.now();
      if (until != null && received.isAfter(until)) continue;
      final sender =
          ((message['from'] as Map?)?['emailAddress'] as Map?)?['address']
              ?.toString() ??
          '';
      final subject = message['subject']?.toString() ?? '';
      final body = ((message['body'] as Map?)?['content']?.toString() ?? '');
      final transactions = parseBankEmailText(
        sender: sender,
        subject: subject,
        text: body,
        fallback: received,
      );
      for (final transaction in transactions) {
        final card =
            _matchingCard(knownCards, transaction) ?? _newCard(transaction);
        if (!knownCards.any((item) => item.id == card.id)) {
          knownCards.add(card);
          discovered[card.id] = card;
        }
        purchases.add(
          Purchase(
            id: newId('outlook'),
            cardId: card.id,
            merchant: transaction.merchant,
            amount: transaction.amount,
            purchasedAt: transaction.date,
            source: PurchaseSource.email,
            subject: subject,
            sourceMessageId: id,
            kind: transaction.kind,
            category: transaction.category,
            currency: transaction.currency,
          ),
        );
      }
    }
    final email = await _storage.read(key: _emailKey, iOptions: _ios);
    return EmailSyncResult(
      accountEmail: email,
      purchases: purchases,
      discoveredCards: discovered.values.toList(),
      message:
          '${discovered.length} account${discovered.length == 1 ? '' : 's'} found, ${purchases.length} transaction${purchases.length == 1 ? '' : 's'} imported from Outlook',
    );
  }

  CreditCard? _matchingCard(
    List<CreditCard> cards,
    BankTransaction transaction,
  ) {
    for (final card in cards) {
      if (card.lastFour == transaction.lastFour &&
          card.currency == transaction.currency &&
          card.accountType == transaction.accountType) {
        return card;
      }
    }
    return null;
  }

  CreditCard _newCard(BankTransaction transaction) => CreditCard(
    id: 'card-outlook-${transaction.accountType.name}-${transaction.currency.toLowerCase()}-${transaction.lastFour}',
    name:
        '${transaction.bank} ${transaction.accountType == AccountType.debit ? 'Debit' : 'Credit'} ${transaction.currency} •${transaction.lastFour}',
    lastFour: transaction.lastFour,
    balance: 0,
    creditLimit: 0,
    apr: 0,
    cutoffDay: 1,
    dueDay: 1,
    minimumDue: 0,
    accentColor: 0xFF087E73,
    emailMatchTerms: [transaction.lastFour],
    accountType: transaction.accountType,
    currency: transaction.currency,
    needsReview: true,
  );

  static String _random(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  static Map<String, dynamic> _body(http.Response response) =>
      response.body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(response.body) as Map<String, dynamic>;
}
