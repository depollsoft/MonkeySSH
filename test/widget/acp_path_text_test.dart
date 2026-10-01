// ignore_for_file: public_member_api_docs

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/acp_path_text.dart';

import '../helpers/tap_selectable_text.dart';

Widget wrap(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: child),
    );

List<TextSpan> spansOf(WidgetTester tester) => tester
    .widget<SelectableText>(find.byType(SelectableText))
    .textSpan!
    .children!
    .cast<TextSpan>();

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('underlines paths and preserves literal text in $brightness', (
      tester,
    ) async {
      final opened = <String>[];
      const text = 'result:\n  /tmp/output.log:42\n  lib/main.dart';
      await tester.pumpWidget(
        wrap(
          AcpPathText(text: text, onTapPath: opened.add),
          brightness: brightness,
        ),
      );
      final spans = spansOf(tester);
      final links = spans.where((span) => span.recognizer != null).toList();
      expect(links.map((span) => span.text), [
        '/tmp/output.log',
        'lib/main.dart',
      ]);
      expect(spans.map((span) => span.text).join(), text);
      final scheme = Theme.of(tester.element(find.byType(AcpPathText)))
          .colorScheme;
      for (final link in links) {
        expect(
          link.style?.decoration?.contains(TextDecoration.underline),
          isTrue,
        );
        expect(link.style?.color, scheme.primary);
        expect(link.style?.decorationColor, scheme.primary);
      }
      await tapSelectableSubstring(tester, '/tmp/output.log');
      await tester.pump();
      await tapSelectableSubstring(tester, 'lib/main.dart');
      await tester.pump();
      expect(opened, ['/tmp/output.log', 'lib/main.dart']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('links a path split across syntax tokens without losing styles', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      wrap(
        AcpPathText(
          text: 'open lib/main.dart now',
          style: const TextStyle(fontFamily: 'monospace'),
          spans: const [
            TextSpan(
              text: 'open ',
              style: TextStyle(color: Colors.green),
            ),
            TextSpan(
              style: TextStyle(fontWeight: FontWeight.bold),
              children: [
                TextSpan(text: 'lib/'),
                TextSpan(text: 'main.'),
              ],
            ),
            TextSpan(
              text: 'dart now',
              style: TextStyle(color: Colors.orange),
            ),
          ],
          onTapPath: (path) => opened = path,
        ),
      ),
    );
    final spans = spansOf(tester);
    final links = spans.where((span) => span.recognizer != null).toList();
    expect(links.map((span) => span.text).join(), 'lib/main.dart');
    expect(links.map((span) => span.recognizer).toSet(), hasLength(1));
    expect(links.first.style?.fontWeight, FontWeight.bold);
    expect(links.first.style?.fontFamily, 'monospace');
    expect(spans.first.style?.color, Colors.green);
    expect(spans.last.style?.color, Colors.orange);
    await tapSelectableSubstring(tester, 'lib/main.dart');
    await tester.pump();
    expect(opened, 'lib/main.dart');
  });

  testWidgets('refreshes streaming text and handler without stale targets', (
    tester,
  ) async {
    final oldOpened = <String>[];
    final newOpened = <String>[];
    await tester.pumpWidget(
      wrap(AcpPathText(text: '/tmp/old.log', onTapPath: oldOpened.add)),
    );
    await tapSelectableSubstring(tester, '/tmp/old.log');
    await tester.pump();
    await tester.pumpWidget(
      wrap(AcpPathText(text: '/tmp/new.log', onTapPath: newOpened.add)),
    );
    await tapSelectableSubstring(tester, '/tmp/new.log');
    await tester.pump();
    await tester.pumpWidget(
      wrap(AcpPathText(text: '/tmp/new.log', onTapPath: oldOpened.add)),
    );
    await tapSelectableSubstring(tester, '/tmp/new.log');
    await tester.pump();
    expect(oldOpened, ['/tmp/old.log', '/tmp/new.log']);
    expect(newOpened, ['/tmp/new.log']);
    await tester.pumpWidget(wrap(const SizedBox()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a handler paths remain undecorated and selectable', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const AcpPathText(text: '/tmp/output.log')));
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.data, '/tmp/output.log');
    expect(text.style?.decoration, isNull);
  });

  testWidgets('disabling path actions removes recognizers and underlines', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(AcpPathText(text: '/tmp/output.log', onTapPath: (_) {})),
    );
    expect(spansOf(tester).single.recognizer, isA<TapGestureRecognizer>());
    await tester.pumpWidget(wrap(const AcpPathText(text: '/tmp/output.log')));
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      '/tmp/output.log',
    );
    expect(tester.takeException(), isNull);
  });
}
