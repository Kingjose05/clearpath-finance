import 'package:card_debt_planner/main.dart';
import 'package:card_debt_planner/services/app_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('local data stays locked until the correct passcode is entered', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    Widget gate(AppStore store) => AppLockGate(
      preferences: prefs,
      store: store,
      child: const MaterialApp(home: Scaffold(body: Text('Unlocked data'))),
    );

    await tester.pumpWidget(gate(AppStore(prefs)));
    expect(find.text('Unlocked data'), findsNothing);
    await tester.enterText(find.byType(TextField), 'long-passcode');
    await tester.tap(find.text('Create and continue'));
    await tester.pumpAndSettle();
    expect(find.text('Unlocked data'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(gate(AppStore(prefs)));
    expect(find.text('Unlocked data'), findsNothing);
    await tester.enterText(find.byType(TextField), 'wrong-passcode');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Unlocked data'), findsNothing);

    await tester.enterText(find.byType(TextField), 'long-passcode');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Unlocked data'), findsOneWidget);
  }, skip: kIsWeb);
}
