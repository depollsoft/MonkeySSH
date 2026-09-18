// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/presentation/widgets/cursor_block.dart';
import 'package:monkeyssh/presentation/widgets/message_of_the_day.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders a faux prompt with a cursor block', (tester) async {
    await tester.pumpWidget(wrap(const MessageOfTheDay()));

    expect(find.byType(CursorBlock), findsOneWidget);
    expect(find.textContaining(r'$'), findsWidgets);
  });

  testWidgets('shows a message from the curated pool', (tester) async {
    await tester.pumpWidget(wrap(MessageOfTheDay(date: DateTime(2026, 6, 15))));

    final widget = tester.widget<MessageOfTheDay>(find.byType(MessageOfTheDay));
    expect(MessageOfTheDay.messages, contains(widget.message));
  });

  test('selection is stable for a given calendar day', () {
    const widget = MessageOfTheDay();
    final morning = MessageOfTheDay(date: DateTime(2026, 3, 14, 8)).message;
    final evening = MessageOfTheDay(date: DateTime(2026, 3, 14, 21)).message;

    expect(morning, evening);
    // The default constructor resolves a real line without throwing.
    expect(MessageOfTheDay.messages, contains(widget.message));
  });

  test('selection rotates across days', () {
    final seen = <String>{
      for (var day = 0; day < MessageOfTheDay.messages.length; day++)
        MessageOfTheDay(date: DateTime(2026, 6, 15).add(Duration(days: day)))
            .message,
    };
    // Distinct days within one cycle should cover the whole pool.
    expect(seen.length, MessageOfTheDay.messages.length);
  });
}
