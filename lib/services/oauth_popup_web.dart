import 'dart:async';
import 'dart:html' as html;

class OAuthPopupResult {
  const OAuthPopupResult({
    this.accessToken,
    this.expiresIn,
    this.error,
    this.cancelled = false,
  });

  final String? accessToken;
  final int? expiresIn;
  final String? error;
  final bool cancelled;
}

Uri? currentWebOAuthRedirectUri() => Uri.base.resolve('auth.html');

String? webGoogleClientIdFromPage() {
  return html.document
      .querySelector('meta[name="google-oauth-client-id"]')
      ?.getAttribute('content');
}

Future<OAuthPopupResult> openOAuthPopup(Uri authorizationUri) {
  html.window.open(
    authorizationUri.toString(),
    'debt_plan_google_sign_in',
    'popup=yes,width=520,height=680',
  );
  final completer = Completer<OAuthPopupResult>();
  late final StreamSubscription<html.MessageEvent> listener;
  Timer? timeout;

  void finish(OAuthPopupResult result) {
    if (completer.isCompleted) return;
    timeout?.cancel();
    listener.cancel();
    completer.complete(result);
  }

  listener = html.window.onMessage.listen((event) {
    if (event.origin != Uri.base.origin) return;
    final data = event.data;
    if (data is! Map || data['source'] != 'debt-plan-google-oauth') return;
    final accessToken = data['accessToken']?.toString();
    final expiresIn = int.tryParse(data['expiresIn']?.toString() ?? '');
    final error = data['error']?.toString();
    finish(
      OAuthPopupResult(
        accessToken: accessToken,
        expiresIn: expiresIn,
        error: error,
        cancelled: data['cancelled'] == true,
      ),
    );
  });

  timeout = Timer(const Duration(minutes: 5), () {
    finish(
      const OAuthPopupResult(
        error: 'Google sign-in timed out. Please try again.',
      ),
    );
  });
  return completer.future;
}
