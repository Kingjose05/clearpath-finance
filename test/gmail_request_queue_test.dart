import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:card_debt_planner/services/gmail_request_queue.dart';

void main() {
  late DateTime now;
  late List<Duration> waits;
  late GmailRequestQueue queue;
  setUp(() {
    now = DateTime.utc(2026, 9, 9);
    waits = [];
    queue = GmailRequestQueue(
      now: () => now,
      jitter: () => 0,
      sleep: (duration) async {
        waits.add(duration);
        now = now.add(duration);
      },
    );
  });

  test('spaces 400 queued reads below the 6000-unit minute limit', () async {
    final started = <DateTime>[];
    await Future.wait(
      List.generate(
        400,
        (_) => queue.run(() async {
          started.add(now);
        }),
      ),
    );
    for (final start in started) {
      final reads = started
          .where(
            (t) =>
                !t.isBefore(start) &&
                t.isBefore(start.add(const Duration(minutes: 1))),
          )
          .length;
      expect(reads * 20, lessThanOrEqualTo(2020));
    }
    expect(waits.length, 399);
  });

  test(
    'retries the reported 403 quota failure and returns real success',
    () async {
      var attempts = 0;
      final statuses = <String>[];
      final result = await queue.run(() async {
        if (++attempts <= 6) {
          throw gmail.DetailedApiRequestError(
            403,
            "Quota exceeded for quota metric 'Total Query Cost' and limit 'Units per minute per user'",
          );
        }
        return 'success';
      }, onStatus: statuses.add);
      expect(result, 'success');
      expect(attempts, 7);
      expect(waits.map((d) => d.inSeconds), [2, 4, 8, 16, 32, 60]);
      expect(statuses.last, contains('Retrying in 60 seconds'));
    },
  );

  test('does not retry permissions or daily quota failures', () async {
    for (final error in [
      gmail.DetailedApiRequestError(403, 'Insufficient Permission'),
      gmail.DetailedApiRequestError(403, 'Daily quota exceeded'),
    ]) {
      await expectLater(
        queue.run(() async => throw error),
        throwsA(same(error)),
      );
    }
    expect(waits.every((d) => d < const Duration(seconds: 1)), isTrue);
    expect(await queue.run(() async => 42), 42);
  });

  test('stops retrying persistent quota errors', () async {
    var attempts = 0;
    await expectLater(
      queue.run(() async {
        attempts++;
        throw gmail.DetailedApiRequestError(429, 'Too many requests');
      }),
      throwsA(isA<gmail.DetailedApiRequestError>()),
    );
    expect(attempts, 8);
  });
}
