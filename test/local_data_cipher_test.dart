import 'dart:convert';

import 'package:card_debt_planner/services/app_store.dart';
import 'package:card_debt_planner/services/local_data_cipher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('financial state decrypts only with the local passcode', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cipher = LocalDataCipher(iterations: 100);
    await cipher.unlock(prefs, 'correct-long-passcode');
    final encrypted = await cipher.encrypt('{"balance":123.45}');
    expect(LocalDataCipher.isEncrypted(encrypted), isTrue);
    expect(encrypted, isNot(contains('123.45')));

    final resumed = LocalDataCipher(iterations: 100);
    await resumed.unlock(prefs, 'correct-long-passcode');
    expect(await resumed.decrypt(encrypted), '{"balance":123.45}');

    final wrong = LocalDataCipher(iterations: 100);
    await wrong.unlock(prefs, 'wrong-passcode');
    await expectLater(wrong.decrypt(encrypted), throwsA(isA<Exception>()));
  });

  test('web store migrates plaintext without losing data', () async {
    if (!kIsWeb) return;
    final original = emptyDebtData();
    SharedPreferences.setMockInitialValues({
      'card_debt_planner_state_v1': jsonEncode(original.toJson()),
    });
    final prefs = await SharedPreferences.getInstance();
    final store = AppStore(prefs);
    await store.unlockWithPasscode('a-long-test-passcode');
    await store.load();
    final encrypted = prefs.getString('card_debt_planner_state_v1');
    expect(LocalDataCipher.isEncrypted(encrypted), isTrue);

    final resumed = AppStore(prefs);
    await resumed.unlockWithPasscode('a-long-test-passcode');
    await resumed.load();
    expect(resumed.data.cards, hasLength(original.cards.length));

    final wrong = AppStore(prefs);
    await wrong.unlockWithPasscode('wrong-passcode');
    await expectLater(wrong.load(), throwsA(isA<StateError>()));
    expect(prefs.getString('card_debt_planner_state_v1'), encrypted);
  });
}
