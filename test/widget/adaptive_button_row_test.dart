// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/adaptive_button_row.dart';

Future<void> _pump(WidgetTester tester, double width) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: AdaptiveButtonRow(
            children: [
              OutlinedButton(onPressed: () {}, child: const Text('Copy Key')),
              OutlinedButton(
                onPressed: () {},
                child: const Text('Copy Command'),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('sits side by side at equal size when the labels fit', (
    tester,
  ) async {
    await _pump(tester, 700);

    final first = tester.getRect(find.byType(OutlinedButton).first);
    final second = tester.getRect(find.byType(OutlinedButton).last);
    expect(first.top, second.top);
    expect(first.width, second.width);
    expect(first.height, second.height);
    expect(second.right, 700);
  });

  testWidgets('stacks at full width rather than wrapping a label', (
    tester,
  ) async {
    // The test font draws every glyph 1em wide, so "Copy Command" can't fit
    // in half of 300.
    await _pump(tester, 300);

    final first = tester.getRect(find.byType(OutlinedButton).first);
    final second = tester.getRect(find.byType(OutlinedButton).last);
    expect(first.width, 300);
    expect(second.width, 300);
    expect(second.top, greaterThan(first.bottom));
    for (final label in ['Copy Key', 'Copy Command']) {
      final text = tester.renderObject<RenderParagraph>(find.text(label));
      expect(text.didExceedMaxLines, isFalse);
      expect(tester.getSize(find.text(label)).height, lessThan(30));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a button in the row still takes taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveButtonRow(
            children: [
              OutlinedButton(onPressed: () => taps++, child: const Text('A')),
              OutlinedButton(onPressed: () {}, child: const Text('B')),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('A'));
    expect(taps, 1);
  });
}
