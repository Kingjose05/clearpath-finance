import 'dart:convert';

import 'package:http/http.dart' as http;

class OutlookPageException implements Exception {
  const OutlookPageException(this.message);
  final String message;

  @override
  String toString() => message;
}

Future<int> forEachOutlookMessagePage({
  required Uri firstPage,
  required Future<http.Response> Function(Uri) fetch,
  required Future<void> Function(List<Map<String, dynamic>>, int) onPage,
}) async {
  Uri? next = firstPage;
  final visited = <Uri>{};
  var count = 0;
  var pageNumber = 0;
  while (next != null) {
    if (next.scheme != 'https' ||
        next.host != 'graph.microsoft.com' ||
        next.path != '/v1.0/me/messages' ||
        !visited.add(next)) {
      throw const OutlookPageException(
        'Outlook returned an invalid page link.',
      );
    }
    final response = await fetch(next);
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const OutlookPageException(
        'Outlook returned an unreadable response.',
      );
    }
    if (response.statusCode != 200) {
      final detail = payload['error'];
      throw OutlookPageException(
        detail is Map && detail['message'] is String
            ? detail['message'] as String
            : 'Outlook could not read messages (${response.statusCode}).',
      );
    }
    final values = payload['value'];
    if (values is! List) {
      throw const OutlookPageException(
        'Outlook returned a page without messages.',
      );
    }
    final messages = values
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    pageNumber++;
    count += messages.length;
    await onPage(messages, pageNumber);
    final link = payload['@odata.nextLink'];
    next = link is String && link.isNotEmpty ? Uri.tryParse(link) : null;
    if (link is String && link.isNotEmpty && next == null) {
      throw const OutlookPageException(
        'Outlook returned an invalid page link.',
      );
    }
  }
  return count;
}
