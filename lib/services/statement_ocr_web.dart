import 'dart:js_interop';
import 'dart:typed_data';

@JS('clearPathExtractStatementText')
external JSPromise<JSString> _extractStatementText(JSUint8Array bytes);

Future<String> extractStatementText(
  String? path, {
  Uint8List? imageBytes,
}) async {
  if (imageBytes == null || imageBytes.isEmpty) return '';
  return (await _extractStatementText(imageBytes.toJS).toDart).toDart;
}
