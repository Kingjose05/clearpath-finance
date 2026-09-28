import 'dart:async';
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
import 'outlook_graph_pager.dart';

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
  static const _refreshTokenKey = 'outlook_refresh_token';
  static const _expiryKey = 'outlook_access_token_expiry';
  static const _emailKey = 'outlook_account_email';
  static const _clientId = String.fromEnvironment('MICROSOFT_OAUTH_CLIENT_ID');
  static const _authorize =
      'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  static const _token =
      'https://login.microsoftonline.com/common/oauth2/v2.0/token';
  static const _networkTimeout = Duration(seconds: 25);
  static const _ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  final FlutterSecureStorage _storage;
  final status = ValueNotifier<String>('');

  Future<bool> hasAccess() async {
    final token = await _storage.read(key: _tokenKey, iOptions: _ios);
    final rawExpiry = await _storage.read(key: _expiryKey, iOptions: _ios);
    final expiry = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    final refreshToken = await _storage.read(
      key: _refreshTokenKey,
      iOptions: _ios,
    );
    return (token != null &&
            token.isNotEmpty &&
            expiry != null &&
            expiry.isAfter(DateTime.now().add(const Duration(minutes: 2)))) ||
        (refreshToken != null && refreshToken.isNotEmpty);
  }

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
    final refreshToken = payload['refresh_token']?.toString();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _storage.write(
        key: _refreshTokenKey,
        value: refreshToken,
        iOptions: _ios,
      );
    }
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
    Future<void> Function(EmailSyncResult)? onBatch,
  }) async {
    status.value = 'Checking Outlook connection...';
    final token = await _usableAccessToken();
    if (token == null || token.isEmpty) {
      throw const OutlookAuthException(
        'Outlook access expired. Connect Outlook again, then import.',
      );
    }
    final query = <String, String>{
      r'$top': '50',
      r'$select': 'id,subject,from,receivedDateTime,body',
      r'$orderby': 'receivedDateTime desc',
    };
    if (since != null) {
      query[r'$filter'] =
          'receivedDateTime ge ${since.toUtc().toIso8601String()}';
    }
    if (until != null) {
      final upper = 'receivedDateTime lt ${until.toUtc().toIso8601String()}';
      query[r'$filter'] = query.containsKey(r'$filter')
          ? '${query[r'$filter']} and $upper'
          : upper;
    }
    final knownCards = [...cards];
    final discovered = <String, CreditCard>{};
    final purchases = <Purchase>[];
    final email = await _storage.read(key: _emailKey, iOptions: _ios);
    var checked = 0;
    var accessToken = token;
    final total = await forEachOutlookMessagePage(
      firstPage: Uri.https('graph.microsoft.com', '/v1.0/me/messages', query),
      fetch: (uri) async {
        for (var attempt = 0; ; attempt++) {
          status.value = 'Reading Outlook emails ($checked checked)...';
          var response = await _messagesRequest(accessToken, uri);
          if (response.statusCode == 401) {
            final refreshed = await _usableAccessToken(forceRefresh: true);
            if (refreshed == null || refreshed.isEmpty) {
              throw const OutlookAuthException(
                'Outlook access expired. Connect Outlook again, then sync.',
              );
            }
            accessToken = refreshed;
            response = await _messagesRequest(accessToken, uri);
          }
          if ((response.statusCode == 429 || response.statusCode == 503) &&
              attempt < 3) {
            final suggested = int.tryParse(
              response.headers['retry-after'] ?? '',
            );
            final seconds = (suggested ?? (2 << attempt)).clamp(1, 30);
            status.value = 'Outlook is busy. Retrying in $seconds seconds...';
            await Future<void>.delayed(Duration(seconds: seconds));
            continue;
          }
          return response;
        }
      },
      onPage: (messages, page) async {
        final pagePurchases = <Purchase>[];
        final pageCards = <CreditCard>[];
        for (final message in messages) {
          final before = discovered.length;
          final parsed = _parseOutlookMessage(
            message,
            knownCards,
            discovered,
            excludedMessageIds,
            until,
          );
          pagePurchases.addAll(parsed);
          purchases.addAll(parsed);
          if (discovered.length > before) {
            pageCards.addAll(discovered.values.skip(before));
          }
        }
        checked += messages.length;
        status.value =
            '$checked Outlook emails checked; ${purchases.length} bank transactions found';
        if (onBatch != null &&
            (pagePurchases.isNotEmpty || pageCards.isNotEmpty)) {
          await onBatch(
            EmailSyncResult(
              accountEmail: email,
              purchases: pagePurchases,
              discoveredCards: pageCards,
              message: status.value,
            ),
          );
        }
      },
    );
    return EmailSyncResult(
      accountEmail: email,
      purchases: purchases,
      discoveredCards: discovered.values.toList(),
      message:
          '$total Outlook emails checked; ${purchases.length} bank transactions found',
    );
  }

  List<Purchase> _parseOutlookMessage(
    Map<String, dynamic> message,
    List<CreditCard> knownCards,
    Map<String, CreditCard> discovered,
    Set<String> excludedMessageIds,
    DateTime? until,
  ) {
    final id = message['id']?.toString();
    if (id == null || excludedMessageIds.contains(id)) return [];
    final received =
        DateTime.tryParse(message['receivedDateTime']?.toString() ?? '') ??
        DateTime.now();
    if (until != null && !received.isBefore(until)) return [];
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
    final purchases = <Purchase>[];
    for (final transaction in transactions) {
      final card =
          _matchingCard(knownCards, transaction) ?? _newCard(transaction);
      if (!knownCards.any((item) => item.id == card.id)) {
        knownCards.add(card);
        discovered[card.id] = card;
      }
      final related = transaction.counterpartyLastFour == null
          ? null
          : _matchingCard(
              knownCards,
              BankTransaction(
                lastFour: transaction.counterpartyLastFour!,
                bank: transaction.bank,
                amount: transaction.amount,
                currency: transaction.currency,
                merchant: transaction.merchant,
                date: transaction.date,
                accountType: AccountType.debit,
              ),
            );
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
          transferReference: transaction.transferReference,
          relatedCardId: related?.id,
        ),
      );
    }
    return purchases;
  }

  CreditCard? _matchingCard(
    List<CreditCard> cards,
    BankTransaction transaction,
  ) {
    for (final card in cards) {
      if (card.matchesIdentifier(transaction.lastFour) &&
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

  Future<http.Response> _messagesRequest(String token, Uri uri) => http
      .get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Prefer': 'outlook.body-content-type="text"',
        },
      )
      .timeout(
        _networkTimeout,
        onTimeout: () => throw const OutlookAuthException(
          'Outlook did not respond within 25 seconds. Check your connection and try Sync again.',
        ),
      );

  Future<String?> _usableAccessToken({bool forceRefresh = false}) async {
    final token = await _storage.read(key: _tokenKey, iOptions: _ios);
    final rawExpiry = await _storage.read(key: _expiryKey, iOptions: _ios);
    final expiry = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    if (!forceRefresh &&
        token != null &&
        token.isNotEmpty &&
        expiry != null &&
        expiry.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      return token;
    }
    final refreshToken = await _storage.read(
      key: _refreshTokenKey,
      iOptions: _ios,
    );
    final clientId = _clientId.isNotEmpty
        ? _clientId
        : (kIsWeb ? webMicrosoftClientIdFromPage() : null);
    if (refreshToken == null || refreshToken.isEmpty || clientId == null) {
      return null;
    }
    final response = await http
        .post(
          Uri.parse(_token),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'client_id': clientId,
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
            'scope': 'openid profile offline_access User.Read Mail.Read',
          },
        )
        .timeout(
          _networkTimeout,
          onTimeout: () => throw const OutlookAuthException(
            'Outlook sign-in refresh timed out. Connect Outlook again and retry.',
          ),
        );
    if (response.statusCode != 200) return null;
    final payload = _body(response);
    final refreshedToken = payload['access_token']?.toString();
    if (refreshedToken == null || refreshedToken.isEmpty) return null;
    await _storage.write(key: _tokenKey, value: refreshedToken, iOptions: _ios);
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
    final nextRefresh = payload['refresh_token']?.toString();
    if (nextRefresh != null && nextRefresh.isNotEmpty) {
      await _storage.write(
        key: _refreshTokenKey,
        value: nextRefresh,
        iOptions: _ios,
      );
    }
    return refreshedToken;
  }

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
