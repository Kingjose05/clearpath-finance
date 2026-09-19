import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'dart:typed_data';

Future<String> extractStatementText(
  String? path, {
  Uint8List? imageBytes,
}) async {
  if (path == null || path.isEmpty) return '';
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final recognized = await recognizer.processImage(
      InputImage.fromFilePath(path),
    );
    return recognized.text;
  } finally {
    await recognizer.close();
  }
}
