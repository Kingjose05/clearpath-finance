import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:googleapis_auth/googleapis_auth.dart' as gapis;
import 'package:http/http.dart' as http;

import '../models.dart';
import 'app_store.dart';
import 'bank_email_parser.dart';
import 'gmail_request_queue.dart';
import 'oauth_popup.dart';

class EmailSyncResult {
  const EmailSyncResult({
    required this.accountEmail,
    required this.purchases,
    this.discoveredCards = const [],
    this.hasMore = false,
    required this.message,
  });

  final String? accountEmail;
  final List<Purchase> purchases;
  final List<CreditCard> discoveredCards;
  final bool hasMore;
  final String message;
}

class GmailOAuthClientConfig {
  const GmailOAuthClientConfig({
    required this.clientId,
    required this.clientSecret,
  });

  final String clientId;
  final String clientSecret;

  bool get isComplete =>
      clientId.trim().isNotEmpty && clientSecret.trim().isNotEmpty;
}

class GmailDeviceAuthorization {
  const GmailDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUrl;
  final int expiresIn;
  final int interval;
}

class GmailSyncException implements Exception {
  const GmailSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GmailPurchaseSyncService {
  GmailPurchaseSyncService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const List<String> _scopes = [gmail.GmailApi.gmailReadonlyScope];
  static const _authorizationEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const _deviceCodeEndpoint =
      'https://oauth2.googleapis.com/device/code';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const _bundledClientId = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_ID',
  );
  static const _bundledClientSecret = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_SECRET',
  );
  static const _clientIdKey = 'gmail_client_id';
  static const _clientSecretKey = 'gmail_client_secret';
  static const _refreshTokenKey = 'gmail_refresh_token';
  static const _accessTokenKey = 'gmail_access_token';
  static const _accessTokenExpiresAtKey = 'gmail_access_token_expires_at';
  static const _emailKey = 'gmail_account_email';
  static const _purchaseSearch =
      '{BHD APAP Banreservas "Banco Popular" Scotiabank ACAP Promerica '
      '"Banco Caribe" Banesco "La Nacional" Ademi Adopem "Santa Cruz" '
      'Qik Lafise BDI Citibank Bandex Banfondesa JMMB Alaver ABONAP '
      'subject:transacciones '
      'subject:notificaciones subject:consumo subject:purchase '
      'subject:transaction subject:approved subject:compra '
      'subject:aprobada subject:autorizada subject:retiro subject:pago '
      'subject:deposito subject:transferencia "card ending" "tarjeta terminada" '
      '"consumo realizado" "transaccion realizada" "tarjeta de debito" '
      '"retiro en cajero" "deposito de sueldo" "payment approved" '
      '"cash withdrawal" "transferencia recibida" "transferencia enviada"}';
  static final _requests = GmailRequestQueue();
  static bool _syncActive = false;
  final status = ValueNotifier<String>('');

  Future<T> _request<T>(Future<T> Function() call) =>
      _requests.run(call, onStatus: (value) => status.value = value);

  final FlutterSecureStorage _storage;

  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  Future<GmailOAuthClientConfig?> readOAuthClientConfig() async {
    if (_bundledClientId.trim().isNotEmpty &&
        _bundledClientSecret.trim().isNotEmpty) {
      return const GmailOAuthClientConfig(
        clientId: _bundledClientId,
        clientSecret: _bundledClientSecret,
      );
    }
    final clientId = await _read(_clientIdKey);
    final clientSecret = await _read(_clientSecretKey);
    if (clientId == null ||
        clientId.trim().isEmpty ||
        clientSecret == null ||
        clientSecret.trim().isEmpty) {
      return null;
    }
    return GmailOAuthClientConfig(
      clientId: clientId,
      clientSecret: clientSecret,
    );
  }

  Future<void> saveOAuthClientConfig(GmailOAuthClientConfig config) async {
    if (!config.isComplete) {
      throw const GmailSyncException('Add both Google OAuth values first.');
    }
    await _write(_clientIdKey, config.clientId.trim());
    await _write(_clientSecretKey, config.clientSecret.trim());
  }

  Future<bool> hasRefreshToken() async {
    final token = await _read(_refreshTokenKey);
    return token != null && token.trim().isNotEmpty;
  }

  Future<bool> hasGoogleAccess() async {
    if (await hasRefreshToken()) return true;
    final rawToken = await _read(_accessTokenKey);
    final rawExpiry = await _read(_accessTokenExpiresAtKey);
    final expiry = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    return rawToken != null &&
        rawToken.isNotEmpty &&
        expiry != null &&
        expiry.isAfter(DateTime.now().add(const Duration(minutes: 5)));
  }

  Future<String?> connectedEmail() => _read(_emailKey);

  Future<EmailSyncResult> connectWithGoogle(
    List<CreditCard> cards, {
    Set<String> excludedMessageIds = const {},
  }) async {
    if (await hasGoogleAccess()) return _connectionResult();
    if (kIsWeb) {
      return _connectWithGooglePopup(
        cards,
        excludedMessageIds: excludedMessageIds,
      );
    }

    final config = await readOAuthClientConfig();
    if (config == null) {
      throw const GmailSyncException(
        'Google sign-in needs an OAuth client configured in the app build.',
      );
    }
    final authorization = await beginDeviceAuthorization();
    throw GmailSyncException(
      'Open ${authorization.verificationUrl} and enter ${authorization.userCode}.',
    );
  }

  Future<EmailSyncResult> _connectWithGooglePopup(
    List<CreditCard> cards, {
    Set<String> excludedMessageIds = const {},
  }) async {
    final clientId = await _googleClientId();
    if (clientId == null || clientId.trim().isEmpty) {
      throw const GmailSyncException(
        'Google sign-in is not configured for this build.',
      );
    }
    final redirectUri = currentWebOAuthRedirectUri();
    if (redirectUri == null) {
      throw const GmailSyncException('Google sign-in is unavailable here.');
    }

    final authorizationUri = Uri.parse(_authorizationEndpoint).replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri.toString(),
        'response_type': 'token',
        'scope': _scopes.join(' '),
        'include_granted_scopes': 'true',
        'prompt': 'consent',
      },
    );

    final result = await openOAuthPopup(authorizationUri);
    if (result.cancelled) {
      throw const GmailSyncException('Google sign-in was cancelled.');
    }
    if (result.error != null && result.error!.isNotEmpty) {
      throw GmailSyncException(result.error!);
    }
    final accessToken = result.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw const GmailSyncException('Google did not return access.');
    }

    await _persistAccessToken(
      accessToken,
      DateTime.now().add(Duration(seconds: result.expiresIn ?? 3600)),
    );
    return _connectionResult();
  }

  Future<EmailSyncResult> _connectionResult() async {
    status.value = 'Checking Gmail connection...';
    final client = gapis.authenticatedClient(
      http.Client(),
      await _credentials(),
    );
    try {
      final profile = await _request(
        () => gmail.GmailApi(client).users.getProfile('me'),
      );
      if (profile.emailAddress != null) {
        await _write(_emailKey, profile.emailAddress!);
      }
      status.value = 'Gmail connected';
      return EmailSyncResult(
        accountEmail: profile.emailAddress,
        purchases: const [],
        message:
            'Gmail connected. Choose Import cards & purchases to select a date range.',
      );
    } finally {
      client.close();
    }
  }

  Future<GmailDeviceAuthorization> beginDeviceAuthorization() async {
    final config = await readOAuthClientConfig();
    if (config == null) {
      throw const GmailSyncException('Google OAuth client is not configured.');
    }

    final response = await http.post(
      Uri.parse(_deviceCodeEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'client_id': config.clientId, 'scope': _scopes.join(' ')},
    );
    final payload = _jsonBody(response);
    if (response.statusCode != 200) {
      throw GmailSyncException(
        payload['error_description'] as String? ??
            payload['error'] as String? ??
            'Could not start Google authorization.',
      );
    }

    return GmailDeviceAuthorization(
      deviceCode: payload['device_code'] as String,
      userCode: payload['user_code'] as String,
      verificationUrl: Uri.parse(payload['verification_url'] as String),
      expiresIn: payload['expires_in'] as int? ?? 1800,
      interval: payload['interval'] as int? ?? 5,
    );
  }

  Future<EmailSyncResult> completeDeviceAuthorization(
    GmailDeviceAuthorization authorization, {
    required List<CreditCard> cards,
    Duration maxPollingTime = const Duration(seconds: 90),
  }) async {
    final config = await readOAuthClientConfig();
    if (config == null) {
      throw const GmailSyncException('Google OAuth client is not configured.');
    }

    final deadline = DateTime.now().add(maxPollingTime);
    var interval = math.max(authorization.interval, 5);
    while (DateTime.now().isBefore(deadline)) {
      final response = await http.post(
        Uri.parse(_tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': config.clientId,
          'client_secret': config.clientSecret,
          'device_code': authorization.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      final payload = _jsonBody(response);
      if (response.statusCode == 200) {
        await _persistTokenPayload(payload);
        return _connectionResult();
      }

      final error = payload['error'] as String?;
      if (error == 'authorization_pending') {
        await Future<void>.delayed(Duration(seconds: interval));
        continue;
      }
      if (error == 'slow_down') {
        interval += 5;
        await Future<void>.delayed(Duration(seconds: interval));
        continue;
      }
      throw GmailSyncException(
        payload['error_description'] as String? ??
            error ??
            'Google authorization failed.',
      );
    }
    throw const GmailSyncException(
      'Google authorization is still pending. Finish the approval and try again.',
    );
  }

  Future<EmailSyncResult> syncRecentPurchases(
    List<CreditCard> cards, {
    DateTime? since,
    DateTime? until,
    bool discoverCards = false,
    bool scanAllMessages = false,
    Set<String> excludedMessageIds = const {},
    Future<void> Function(EmailSyncResult)? onBatch,
  }) async {
    if (_syncActive) {
      throw const GmailSyncException('A Gmail sync is already running.');
    }
    _syncActive = true;
    try {
      return await _syncPurchases(
        cards,
        since: since,
        until: until,
        discoverCards: discoverCards,
        scanAllMessages: scanAllMessages,
        excludedMessageIds: excludedMessageIds,
        onBatch: onBatch,
      );
    } finally {
      _syncActive = false;
    }
  }

  Future<EmailSyncResult> _syncPurchases(
    List<CreditCard> cards, {
    DateTime? since,
    DateTime? until,
    required bool discoverCards,
    required bool scanAllMessages,
    required Set<String> excludedMessageIds,
    Future<void> Function(EmailSyncResult)? onBatch,
  }) async {
    final credentials = await _credentials();
    final client = gapis.authenticatedClient(http.Client(), credentials);

    try {
      final api = gmail.GmailApi(client);
      status.value = 'Checking Gmail connection...';
      final profile = await _request(() => api.users.getProfile('me'));
      final accountEmail = profile.emailAddress;
      if (accountEmail != null && accountEmail.isNotEmpty) {
        await _write(_emailKey, accountEmail);
      }

      final queryParts = <String>[];
      if (since != null) queryParts.add('after:${_gmailDate(since)}');
      if (until != null) queryParts.add('before:${_gmailDate(until)}');
      if (!scanAllMessages) {
        queryParts.add(_purchaseSearch);
      }

      final messageItems = <gmail.Message>[];
      String? pageToken;
      do {
        status.value = 'Finding bank emails (${messageItems.length} found)...';
        final page = await _request(
          () => api.users.messages.list(
            'me',
            maxResults: 200,
            pageToken: pageToken,
            q: queryParts.join(' '),
          ),
        );
        for (final message in page.messages ?? const <gmail.Message>[]) {
          final id = message.id;
          if (id == null || excludedMessageIds.contains(id)) continue;
          messageItems.add(message);
        }
        pageToken = page.nextPageToken;
      } while (pageToken != null && pageToken.isNotEmpty);

      final knownCards = [...cards];
      final discoveredByLastFour = <String, CreditCard>{};
      final parsed = <Purchase>[];
      var checked = 0;
      for (final item in messageItems) {
        final id = item.id;
        if (id == null) continue;
        status.value =
            'Reading email ${checked + 1} of ${messageItems.length}...';
        final full = await _request(
          () => api.users.messages.get('me', id, format: 'full'),
        );
        final transactions = parseBankTransactions(full);
        for (final transaction in transactions) {
          var card = _firstCardWithLastFour(
            knownCards,
            transaction.lastFour,
            accountType: transaction.accountType,
            currency: transaction.currency,
          );
          if (card == null) {
            card = _inferredCard(
              transaction.lastFour,
              accountType: transaction.accountType,
              currency: transaction.currency,
              bank: transaction.bank,
              needsReview: transaction.needsReview,
            );
            discoveredByLastFour[transaction.lastFour] = card;
            knownCards.add(card);
          }
          final relatedCard = transaction.counterpartyLastFour == null
              ? null
              : _firstCardWithLastFour(
                  knownCards,
                  transaction.counterpartyLastFour!,
                  accountType: AccountType.debit,
                  currency: transaction.currency,
                );
          parsed.add(
            Purchase(
              id: newId('email'),
              cardId: card.id,
              merchant: transaction.merchant,
              amount: transaction.amount,
              purchasedAt: transaction.date,
              source: PurchaseSource.email,
              subject: messageHeader(full, 'subject'),
              sourceMessageId: full.id,
              kind: transaction.kind,
              category: transaction.category,
              currency: transaction.currency,
              transferReference: transaction.transferReference,
              relatedCardId: relatedCard?.id,
            ),
          );
        }
        checked++;
        if (onBatch != null && checked % 25 == 0) {
          await onBatch(
            EmailSyncResult(
              accountEmail: accountEmail,
              purchases: List.of(parsed),
              discoveredCards: discoveredByLastFour.values.toList(),
              message: '$checked of ${messageItems.length} emails checked',
            ),
          );
        }
      }
      final discoveredCards = discoveredByLastFour.values.toList();
      status.value =
          '${messageItems.length} emails checked; ${parsed.length} transactions found';
      return EmailSyncResult(
        accountEmail: accountEmail,
        purchases: parsed,
        discoveredCards: discoveredCards,
        message: parsed.isEmpty && discoveredCards.isEmpty
            ? 'No supported bank transactions found in that range'
            : '${discoveredCards.length} account${discoveredCards.length == 1 ? '' : 's'} found, '
                  '${parsed.length} transaction${parsed.length == 1 ? '' : 's'} imported',
      );
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (message.contains('quota exceeded') ||
          message.contains('rate limit') ||
          message.contains('userratelimitexceeded')) {
        throw const GmailSyncException(
          'Gmail is still limiting requests after automatic retries. '
          'Saved imports are kept. Try Sync Gmail now again shortly.',
        );
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  CreditCard _inferredCard(
    String lastFour, {
    AccountType accountType = AccountType.credit,
    String currency = 'DOP',
    String? bank,
    bool needsReview = false,
  }) {
    const accentColors = [0xFF0F766E, 0xFF2563EB, 0xFFB45309, 0xFFDC2626];
    return CreditCard(
      id: 'card-email-${accountType.name}-${currency.toLowerCase()}-$lastFour',
      name:
          '${bank == null ? '' : '$bank '}${accountType == AccountType.debit ? 'Debit' : 'Credit'} $currency •$lastFour',
      lastFour: lastFour,
      balance: 0,
      creditLimit: 0,
      apr: 0,
      cutoffDay: 1,
      dueDay: 1,
      minimumDue: 0,
      accentColor: accentColors[lastFour.codeUnitAt(0) % accentColors.length],
      emailMatchTerms: [lastFour],
      accountType: accountType,
      currency: currency,
      needsReview: needsReview,
    );
  }

  Future<void> disconnect() async {
    await _storage.delete(key: _refreshTokenKey, iOptions: _iosOptions);
    await _storage.delete(key: _accessTokenKey, iOptions: _iosOptions);
    await _storage.delete(key: _accessTokenExpiresAtKey, iOptions: _iosOptions);
    await _storage.delete(key: _emailKey, iOptions: _iosOptions);
  }

  Future<void> clearOAuthClientConfig() async {
    await disconnect();
    await _storage.delete(key: _clientIdKey, iOptions: _iosOptions);
    await _storage.delete(key: _clientSecretKey, iOptions: _iosOptions);
  }

  Future<gapis.AccessCredentials> _credentials() async {
    final accessToken = await _validAccessToken();
    return gapis.AccessCredentials(
      gapis.AccessToken(
        'Bearer',
        accessToken.value,
        accessToken.expiresAt.toUtc(),
      ),
      null,
      _scopes,
    );
  }

  Future<_AccessToken> _validAccessToken() async {
    final rawToken = await _read(_accessTokenKey);
    final rawExpiry = await _read(_accessTokenExpiresAtKey);
    final expiry = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    if (rawToken != null &&
        rawToken.isNotEmpty &&
        expiry != null &&
        expiry.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return _AccessToken(rawToken, expiry);
    }
    return _refreshAccessToken();
  }

  Future<_AccessToken> _refreshAccessToken() async {
    final config = await readOAuthClientConfig();
    final refreshToken = await _read(_refreshTokenKey);
    if (config == null || refreshToken == null || refreshToken.isEmpty) {
      throw const GmailSyncException(
        'Gmail is not connected. Complete Google authorization first.',
      );
    }

    final body = <String, String>{
      'client_id': config.clientId,
      'client_secret': config.clientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    };
    final response = await http.post(
      Uri.parse(_tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );
    final payload = _jsonBody(response);
    if (response.statusCode != 200) {
      throw GmailSyncException(
        payload['error_description'] as String? ??
            payload['error'] as String? ??
            'Could not refresh Gmail access.',
      );
    }
    return _persistTokenPayload(payload, keepExistingRefreshToken: true);
  }

  Future<_AccessToken> _persistTokenPayload(
    Map<String, dynamic> payload, {
    bool keepExistingRefreshToken = false,
  }) async {
    final accessToken = payload['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw const GmailSyncException('Google did not return an access token.');
    }

    final expiresIn = payload['expires_in'] as int? ?? 3600;
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    await _write(_accessTokenKey, accessToken);
    await _write(_accessTokenExpiresAtKey, expiresAt.toIso8601String());

    final refreshToken = payload['refresh_token'] as String?;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _write(_refreshTokenKey, refreshToken);
    } else if (!keepExistingRefreshToken) {
      throw const GmailSyncException('Google did not return a refresh token.');
    }

    return _AccessToken(accessToken, expiresAt);
  }

  Future<void> _persistAccessToken(
    String accessToken,
    DateTime expiresAt,
  ) async {
    await _write(_accessTokenKey, accessToken);
    await _write(_accessTokenExpiresAtKey, expiresAt.toIso8601String());
  }

  Future<String?> _googleClientId() async {
    if (_bundledClientId.trim().isNotEmpty) return _bundledClientId.trim();
    if (kIsWeb) {
      final pageClientId = webGoogleClientIdFromPage();
      if (pageClientId != null && pageClientId.trim().isNotEmpty) {
        return pageClientId.trim();
      }
    }
    final stored = await _read(_clientIdKey);
    if (stored != null && stored.trim().isNotEmpty) return stored.trim();
    return null;
  }

  Future<String?> _read(String key) =>
      _storage.read(key: key, iOptions: _iosOptions);

  Future<void> _write(String key, String value) =>
      _storage.write(key: key, value: value, iOptions: _iosOptions);
}

class _AccessToken {
  const _AccessToken(this.value, this.expiresAt);

  final String value;
  final DateTime expiresAt;
}

CreditCard? _firstCardWithLastFour(
  List<CreditCard> cards,
  String lastFour, {
  AccountType? accountType,
  String? currency,
}) {
  for (final card in cards) {
    if (card.lastFour == lastFour &&
        (accountType == null || card.accountType == accountType) &&
        (currency == null || card.currency == currency)) {
      return card;
    }
  }
  return null;
}

Map<String, dynamic> _jsonBody(http.Response response) {
  if (response.body.trim().isEmpty) return <String, dynamic>{};
  return jsonDecode(response.body) as Map<String, dynamic>;
}

Purchase? parseGmailMessage(
  gmail.Message message,
  List<CreditCard> cards, {
  bool requireCardMatch = false,
}) {
  if (cards.isEmpty) return null;
  final subject = _header(message, 'subject') ?? 'Card purchase';
  final body = _bodyText(message.payload);
  final text = '$subject\n${message.snippet ?? ''}\n$body';
  final amount = _extractAmount(text);
  if (amount == null || amount <= 0) return null;

  final matchedCard = _matchCard(text, cards);
  if (requireCardMatch && matchedCard == null) return null;
  final merchant = _extractMerchant(text, subject);
  final timestamp = int.tryParse(message.internalDate ?? '');
  final purchasedAt = timestamp == null
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(timestamp);

  return Purchase(
    id: newId('email'),
    cardId: matchedCard?.id ?? cards.first.id,
    merchant: merchant,
    amount: amount,
    purchasedAt: purchasedAt,
    source: PurchaseSource.email,
    subject: subject,
    sourceMessageId: message.id,
    needsReview: matchedCard == null || merchant == 'Unknown merchant',
  );
}

String _gmailDate(DateTime date) {
  final value = date.toUtc();
  return '${value.year.toString().padLeft(4, '0')}/'
      '${value.month.toString().padLeft(2, '0')}/'
      '${value.day.toString().padLeft(2, '0')}';
}

String? _header(gmail.Message message, String name) {
  final headers = message.payload?.headers ?? const <gmail.MessagePartHeader>[];
  for (final header in headers) {
    if (header.name?.toLowerCase() == name.toLowerCase()) {
      return header.value;
    }
  }
  return null;
}

String _bodyText(gmail.MessagePart? part) {
  if (part == null) return '';
  final chunks = <String>[];
  final data = part.body?.data;
  if (data != null && data.isNotEmpty) {
    try {
      chunks.add(utf8.decode(base64Url.decode(base64Url.normalize(data))));
    } catch (_) {
      // Ignore unreadable MIME chunks.
    }
  }
  for (final child in part.parts ?? const <gmail.MessagePart>[]) {
    chunks.add(_bodyText(child));
  }
  return chunks.join('\n');
}

double? _extractAmount(String text) {
  final amountPattern = RegExp(
    r'(?:RD\$|DOP|US\$|USD|\$)\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?|[0-9]+(?:\.[0-9]{2})?)',
    caseSensitive: false,
  );
  final values = amountPattern.allMatches(text).map((match) {
    final raw = match.group(1)?.replaceAll(',', '');
    return raw == null ? null : double.tryParse(raw);
  }).whereType<double>();
  if (values.isEmpty) return null;
  return values.reduce(math.max);
}

CreditCard? _matchCard(String text, List<CreditCard> cards) {
  final normalized = text.toLowerCase();
  for (final card in cards) {
    if (card.lastFour.isNotEmpty && normalized.contains(card.lastFour)) {
      return card;
    }
    for (final term in card.emailMatchTerms) {
      if (term.trim().isNotEmpty && normalized.contains(term.toLowerCase())) {
        return card;
      }
    }
  }
  return null;
}

String _extractMerchant(String text, String subject) {
  final patterns = [
    RegExp(
      r'(?:at|en|comercio:|merchant:)\s+([A-Za-z0-9 &.\-_\xC0-\xFF]+)',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:purchase from|compra en)\s+([A-Za-z0-9 &.\-_\xC0-\xFF]+)',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(text);
    final merchant = match?.group(1)?.trim();
    if (merchant != null && merchant.length >= 2) {
      return merchant.split(RegExp(r'\s{2,}|\n')).first.trim();
    }
  }
  final cleaned = subject
      .replaceAll(
        RegExp(
          r'purchase|approved|transaction|notification|compra',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'ending\s+\d{4}', caseSensitive: false), '')
      .trim();
  return cleaned.length >= 3 ? cleaned : 'Unknown merchant';
}
