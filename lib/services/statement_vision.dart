import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'statement_ocr.dart';

const _workerUrl = String.fromEnvironment(
  'VISION_WORKER_URL',
  defaultValue: 'https://clearpath-vision.josemiguelrojasguzman860.workers.dev',
);

class StatementVisionService {
  const StatementVisionService();

  Future<List<StatementDraft>> analyze({
    required String fileName,
    required Uint8List imageBytes,
  }) async {
    final mimeType =
        fileName.toLowerCase().endsWith('.jpg') ||
            fileName.toLowerCase().endsWith('.jpeg')
        ? 'image/jpeg'
        : 'image/png';
    final response = await http
        .post(
          Uri.parse(_workerUrl),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image': 'data:$mimeType;base64,${base64Encode(imageBytes)}',
            'fileName': fileName,
          }),
        )
        .timeout(const Duration(seconds: 75));
    if (response.statusCode != 200) {
      throw StateError('Vision Worker returned ${response.statusCode}.');
    }

    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic> || payload['statements'] is! List) {
      throw const FormatException(
        'Vision Worker returned invalid statement data.',
      );
    }
    return (payload['statements'] as List)
        .whereType<Map>()
        .map(
          (statement) => StatementDraft.fromVision(
            fileName: fileName,
            imageBytes: imageBytes,
            values: Map<String, dynamic>.from(statement),
          ),
        )
        .toList();
  }
}
