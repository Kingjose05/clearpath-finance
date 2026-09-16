import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

Future<String> extractStatementText(String? path) async {
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
