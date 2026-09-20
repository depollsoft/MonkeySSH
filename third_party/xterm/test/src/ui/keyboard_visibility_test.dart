import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/ui.dart';

void main() {
  testWidgets('a metrics change after removal is ignored', (tester) async {
    // Closing a terminal tab while the keyboard is hiding removes the widget
    // before the queued metrics notification is delivered. `View.of(context)`
    // throws on a defunct element, so the callback has to bail out first.
    final key = GlobalKey<KeyboardVisibilityState>();
    var hides = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardVisibility(
          key: key,
          onKeyboardHide: () => hides++,
          child: const SizedBox(),
        ),
      ),
    );

    final state = key.currentState!;

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(state.mounted, isFalse);
    expect(state.didChangeMetrics, returnsNormally);
    expect(hides, 0);
  });

  testWidgets('still reports show and hide while mounted', (tester) async {
    final key = GlobalKey<KeyboardVisibilityState>();
    var shows = 0;
    var hides = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardVisibility(
          key: key,
          onKeyboardShow: () => shows++,
          onKeyboardHide: () => hides++,
          child: const SizedBox(),
        ),
      ),
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    key.currentState!.didChangeMetrics();
    expect(shows, 1);

    tester.view.resetViewInsets();
    key.currentState!.didChangeMetrics();
    expect(hides, 1);
  });
}
