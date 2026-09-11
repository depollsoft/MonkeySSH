import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart'
    as app_terminal_themes;
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

import '../test/helpers/terminal_session_fixture.dart';

String _selectedText(TextEditingController controller) =>
    controller.selection.textInside(controller.text);

void _expectTransparentOverlayDecoration(
  WidgetTester tester,
  Finder overlayField,
) {
  final inputDecorator = find.descendant(
    of: overlayField,
    matching: find.byType(InputDecorator),
  );
  expect(inputDecorator, findsOneWidget);

  final decoration = tester.widget<InputDecorator>(inputDecorator).decoration;
  expect(decoration.filled, isFalse);
  expect(decoration.fillColor, Colors.transparent);
  expect(decoration.hoverColor, Colors.transparent);
  expect(decoration.border, InputBorder.none);
  expect(decoration.enabledBorder, InputBorder.none);
  expect(decoration.disabledBorder, InputBorder.none);
  expect(decoration.focusedBorder, InputBorder.none);
  expect(decoration.errorBorder, InputBorder.none);
  expect(decoration.focusedErrorBorder, InputBorder.none);
}

void _expectOverlaySelectionTheme(WidgetTester tester, Finder overlayField) {
  final selectionTheme = find.ancestor(
    of: overlayField,
    matching: find.byType(TextSelectionTheme),
  );
  expect(selectionTheme, findsOneWidget);

  final data = tester.widget<TextSelectionTheme>(selectionTheme).data;
  expect(
    data.selectionColor,
    app_terminal_themes.TerminalThemes.defaultLightTheme.readableSelection,
  );
  expect(
    data.selectionHandleColor,
    app_terminal_themes.TerminalThemes.defaultLightTheme.cursor,
  );
}

TextEditingController _expectOverlayWordSelection(
  WidgetTester tester,
  Finder overlayField,
  String expectedWord, {
  bool expectedFocus = true,
}) {
  final controller = tester.widget<TextField>(overlayField).controller;
  expect(controller, isNotNull);
  expect(controller!.selection.isCollapsed, isFalse);
  expect(_selectedText(controller), expectedWord);

  final editableText = find.descendant(
    of: overlayField,
    matching: find.byType(EditableText),
  );
  expect(editableText, findsOneWidget);
  expect(
    tester.widget<EditableText>(editableText).focusNode.hasFocus,
    expectedFocus,
  );
  _expectTransparentOverlayDecoration(tester, overlayField);
  _expectOverlaySelectionTheme(tester, overlayField);

  return controller;
}

Offset? _visibleTokenCenter(
  WidgetTester tester,
  Terminal terminal,
  String token,
) {
  final terminalViewState = tester.state<MonkeyTerminalViewState>(
    find.byType(MonkeyTerminalView),
  );
  final renderTerminal = terminalViewState.renderTerminal;
  final firstVisibleRow = (terminal.buffer.lines.length - terminal.viewHeight)
      .clamp(0, terminal.buffer.lines.length - 1);

  for (
    var row = firstVisibleRow;
    row < terminal.buffer.lines.length;
    row += 1
  ) {
    final lineText = trimTerminalLinePadding(
      terminal.buffer.lines[row].getText(0, terminal.buffer.viewWidth),
    );
    final startColumn = lineText.indexOf(token);
    if (startColumn == -1) {
      continue;
    }

    final tapColumn = startColumn + (token.length ~/ 2);
    final cellOffset = CellOffset(tapColumn, row);
    return renderTerminal.localToGlobal(
      renderTerminal.getOffset(cellOffset) +
          renderTerminal.cellSize.center(Offset.zero),
    );
  }

  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const SSHPtyConfig());
    registerFallbackValue(Uint8List(0));
  });

  testWidgets(
    'long press refreshes the native overlay from live terminal output',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 1, connectionId: 7);
      final session = fixture.session;

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      Offset cellCenter(CellOffset offset) {
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        return renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
      }

      session.terminal!.write('alpha');
      await tester.pumpAndSettle();

      await tester.longPressAt(cellCenter(const CellOffset(2, 0)));
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      final terminalView = tester.widget<MonkeyTerminalView>(
        find.byType(MonkeyTerminalView),
      );
      expect(terminalView.controller, isNotNull);
      expect(terminalView.controller!.selection, isNull);
      var overlayController = _expectOverlayWordSelection(
        tester,
        overlayField,
        'alpha',
      );
      expect(overlayController.text, contains('alpha'));

      session.terminal!.write('\r\ncharlie');
      await tester.pumpAndSettle();
      expect(overlayController.text, isNot(contains('charlie')));

      await tester.longPressAt(cellCenter(const CellOffset(2, 1)));
      await tester.pumpAndSettle();

      expect(terminalView.controller!.selection, isNull);
      overlayController = _expectOverlayWordSelection(
        tester,
        overlayField,
        'charlie',
      );
      expect(overlayController.text, contains('charlie'));
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );

  testWidgets(
    'long press inside the active overlay keeps the current native selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 10, connectionId: 14);
      final session = fixture.session;

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      Offset cellCenter(CellOffset offset) {
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        return renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
      }

      session.terminal!.write('alpha');
      await tester.pumpAndSettle();

      final selectionOffset = cellCenter(const CellOffset(2, 0));
      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      var overlayController = _expectOverlayWordSelection(
        tester,
        overlayField,
        'alpha',
      );
      expect(overlayController.text, contains('alpha'));

      session.terminal!.write('\r\ncharlie');
      await tester.pumpAndSettle();
      expect(overlayController.text, isNot(contains('charlie')));

      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      overlayController = _expectOverlayWordSelection(
        tester,
        overlayField,
        'alpha',
      );
      expect(overlayController.text, isNot(contains('charlie')));
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );

  testWidgets(
    'dismissing a selection still allows the next long press to select text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 2, connectionId: 8);
      final session = fixture.session;

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      Offset cellCenter(CellOffset offset) {
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        return renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
      }

      session.terminal!.write('alpha bravo');
      await tester.pumpAndSettle();

      final selectionOffset = cellCenter(const CellOffset(2, 0));
      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      _expectOverlayWordSelection(tester, overlayField, 'alpha');

      await tester.tapAt(cellCenter(const CellOffset(2, 2)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      _expectOverlayWordSelection(tester, overlayField, 'alpha');
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );

  testWidgets(
    'immediately retrying after tap dismissal still selects on the first long press',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 3, connectionId: 9);
      final session = fixture.session;

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      Offset cellCenter(CellOffset offset) {
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        return renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
      }

      session.terminal!.write('alpha bravo');
      await tester.pumpAndSettle();

      final selectionOffset = cellCenter(const CellOffset(2, 0));
      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      _expectOverlayWordSelection(tester, overlayField, 'alpha');

      await tester.tapAt(cellCenter(const CellOffset(2, 2)));
      await tester.pump(const Duration(milliseconds: 16));

      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      _expectOverlayWordSelection(tester, overlayField, 'alpha');
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );

  testWidgets(
    'streaming output does not block the first retry after tap dismissal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 4, connectionId: 10);
      final session = fixture.session;

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      Offset cellCenter(CellOffset offset) {
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        return renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
      }

      session.terminal!.write('alpha bravo\r\nprocessing |');
      await tester.pumpAndSettle();

      final selectionOffset = cellCenter(const CellOffset(2, 0));
      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      _expectOverlayWordSelection(tester, overlayField, 'alpha');

      final spinnerFrames = <String>['|', '/', '-', String.fromCharCode(92)];
      var spinnerIndex = 0;
      final spinnerTimer = Timer.periodic(const Duration(milliseconds: 50), (
        _,
      ) {
        session.terminal!.write('\rprocessing ${spinnerFrames[spinnerIndex]}');
        spinnerIndex = (spinnerIndex + 1) % spinnerFrames.length;
      });
      addTearDown(spinnerTimer.cancel);

      await tester.tapAt(cellCenter(const CellOffset(2, 2)));
      await tester.pump(const Duration(milliseconds: 16));

      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      spinnerTimer.cancel();

      _expectOverlayWordSelection(tester, overlayField, 'alpha');
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );

  testWidgets(
    'touch-scroll mode keeps the touched word selected while output streams during the long press',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 15, connectionId: 16);
      final session = fixture.session;
      session.terminal!
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      final initialLines = List<String>.generate(
        28,
        (index) => index == 27 ? 'alpha bravo' : 'line $index',
      ).join('\r\n');
      session.terminal!.write(initialLines);
      await tester.pumpAndSettle();

      final selectionOffset = _visibleTokenCenter(
        tester,
        session.terminal!,
        'alpha',
      );
      expect(selectionOffset, isNotNull);

      var streamIndex = 0;
      final streamTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        session.terminal!.write('\r\nstream $streamIndex');
        streamIndex += 1;
      });
      addTearDown(streamTimer.cancel);

      final gesture = await tester.startGesture(selectionOffset!);
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      streamTimer.cancel();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      _expectOverlayWordSelection(tester, overlayField, 'alpha');
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );

  testWidgets(
    'touch-scroll mode long press shows a visible native selection overlay',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 5, connectionId: 11);
      final session = fixture.session;
      session.terminal!
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      Offset cellCenter(CellOffset offset) {
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        return renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
      }

      session.terminal!.write('alpha bravo');
      await tester.pumpAndSettle();

      final selectionOffset = cellCenter(const CellOffset(2, 0));
      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      _expectOverlayWordSelection(tester, overlayField, 'alpha');
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );

  testWidgets(
    'touch-scroll mode dismissal still allows the next long press to select text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 6, connectionId: 12);
      final session = fixture.session;
      session.terminal!
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);

      await fixture.pump(tester);

      await tester.pump();
      await tester.pump();

      Offset cellCenter(CellOffset offset) {
        final terminalViewState = tester.state<MonkeyTerminalViewState>(
          find.byType(MonkeyTerminalView),
        );
        final renderTerminal = terminalViewState.renderTerminal;
        return renderTerminal.localToGlobal(
          renderTerminal.getOffset(offset) +
              renderTerminal.cellSize.center(Offset.zero),
        );
      }

      session.terminal!.write('alpha bravo\r\nprocessing |');
      await tester.pumpAndSettle();

      final selectionOffset = cellCenter(const CellOffset(2, 0));
      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      _expectOverlayWordSelection(tester, overlayField, 'alpha');

      final spinnerFrames = <String>['|', '/', '-', String.fromCharCode(92)];
      var spinnerIndex = 0;
      final spinnerTimer = Timer.periodic(const Duration(milliseconds: 50), (
        _,
      ) {
        session.terminal!.write('\rprocessing ${spinnerFrames[spinnerIndex]}');
        spinnerIndex = (spinnerIndex + 1) % spinnerFrames.length;
      });
      addTearDown(spinnerTimer.cancel);

      await tester.tapAt(cellCenter(const CellOffset(2, 2)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final dismissedController = tester
          .widget<TextField>(overlayField)
          .controller;
      expect(dismissedController, isNotNull);
      expect(dismissedController!.selection.isCollapsed, isTrue);

      await tester.longPressAt(selectionOffset);
      await tester.pumpAndSettle();

      spinnerTimer.cancel();

      expect(overlayField, findsOneWidget);
      _expectOverlayWordSelection(tester, overlayField, 'alpha');
    },
    skip:
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS,
  );
}
