import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Taps the first occurrence of [substring] within selectable text.
Future<void> tapSelectableSubstring(
  WidgetTester tester,
  String substring,
) async {
  final finder = find
      .byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? widget.textSpan!.toPlainText()).contains(substring),
      )
      .first;
  final widget = tester.widget<SelectableText>(finder);
  final text = widget.data ?? widget.textSpan!.toPlainText();
  final start = text.indexOf(substring);
  final editable = tester
      .state<EditableTextState>(
        find.descendant(of: finder, matching: find.byType(EditableText)),
      )
      .renderEditable;
  final boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + substring.length),
  );
  await tester.tapAt(editable.localToGlobal(boxes.first.toRect().center));
}
