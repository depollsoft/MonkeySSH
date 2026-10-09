import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:monkeyssh/presentation/widgets/terminal_scrollback_search.dart';
import 'package:monkeyssh/presentation/widgets/terminal_scrollback_search_bar.dart';
import 'package:xterm/xterm.dart';

const _field = ValueKey<String>('terminal-search-field');
const _status = ValueKey<String>('terminal-search-status');

String? _statusText(WidgetTester tester) {
  final finder = find.byKey(_status);
  return finder.evaluate().isEmpty ? null : tester.widget<Text>(finder).data;
}

Future<void> _settle(WidgetTester tester) async {
  // Debounce, slices and the result each take a turn of the event loop.
  for (var turn = 0; turn < 10; turn++) {
    await tester.pump(Duration.zero);
  }
}

TerminalScrollbackSearchController _controller(Terminal terminal) =>
    TerminalScrollbackSearchController(
      terminal: terminal,
      typingDebounce: Duration.zero,
    );

void main() {
  group('TerminalScrollbackSearchBar', () {
    late Terminal terminal;
    late TerminalScrollbackSearchController search;
    late List<int> revealed;
    late int closes;

    setUp(() {
      terminal = Terminal()
        ..resize(30, 6)
        ..write('alpha one\r\nbeta\r\nAlpha two\r\nalpha three');
      search = _controller(terminal);
      revealed = <int>[];
      closes = 0;
    });

    tearDown(() => search.dispose());

    Future<void> pumpBar(WidgetTester tester, {ThemeData? theme}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? FluttyTheme.dark,
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox.expand()),
                TerminalScrollbackSearchBar(
                  controller: search,
                  onClose: () => closes++,
                  onRevealRow: revealed.add,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('counts matches and steps with buttons and keys', (
      tester,
    ) async {
      await pumpBar(tester);
      expect(_statusText(tester), isNull);
      expect(find.text('Find in scrollback'), findsOneWidget);

      await tester.enterText(find.byKey(_field), 'alpha');
      await _settle(tester);
      expect(_statusText(tester), '3/3');
      expect(revealed, [3]);

      await tester.tap(find.byTooltip('Previous match'));
      await tester.pump();
      expect(_statusText(tester), '2/3');
      await tester.tap(find.byTooltip('Next match'));
      await tester.pump();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pump();
      expect(_statusText(tester), '1/3');
      expect(revealed, [3, 2, 3, 0]);

      // Enter steps up (older), Shift+Enter steps down (newer).
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(_statusText(tester), '3/3');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(_statusText(tester), '1/3');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closes, 1);
      await tester.tap(find.byTooltip('Close find'));
      expect(closes, 2);
    });

    testWidgets('disables stepping without matches and says so', (
      tester,
    ) async {
      await pumpBar(tester);
      await tester.enterText(find.byKey(_field), 'gamma');
      await _settle(tester);

      expect(_statusText(tester), '0');
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey<String>('terminal-search-next')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.getSemantics(find.byKey(_status)),
        matchesSemantics(label: 'No matches', isLiveRegion: true),
      );
    });

    testWidgets('the options menu toggles match case and shows a badge', (
      tester,
    ) async {
      await pumpBar(tester);
      await tester.enterText(find.byKey(_field), 'alpha');
      await _settle(tester);
      expect(_statusText(tester), '3/3');

      await tester.tap(find.byTooltip('Search options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Match case'));
      await tester.pumpAndSettle();
      await _settle(tester);

      expect(search.caseSensitive, isTrue);
      expect(find.text('Aa'), findsOneWidget);
      expect(_statusText(tester), '2/2');
    });

    testWidgets('reports an invalid regular expression in text', (
      tester,
    ) async {
      await pumpBar(tester);
      search
        ..setRegex(value: true)
        ..setQuery('(');
      await _settle(tester);

      expect(find.text('.*'), findsOneWidget);
      expect(_statusText(tester), 'invalid');
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });

    testWidgets('says when only the alternate screen is searched', (
      tester,
    ) async {
      terminal.write('\x1b[?1049h\x1b[Halpha on screen');
      await pumpBar(tester);
      await tester.enterText(find.byKey(_field), 'alpha');
      await _settle(tester);

      expect(find.text('Find on screen'), findsOneWidget);
      expect(_statusText(tester), '1/1');
    });

    for (final (name, theme) in [
      ('dark', FluttyTheme.dark),
      ('light', FluttyTheme.light),
    ]) {
      testWidgets('meets tap target and contrast guidelines ($name)', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pumpBar(tester, theme: theme);
        await tester.enterText(find.byKey(_field), 'alpha');
        await _settle(tester);

        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        semantics.dispose();
      });
    }
  });

  group('MonkeyTerminalView search hits', () {
    testWidgets('paint and repaint when the search changes', (tester) async {
      final terminal = Terminal()
        ..resize(40, 6)
        ..write('needle one\r\nhay\r\nneedle two');
      final search = _controller(terminal);
      addTearDown(search.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 200,
              child: MonkeyTerminalView(
                terminal,
                autoResize: false,
                hardwareKeyboardOnly: true,
                searchHits: search,
              ),
            ),
          ),
        ),
      );
      search.setQuery('needle');
      await _settle(tester);
      expect(search.matchCount, 2);

      final render = tester
          .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
          .renderTerminal;
      final paints = render.paintCount;
      search.showPrevious();
      await tester.pump();
      expect(render.paintCount, greaterThan(paints));
      expect(tester.takeException(), isNull);
    });
  });

  group('TerminalScrollbackSearchOverlay', () {
    testWidgets('scrolls the terminal to an off-screen match', (tester) async {
      final terminal = Terminal()..resize(40, 10);
      for (var row = 0; row < 200; row++) {
        terminal.write(row == 4 ? 'needle\r\n' : 'line $row\r\n');
      }
      final search = _controller(terminal);
      addTearDown(search.dispose);
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final viewKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          theme: FluttyTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: TerminalScrollbackSearchOverlay(
                search: search,
                scrollController: scrollController,
                lineHeight: () =>
                    viewKey.currentState?.renderTerminal.lineHeight ?? 0,
                onClose: () {},
                child: MonkeyTerminalView(
                  terminal,
                  key: viewKey,
                  scrollController: scrollController,
                  autoResize: false,
                  hardwareKeyboardOnly: true,
                  searchHits: search,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final bottom = scrollController.position.maxScrollExtent;
      expect(scrollController.offset, bottom);

      await tester.enterText(find.byKey(_field), 'needle');
      await _settle(tester);
      await tester.pumpAndSettle();

      final lineHeight = viewKey.currentState!.renderTerminal.lineHeight;
      expect(search.currentMatchRow, 4);
      expect(scrollController.offset, lessThanOrEqualTo(4 * lineHeight));
      expect(scrollController.offset, lessThan(bottom));
    });

    testWidgets('shows only the child without a search', (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalScrollbackSearchOverlay(
            search: null,
            scrollController: scrollController,
            lineHeight: () => 10,
            onClose: () {},
            child: const Text('terminal'),
          ),
        ),
      );
      expect(find.text('terminal'), findsOneWidget);
      expect(find.byType(TerminalScrollbackSearchBar), findsNothing);
    });
  });
}
