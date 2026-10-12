import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkeymux_offer_sheet.dart';

void main() {
  Future<bool?> answer(WidgetTester tester, String buttonKey) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showMonkeyMuxOfferSheet(
              context,
              sessionName: 'proj-alpha',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Use MonkeyMux on this host?'), findsOneWidget);
    // The upload and the session it opens are stated before agreeing.
    expect(find.textContaining('~/.monkeyssh', findRichText: true), findsOne);
    expect(find.textContaining('proj-alpha', findRichText: true), findsOne);
    await tester.tap(find.byKey(ValueKey(buttonKey)));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('choosing MonkeyMux answers true', (tester) async {
    expect(await answer(tester, 'monkeymux-offer-accept'), isTrue);
  });

  testWidgets('not now answers false', (tester) async {
    expect(await answer(tester, 'monkeymux-offer-decline'), isFalse);
  });
}
