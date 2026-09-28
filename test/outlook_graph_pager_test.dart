import 'dart:convert';

import 'package:card_debt_planner/services/outlook_graph_pager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final first = Uri.https('graph.microsoft.com', '/v1.0/me/messages', {
    r'$top': '50',
  });

  test('reads every Outlook page and saves each batch', () async {
    final second = Uri.https('graph.microsoft.com', '/v1.0/me/messages', {
      r'$skiptoken': 'page-two',
    });
    final saved = <String>[];
    final total = await forEachOutlookMessagePage(
      firstPage: first,
      fetch: (uri) async => http.Response(
        jsonEncode(
          uri == first
              ? {
                  'value': [
                    {'id': 'first-message'},
                  ],
                  '@odata.nextLink': second.toString(),
                }
              : {
                  'value': [
                    {'id': 'second-message'},
                  ],
                },
        ),
        200,
      ),
      onPage: (messages, page) async =>
          saved.add(messages.single['id'] as String),
    );

    expect(total, 2);
    expect(saved, ['first-message', 'second-message']);
  });

  test('rejects a repeated page link instead of spinning forever', () async {
    await expectLater(
      forEachOutlookMessagePage(
        firstPage: first,
        fetch: (_) async => http.Response(
          jsonEncode({'value': [], '@odata.nextLink': first.toString()}),
          200,
        ),
        onPage: (_, _) async {},
      ),
      throwsA(isA<OutlookPageException>()),
    );
  });

  test('stops on a later-page error without claiming completion', () async {
    var savedPages = 0;
    await expectLater(
      forEachOutlookMessagePage(
        firstPage: first,
        fetch: (uri) async => uri == first
            ? http.Response(
                jsonEncode({
                  'value': [
                    {'id': 'first-message'},
                  ],
                  '@odata.nextLink':
                      'https://graph.microsoft.com/v1.0/me/messages?next=2',
                }),
                200,
              )
            : http.Response(
                jsonEncode({
                  'error': {'message': 'Request limit reached'},
                }),
                429,
              ),
        onPage: (_, _) async => savedPages++,
      ),
      throwsA(isA<OutlookPageException>()),
    );
    expect(savedPages, 1);
  });
}
