// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _deleteDetectionMarker = '\u200B\u200B';

({String text, int cursorOffset}) terminalStateFromEvents(
  Iterable<String> events, {
  String initialText = '',
  int? initialCursorOffset,
}) {
  final visibleCharacters = initialText.characters.toList(growable: true);
  var cursorOffset = initialCursorOffset ?? visibleCharacters.length;
  for (final event in events) {
    var offset = 0;
    while (offset < event.length) {
      if (event.startsWith('\u001b[D', offset)) {
        if (cursorOffset > 0) {
          cursorOffset--;
        }
        offset += 3;
        continue;
      }
      if (event.startsWith('\u001b[C', offset)) {
        if (cursorOffset < visibleCharacters.length) {
          cursorOffset++;
        }
        offset += 3;
        continue;
      }

      final character = event.substring(offset).characters.first;
      offset += character.length;
      if (character == '\x7f') {
        if (cursorOffset > 0) {
          visibleCharacters.removeAt(cursorOffset - 1);
          cursorOffset--;
        }
        continue;
      }
      visibleCharacters.insert(cursorOffset, character);
      cursorOffset++;
    }
  }

  return (text: visibleCharacters.join(), cursorOffset: cursorOffset);
}

Future<void> commitSwipeText(WidgetTester tester, String text) async {
  final selection = TextSelection.collapsed(offset: text.length);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: selection,
      composing: TextRange(
        start: _deleteDetectionMarker.length,
        end: text.length,
      ),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    TextEditingValue(text: text, selection: selection),
  );
  await tester.pump();
}

String terminalTextFromEvents(Iterable<String> events) =>
    terminalStateFromEvents(events).text;
