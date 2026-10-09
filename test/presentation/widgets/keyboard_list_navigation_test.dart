// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/shortcuts/app_shortcuts.dart';
import 'package:monkeyssh/presentation/widgets/keyboard_list_navigation.dart';

const _ringColor = Color(0xFF14756C);

class _ListHarness {
  _ListHarness(int count)
    : rows = List.generate(count, (i) => FocusNode(debugLabel: 'row $i')),
      closes = List.generate(count, (i) => FocusNode(debugLabel: 'close $i'));

  final List<FocusNode> rows;
  final List<FocusNode> closes;
  final taps = <int>[];
  final tapFlows = <bool>[];

  void dispose() {
    for (final node in [...rows, ...closes]) {
      node.dispose();
    }
  }

  Widget list({VoidCallback? onEscape, bool autofocus = true}) =>
      KeyboardListNavigation(
        autofocus: autofocus,
        onEscape: onEscape,
        child: ListView(
          children: [
            for (var i = 0; i < rows.length; i++)
              ListTile(
                focusNode: rows[i],
                title: Text('row $i'),
                trailing: IconButton(
                  focusNode: closes[i],
                  icon: const Icon(Icons.close),
                  onPressed: () {},
                ),
                onTap: () {
                  taps.add(i);
                  tapFlows.add(isHardwareKeyboardFlow);
                },
              ),
          ],
        ),
      );
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

Widget _app(Widget body) => MaterialApp(
  theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _ringColor))
      .copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: _ringColor)
            .copyWith(primary: _ringColor),
      ),
  home: Scaffold(body: body),
);

void main() {
  testWidgets('arrows move between rows and skip trailing buttons', (
    tester,
  ) async {
    final harness = _ListHarness(3);
    addTearDown(harness.dispose);
    await tester.pumpWidget(_app(harness.list()));
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.rows[0].hasPrimaryFocus, isTrue);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.rows[1].hasPrimaryFocus, isTrue);

    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(harness.closes[1].hasPrimaryFocus, isTrue);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.rows[2].hasPrimaryFocus, isTrue);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.rows[2].hasPrimaryFocus, isTrue, reason: 'stays at end');

    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(harness.rows[0].hasPrimaryFocus, isTrue, reason: 'stays at top');
  });

  testWidgets('walks a lazily built list past the first screen', (
    tester,
  ) async {
    final nodes = List.generate(60, (i) => FocusNode(debugLabel: 'lazy $i'));
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });
    await tester.pumpWidget(
      _app(
        KeyboardListNavigation(
          autofocus: true,
          child: ListView.builder(
            itemCount: nodes.length,
            itemBuilder: (context, i) => ListTile(
              focusNode: nodes[i],
              title: Text('lazy $i'),
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    for (var i = 0; i < 40; i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(nodes[39].hasPrimaryFocus, isTrue);
    expect(find.text('lazy 39'), findsOneWidget);
  });

  testWidgets('Up from the list itself starts at the last row', (tester) async {
    final harness = _ListHarness(3);
    addTearDown(harness.dispose);
    await tester.pumpWidget(_app(harness.list()));
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(harness.rows[2].hasPrimaryFocus, isTrue);
  });

  testWidgets('Return activates the row as a keyboard flow', (tester) async {
    final harness = _ListHarness(2);
    addTearDown(harness.dispose);
    await tester.pumpWidget(_app(harness.list()));
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.enter);

    expect(harness.taps, [1]);
    expect(harness.tapFlows, [isTrue]);
  });

  testWidgets('Esc runs onEscape', (tester) async {
    final harness = _ListHarness(2);
    addTearDown(harness.dispose);
    var escapes = 0;
    await tester.pumpWidget(_app(harness.list(onEscape: () => escapes++)));
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.escape);

    expect(escapes, 1);
  });

  testWidgets('Esc without onEscape leaves the row on a page', (tester) async {
    final harness = _ListHarness(2);
    addTearDown(harness.dispose);
    await tester.pumpWidget(_app(harness.list()));
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.rows[0].hasPrimaryFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.escape);

    expect(harness.rows[0].hasFocus, isFalse);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.rows[0].hasPrimaryFocus, isTrue);
  });

  testWidgets('Esc without onEscape dismisses an enclosing sheet', (
    tester,
  ) async {
    final harness = _ListHarness(2);
    addTearDown(harness.dispose);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => harness.list(autofocus: false),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.rows.any((node) => node.hasPrimaryFocus), isTrue);
    await _key(tester, LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('row 0'), findsNothing);
  });

  testWidgets('draws a focus ring only while the keyboard drives focus', (
    tester,
  ) async {
    final harness = _ListHarness(2);
    addTearDown(harness.dispose);
    await tester.pumpWidget(_app(harness.list()));
    await tester.pump();
    final navigation = find.byType(KeyboardListNavigation);
    final ring = paints
      ..rrect(color: _ringColor, style: PaintingStyle.stroke, strokeWidth: 2);

    expect(tester.renderObject(navigation), isNot(ring));

    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(tester.renderObject(navigation), ring);

    // A touch switches Flutter to touch highlights; the ring goes away.
    await tester.tap(find.text('row 1'));
    await tester.pump();
    expect(tester.renderObject(navigation), isNot(ring));
  });
}
