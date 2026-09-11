import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

void main() {
  Future<MonkeyRenderTerminal> pumpTerminal(
    WidgetTester tester,
    Terminal terminal,
    TerminalController controller, {
    required bool useSystemSelection,
    double width = 640,
    bool autoResize = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 240,
            child: MonkeyTerminalView(
              terminal,
              controller: controller,
              autoResize: autoResize,
              hardwareKeyboardOnly: true,
              useSystemSelection: useSystemSelection,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .renderTerminal;
  }

  void selectWord(MonkeyRenderTerminal render, CellOffset cell) {
    render.dispatchSelectionEvent(
      SelectWordSelectionEvent(
        globalPosition: render.localToGlobal(
          render.getOffset(cell) + render.cellSize.center(Offset.zero),
        ),
      ),
    );
  }

  for (final useSystemSelection in [true, false]) {
    for (final change in [
      'grid resize',
      'viewport resize',
      'scrollback eviction',
    ]) {
      testWidgets(
        '$change preserves selection, system selection: $useSystemSelection',
        (tester) async {
          final evict = change == 'scrollback eviction';
          final autoResize = change == 'viewport resize';
          final terminal = Terminal(maxLines: evict ? 32 : 100)
            ..resize(evict ? 40 : 80, evict ? 4 : 6)
            ..write(
              evict
                  ? List.generate(
                      32,
                      (index) => index == 26 ? 'selected' : 'row $index',
                    ).join('\r\n')
                  : 'first\r\nsecond\r\nshort selected text\r\nlast',
            );
          final controller = TerminalController();
          addTearDown(controller.dispose);
          final render = await pumpTerminal(
            tester,
            terminal,
            controller,
            useSystemSelection: useSystemSelection,
            autoResize: autoResize,
          );
          final initialWidth = terminal.viewWidth;
          selectWord(
            render,
            evict ? const CellOffset(3, 26) : const CellOffset(10, 2),
          );
          await tester.pump();
          expect(render.getSelectedContent()?.plainText, 'selected');
          if (evict) {
            expect(terminal.buffer.lines.length, 32);
            terminal.write('\r\nnewest');
          } else if (autoResize) {
            final resizedRender = await pumpTerminal(
              tester,
              terminal,
              controller,
              useSystemSelection: useSystemSelection,
              width: 320,
              autoResize: true,
            );
            expect(resizedRender, same(render));
            expect(terminal.viewWidth, lessThan(initialWidth));
          } else {
            expect(controller.selection!.begin, const CellOffset(6, 2));
            expect(controller.selection!.end, const CellOffset(14, 2));
            // Direct grid resizing needs an explicit view notification.
            terminal
              ..resize(40, 6)
              ..notifyListeners();
          }
          await tester.pumpAndSettle();
          if (evict) expect(terminal.buffer.lines.length, 32);
          expect(
            controller.selection!.begin,
            evict ? const CellOffset(0, 25) : const CellOffset(6, 2),
          );
          expect(
            controller.selection!.end,
            evict ? const CellOffset(8, 25) : const CellOffset(14, 2),
          );
          expect(render.getSelectedContent()?.plainText, 'selected');
          expect(terminal.buffer.getText(controller.selection), 'selected');
        },
      );
    }
  }
}
