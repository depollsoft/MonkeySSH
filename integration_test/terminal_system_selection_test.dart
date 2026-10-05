import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _selectionPaintColor = Color(0xFFFF00FF);
const _testTerminalTheme = TerminalTheme(
  cursor: Color(0xFFFFFFFF),
  selection: _selectionPaintColor,
  foreground: Color(0xFFFFFFFF),
  background: Color(0xFF000000),
  black: Color(0xFF000000),
  red: Color(0xFFFF0000),
  green: Color(0xFF00FF00),
  yellow: Color(0xFFFFFF00),
  blue: Color(0xFF0000FF),
  magenta: Color(0xFFFF00FF),
  cyan: Color(0xFF00FFFF),
  white: Color(0xFFFFFFFF),
  brightBlack: Color(0xFF808080),
  brightRed: Color(0xFFFF8080),
  brightGreen: Color(0xFF80FF80),
  brightYellow: Color(0xFFFFFF80),
  brightBlue: Color(0xFF8080FF),
  brightMagenta: Color(0xFFFF80FF),
  brightCyan: Color(0xFF80FFFF),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFFF00),
  searchHitBackgroundCurrent: Color(0xFFFFA000),
  searchHitForeground: Color(0xFF000000),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  String rowLabel(int row) => 'row ${row.toString().padLeft(2, '0')}';

  Future<double> waitForKeyboardInset(
    WidgetTester tester, {
    required bool visible,
  }) async {
    for (var attempt = 0; attempt < 30; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      final bottomInset = tester.view.viewInsets.bottom;
      if (visible ? bottomInset > 0 : bottomInset == 0) {
        return bottomInset;
      }
    }
    return tester.view.viewInsets.bottom;
  }

  Future<int> countSelectionPaintPixels(
    RenderRepaintBoundary repaintBoundary,
  ) async {
    final image = await repaintBoundary.toImage();
    final byteData = await image.toByteData();
    expect(byteData, isNotNull);
    final bytes = byteData!.buffer.asUint8List();
    var pixels = 0;
    for (var index = 0; index < bytes.length; index += 4) {
      final red = bytes[index];
      final green = bytes[index + 1];
      final blue = bytes[index + 2];
      final alpha = bytes[index + 3];
      if (red > 240 && green < 20 && blue > 240 && alpha > 240) {
        pixels += 1;
      }
    }
    image.dispose();
    return pixels;
  }

  testWidgets('terminal render object supports system selection on device', (
    tester,
  ) async {
    final terminal = Terminal();
    final controller = TerminalController();
    final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();
    final selectionChanges = <SelectedContent?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: MonkeyTerminalView(
              terminal,
              key: terminalViewKey,
              controller: controller,
              readOnly: true,
              useSystemSelection: true,
              onSystemSelectionChanged: selectionChanges.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    terminal.write('selectable alpha   beta gamma');
    await tester.pumpAndSettle();

    final renderTerminal = terminalViewKey.currentState!.renderTerminal;
    Offset cellCenter(CellOffset offset) => renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

    await tester.longPressAt(cellCenter(const CellOffset(13, 0)));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(controller.selection, isNotNull);
    expect(renderTerminal.getSelectedContent()?.plainText, 'alpha');
    expect(selectionChanges, isNotEmpty);
    expect(selectionChanges.last?.plainText, 'alpha');

    controller.setSelection(
      terminal.buffer.createAnchorFromOffset(const CellOffset(11, 0)),
      terminal.buffer.createAnchorFromOffset(const CellOffset(19, 0)),
      mode: SelectionMode.line,
    );
    await tester.pumpAndSettle();

    expect(renderTerminal.getSelectedContent()?.plainText, 'alpha');
  });

  Future<
    ({
      Terminal terminal,
      TerminalController controller,
      GlobalKey<MonkeyTerminalViewState> terminalViewKey,
      GlobalKey repaintBoundaryKey,
      FocusNode focusNode,
      TerminalTextInputHandlerController inputController,
    })
  >
  pumpKeyboardSelectionHarness(WidgetTester tester) async {
    final terminal = Terminal(maxLines: 120);
    final controller = TerminalController();
    final terminalViewKey = GlobalKey<MonkeyTerminalViewState>();
    final repaintBoundaryKey = GlobalKey();
    final focusNode = FocusNode();
    final inputController = TerminalTextInputHandlerController();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: TerminalTextInputHandler(
                  terminal: terminal,
                  focusNode: focusNode,
                  controller: inputController,
                  showKeyboardOnFocus: false,
                  child: Focus(
                    focusNode: focusNode,
                    child: RepaintBoundary(
                      key: repaintBoundaryKey,
                      child: MonkeyTerminalView(
                        terminal,
                        key: terminalViewKey,
                        controller: controller,
                        hardwareKeyboardOnly: true,
                        theme: _testTerminalTheme,
                        useSystemSelection: true,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pumpAndSettle();

    for (var row = 0; row < 80; row += 1) {
      terminal.write('${rowLabel(row)}\r\n');
    }
    await tester.pumpAndSettle();

    return (
      terminal: terminal,
      controller: controller,
      terminalViewKey: terminalViewKey,
      repaintBoundaryKey: repaintBoundaryKey,
      focusNode: focusNode,
      inputController: inputController,
    );
  }

  Future<void> dragStartHandleToRow(
    WidgetTester tester,
    MonkeyRenderTerminal renderTerminal, {
    required int targetRow,
  }) async {
    final startSelectionPoint = renderTerminal.value.startSelectionPoint!;
    final startHandlePosition = renderTerminal.localToGlobal(
      startSelectionPoint.localPosition,
    );
    final handleDragPosition =
        startHandlePosition + Offset(0, renderTerminal.cellSize.height);

    Offset cellCenter(CellOffset offset) => renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

    await tester.timedDragFrom(
      handleDragPosition,
      cellCenter(CellOffset(0, targetRow)) - handleDragPosition,
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dragEndHandleToRow(
    WidgetTester tester,
    MonkeyRenderTerminal renderTerminal, {
    required int targetRow,
  }) async {
    final endSelectionPoint = renderTerminal.value.endSelectionPoint!;
    final endHandlePosition = renderTerminal.localToGlobal(
      endSelectionPoint.localPosition,
    );
    final handleDragPosition =
        endHandlePosition + Offset(0, renderTerminal.cellSize.height);

    Offset cellCenter(CellOffset offset) => renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

    await tester.timedDragFrom(
      handleDragPosition,
      cellCenter(CellOffset(0, targetRow)) - handleDragPosition,
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('terminal system selection is visible with soft keyboard open', (
    tester,
  ) async {
    final harness = await pumpKeyboardSelectionHarness(tester);
    final renderTerminal = harness.terminalViewKey.currentState!.renderTerminal;

    Offset cellCenter(CellOffset offset) => renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

    harness.inputController.requestKeyboard();
    final shownKeyboardInset = await waitForKeyboardInset(
      tester,
      visible: true,
    );
    expect(shownKeyboardInset, greaterThan(0));
    await tester.pumpAndSettle();

    final topVisibleRow = renderTerminal.getCellOffset(Offset.zero).y;
    final selectedRow = topVisibleRow + 20;
    final targetRow = topVisibleRow + 1;

    await tester.longPressAt(cellCenter(CellOffset(5, selectedRow)));
    await tester.pumpAndSettle();
    expect(harness.controller.selection, isNotNull);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(tester.view.viewInsets.bottom, greaterThan(0));

    await dragStartHandleToRow(tester, renderTerminal, targetRow: targetRow);

    final selectedText = renderTerminal.getSelectedContent()!.plainText;
    expect(selectedText, contains(rowLabel(targetRow)));
    expect(selectedText, contains(rowLabel(selectedRow)));
    final repaintBoundary =
        harness.repaintBoundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    expect(await countSelectionPaintPixels(repaintBoundary), greaterThan(100));
  });

  testWidgets('terminal system selection can start from whitespace', (
    tester,
  ) async {
    final harness = await pumpKeyboardSelectionHarness(tester);
    final renderTerminal = harness.terminalViewKey.currentState!.renderTerminal;

    Offset cellCenter(CellOffset offset) => renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

    harness.inputController.requestKeyboard();
    final shownKeyboardInset = await waitForKeyboardInset(
      tester,
      visible: true,
    );
    expect(shownKeyboardInset, greaterThan(0));
    await tester.pumpAndSettle();

    final topVisibleRow = renderTerminal.getCellOffset(Offset.zero).y;
    final selectedRow = topVisibleRow + 20;
    final targetRow = topVisibleRow + 1;
    final selectedRowText = rowLabel(selectedRow);
    final whitespaceColumn = selectedRowText.length + 4;
    expect(
      harness.terminal.buffer.getWordBoundary(
        CellOffset(whitespaceColumn, selectedRow),
      ),
      isNull,
    );

    final gesture = await tester.startGesture(
      cellCenter(CellOffset(whitespaceColumn, selectedRow)),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(cellCenter(CellOffset(0, selectedRow)));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.controller.selection, isNotNull);
    expect(renderTerminal.getSelectedContent()?.plainText, selectedRowText);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(tester.view.viewInsets.bottom, greaterThan(0));

    await dragEndHandleToRow(tester, renderTerminal, targetRow: targetRow);

    final selectedText = renderTerminal.getSelectedContent()!.plainText;
    expect(selectedText, contains(rowLabel(targetRow)));
    expect(selectedText, contains(rowLabel(selectedRow)));
  });

  testWidgets('terminal system selection survives soft keyboard resize', (
    tester,
  ) async {
    final harness = await pumpKeyboardSelectionHarness(tester);
    final renderTerminal = harness.terminalViewKey.currentState!.renderTerminal;

    Offset cellCenter(CellOffset offset) => renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

    harness.inputController.requestKeyboard();
    final shownKeyboardInset = await waitForKeyboardInset(
      tester,
      visible: true,
    );
    expect(shownKeyboardInset, greaterThan(0));
    harness.focusNode.unfocus();
    final hiddenKeyboardInset = await waitForKeyboardInset(
      tester,
      visible: false,
    );
    expect(hiddenKeyboardInset, 0);
    await tester.pumpAndSettle();

    final topVisibleRow = renderTerminal.getCellOffset(Offset.zero).y;
    final selectedRow = topVisibleRow + 35;
    final targetRow = topVisibleRow + 1;

    await tester.longPressAt(cellCenter(CellOffset(5, selectedRow)));
    await tester.pumpAndSettle();
    expect(harness.controller.selection, isNotNull);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    await dragStartHandleToRow(tester, renderTerminal, targetRow: targetRow);

    final selectedText = renderTerminal.getSelectedContent()!.plainText;
    expect(selectedText, contains(rowLabel(targetRow)));
    expect(selectedText, contains(rowLabel(selectedRow)));
    final repaintBoundary =
        harness.repaintBoundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    expect(await countSelectionPaintPixels(repaintBoundary), greaterThan(100));
  });
}
