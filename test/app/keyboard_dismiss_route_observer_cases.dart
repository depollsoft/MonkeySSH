// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/keyboard_dismiss_route_observer.dart';

void registerKeyboardDismissRouteObserverTests() {
  group('keyboard_dismiss_route_observer', () {
    MaterialPageRoute<void> fakeRoute() =>
        MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink());

    bool loggedHide(WidgetTester tester) =>
        tester.testTextInput.log.any((call) => call.method == 'TextInput.hide');

    group('KeyboardDismissRouteObserver', () {
      testWidgets('hides the keyboard after a pop when nothing is focused', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        );
        final observer = KeyboardDismissRouteObserver();
        tester.testTextInput.log.clear();

        observer.didPop(fakeRoute(), fakeRoute());
        await tester.pump();

        expect(loggedHide(tester), isTrue);
      });

      testWidgets('hides the keyboard after a push when nothing is focused', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        );
        final observer = KeyboardDismissRouteObserver();
        tester.testTextInput.log.clear();

        observer.didPush(fakeRoute(), fakeRoute());
        await tester.pump();

        expect(loggedHide(tester), isTrue);
      });

      testWidgets('does not hide the keyboard while a text field is focused', (
        tester,
      ) async {
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextField(focusNode: focusNode, autofocus: true),
            ),
          ),
        );
        await tester.pump();
        expect(focusNode.hasPrimaryFocus, isTrue);

        final observer = KeyboardDismissRouteObserver();
        tester.testTextInput.log.clear();

        observer
          ..didPop(fakeRoute(), fakeRoute())
          ..didPush(fakeRoute(), fakeRoute());
        await tester.pump();

        expect(loggedHide(tester), isFalse);
        expect(focusNode.hasPrimaryFocus, isTrue);
      });

      testWidgets('dismisses a lingering keyboard when returning to a screen', (
        tester,
      ) async {
        final observer = KeyboardDismissRouteObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const Scaffold(body: TextField(autofocus: true)),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);

        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();

        expect(tester.testTextInput.isVisible, isFalse);
        expect(loggedHide(tester), isTrue);
      });
    });
  });
}
