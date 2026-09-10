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

Uri? currentWebOAuthRedirectUri() => null;

String? webGoogleClientIdFromPage() => null;

Future<OAuthPopupResult> openOAuthPopup(Uri authorizationUri) async {
  return const OAuthPopupResult(
    error: 'Google sign-in is available in the web version of ClearPath.',
  );
}
