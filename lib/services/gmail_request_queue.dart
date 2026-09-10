import 'dart:async';
import 'dart:math';

import 'package:googleapis/gmail/v1.dart' as gmail;

/// Serializes reads and leaves quota headroom for other tabs and applications.
class GmailRequestQueue {
  GmailRequestQueue({
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    int Function()? jitter,
    this.spacing = const Duration(milliseconds: 600),
    this.maxRetries = 7,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _now = now ?? DateTime.now,
       _jitter = jitter ?? (() => Random().nextInt(1000));

  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;
  final int Function() _jitter;
  final Duration spacing;
  final int maxRetries;
  Future<void> _tail = Future<void>.value();
  DateTime? _nextRequest;

  Future<T> run<T>(
    Future<T> Function() request, {
    void Function(String)? onStatus,
  }) {
    final result = _tail.then((_) => _run(request, onStatus));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<T> _run<T>(
    Future<T> Function() request,
    void Function(String)? onStatus,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final remaining = _nextRequest?.difference(_now()) ?? Duration.zero;
      if (remaining > Duration.zero) await _sleep(remaining);
      _nextRequest = _now().add(spacing);
      try {
        return await request();
      } on gmail.DetailedApiRequestError catch (error) {
        if (!isRetryableGmailError(error) || attempt >= maxRetries) rethrow;
        final wait = Duration(
          seconds: min(2 << attempt, 60),
          milliseconds: _jitter(),
        );
        onStatus?.call(
          'Gmail is busy. Retrying in ${wait.inSeconds} seconds '
          '(${attempt + 1}/$maxRetries)...',
        );
        await _sleep(wait);
      }
    }
  }
}

bool isRetryableGmailError(gmail.DetailedApiRequestError error) {
  if (error.status == 429 || (error.status ?? 0) >= 500) return true;
  if (error.status != 403) return false;
  final reasons = error.errors.map((detail) => detail.reason).toSet();
  if (reasons.contains('dailyLimitExceeded')) return false;
  return reasons.any(
        {
          'rateLimitExceeded',
          'userRateLimitExceeded',
          'quotaExceeded',
        }.contains,
      ) ||
      (error.message ?? '').toLowerCase().contains('units per minute') ||
      (error.message ?? '').toLowerCase().contains('rate limit');
}
