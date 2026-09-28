import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalDataCipher {
  LocalDataCipher({int iterations = 120000}) : _iterations = iterations;

  static const prefix = 'clearpath-encrypted-v1:';
  static const saltStorageKey = 'clearpath_local_data_salt_v1';

  final _algorithm = AesGcm.with256bits();
  final int _iterations;
  SecretKey? _key;

  bool get isUnlocked => _key != null;
  static bool isEncrypted(String? value) => value?.startsWith(prefix) == true;

  Future<void> unlock(SharedPreferences prefs, String passcode) async {
    var encodedSalt = prefs.getString(saltStorageKey);
    if (encodedSalt == null) {
      final random = Random.secure();
      encodedSalt = base64Encode(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );
      await prefs.setString(saltStorageKey, encodedSalt);
    }
    _key =
        await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: _iterations,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(passcode)),
          nonce: base64Decode(encodedSalt),
        );
  }

  Future<String> encrypt(String plaintext) async {
    final key = _key;
    if (key == null) throw StateError('Local data is locked.');
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
    );
    return '$prefix${base64Encode(box.concatenation())}';
  }

  Future<String> decrypt(String encrypted) async {
    final key = _key;
    if (key == null) throw StateError('Local data is locked.');
    if (!isEncrypted(encrypted)) {
      throw const FormatException('Not encrypted ClearPath data.');
    }
    final box = SecretBox.fromConcatenation(
      base64Decode(encrypted.substring(prefix.length)),
      nonceLength: _algorithm.nonceLength,
      macLength: _algorithm.macAlgorithm.macLength,
    );
    return utf8.decode(await _algorithm.decrypt(box, secretKey: key));
  }
}
