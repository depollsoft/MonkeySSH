import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/swipe_snack_bar_messenger.dart';

void main() {
  for (final (direction, offset) in [
    ('left', const Offset(-450, 0)),
    ('right', const Offset(450, 0)),
    ('down', const Offset(0, 80)),
  ]) {
    testWidgets('swiping $direction dismisses only the current message', (
      tester,
    ) async {
      final messenger = await _pumpMessenger(tester);
      var actionTapped = false;
      final alert = messenger.showSnackBar(
        SnackBar(
          key: GlobalKey(),
          content: const Text('Notification'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => actionTapped = true,
          ),
        ),
      );
      final next = messenger.showSnackBar(
        const SnackBar(
          content: Text('Next message'),
          duration: Duration(seconds: 1),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notification'), findsOneWidget);
      await tester.drag(find.text('Notification'), offset);
      await tester.pumpAndSettle();

      expect(await alert.closed, SnackBarClosedReason.swipe);
      expect(actionTapped, isFalse);
      expect(find.text('Notification'), findsNothing);
      expect(find.text('Next message'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(await next.closed, SnackBarClosedReason.timeout);
    });
  }

  testWidgets('an upward drag does not dismiss or activate a message', (
    tester,
  ) async {
    final messenger = await _pumpMessenger(tester);
    var actionTapped = false;
    final alert = messenger.showSnackBar(
      SnackBar(
        content: const Text('Notification'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => actionTapped = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.text('Notification'), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('Notification'), findsOneWidget);
    expect(actionTapped, isFalse);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(actionTapped, isTrue);
    expect(await alert.closed, SnackBarClosedReason.action);
  });

  for (final usesDefaultMargin in [true, false]) {
    testWidgets(
      usesDefaultMargin
          ? 'the default bottom margin accepts a downward swipe'
          : 'an explicit bottom margin lets touches pass through',
      (tester) async {
        final messenger = await _pumpMessenger(tester);
        final alert = messenger.showSnackBar(
          SnackBar(
            content: const Text('Notification'),
            margin: usesDefaultMargin
                ? null
                : const EdgeInsets.fromLTRB(15, 0, 15, 20),
          ),
        );
        await tester.pumpAndSettle();

        final snackBarBottom = tester.getBottomLeft(find.byType(SnackBar)).dy;
        await tester.dragFrom(
          Offset(
            tester.getCenter(find.text('Notification')).dx,
            snackBarBottom - 2,
          ),
          const Offset(0, 80),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Notification'),
          usesDefaultMargin ? findsNothing : findsOneWidget,
        );
        if (usesDefaultMargin) {
          expect(await alert.closed, SnackBarClosedReason.swipe);
        }
      },
    );
  }
}

Future<ScaffoldMessengerState> _pumpMessenger(WidgetTester tester) async {
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      builder: (context, child) =>
          SwipeSnackBarMessenger(key: messengerKey, child: child!),
      home: const Scaffold(),
    ),
  );
  return messengerKey.currentState!;
}
