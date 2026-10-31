import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

const _prompt = '\x1b]133;A;cl=line\x07\$ \x1b]133;B\x07';

void main() {
  late List<String> output;
  late Terminal terminal;
  late TerminalController controller;
  late List<String> events;
  final viewKey = GlobalKey<MonkeyTerminalViewState>();

  setUp(() {
    output = <String>[];
    events = <String>[];
    terminal = Terminal(
      onOutput: (data) {
        output.add(data);
        events.add('output');
      },
    );
    controller = TerminalController();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpView(
    WidgetTester tester, {
    bool useSystemSelection = false,
    ScrollController? scrollController,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 200,
          child: MonkeyTerminalView(
            key: viewKey,
            terminal,
            controller: controller,
            scrollController: scrollController,
            useSystemSelection: useSystemSelection,
            hardwareKeyboardOnly: true,
            onUserInput: () => events.add('input'),
            onPromptCursorMove: () => events.add('cursor moved'),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Offset cellCenter(int x, int y) {
    final render = viewKey.currentState!.renderTerminal;
    return render.localToGlobal(
      render.getOffset(CellOffset(x, y)) + render.cellSize.center(Offset.zero),
    );
  }

  Future<void> click(WidgetTester tester, Offset position) async {
    await tester.tapAt(position, kind: PointerDeviceKind.mouse);
    // Outlast the double-click window so the next click is a single one.
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a click on the prompt input moves the shell cursor there', (
    tester,
  ) async {
    terminal.write('${_prompt}echo hi');
    await pumpView(tester);

    await click(tester, cellCenter(2, terminal.buffer.absoluteCursorY));
    expect(output.join(), '\x1b[D' * 7);
    // The move is user input, so a paste or upload still pending sees it, and
    // an input method learns that the text before the cursor changed.
    expect(events, ['input', 'output', 'cursor moved']);
  });

  testWidgets('a click outside the prompt input sends nothing', (tester) async {
    terminal.write('out\r\n${_prompt}ls');
    await pumpView(tester);

    await click(tester, cellCenter(1, 0));
    await click(tester, cellCenter(0, 1));
    await click(tester, cellCenter(3, 3));
    // A click on the cell the cursor is at moves nothing either.
    await click(tester, cellCenter(4, 1));
    expect(output, isEmpty);
    expect(events, isEmpty);
  });

  testWidgets('a touch tap moves the cursor once on a desktop terminal', (
    tester,
  ) async {
    terminal.write('${_prompt}echo hi');
    await pumpView(tester);
    final view = viewKey.currentState!;
    expect(view.leavesTapToParent(PointerDeviceKind.touch), isFalse);
    expect(view.leavesTapToParent(PointerDeviceKind.mouse), isFalse);

    await tester.tapAt(cellCenter(2, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(output.join(), '\x1b[D' * 7);
    expect(events, ['input', 'output', 'cursor moved']);
  });

  testWidgets('mouse tracking takes the click instead', (tester) async {
    terminal.write('${_prompt}ls\x1b[?1000h\x1b[?1006h');
    await pumpView(tester);

    await click(tester, cellCenter(2, 0));
    expect(output.join(), startsWith('\x1b[<0;3;1M'));
    expect(output.join(), isNot(contains('\x1b[D')));
  });

  testWidgets('a click that clears a selection does not move the cursor', (
    tester,
  ) async {
    terminal.write('${_prompt}ls -la');
    await pumpView(tester);
    controller.setSelection(
      terminal.buffer.createAnchor(2, 0),
      terminal.buffer.createAnchor(4, 0),
    );
    await tester.pump();

    await click(tester, cellCenter(2, 0));
    expect(controller.selection, isNull);
    expect(output, isEmpty);
  });

  testWidgets('no move while the viewport is scrolled back', (tester) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    for (var i = 0; i < 40; i++) {
      terminal.write('line $i\r\n');
    }
    terminal.write('${_prompt}ls -la');
    await pumpView(tester, scrollController: scrollController);
    final view = viewKey.currentState!;
    final row = terminal.buffer.absoluteCursorY;

    expect(view.renderTerminal.isScrolledBack, isFalse);
    expect(view.moveTerminalPromptCursor(cellCenter(2, row)), isTrue);
    output.clear();

    scrollController.jumpTo(scrollController.position.maxScrollExtent - 60);
    await tester.pump();
    expect(view.renderTerminal.isScrolledBack, isTrue);
    expect(view.moveTerminalPromptCursor(cellCenter(2, row)), isFalse);
    expect(output, isEmpty);
  });

  testWidgets('touch taps on a system-selection terminal are left to the '
      'screen', (tester) async {
    terminal.write('${_prompt}ls -la');
    await pumpView(tester, useSystemSelection: true);
    expect(
      viewKey.currentState!.leavesTapToParent(PointerDeviceKind.touch),
      isTrue,
    );

    await tester.tapAt(cellCenter(2, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(output, isEmpty);
    expect(events, isEmpty);

    // The screen calls in once it has told the tap from its own gestures.
    expect(
      viewKey.currentState!.moveTerminalPromptCursor(cellCenter(2, 0)),
      isTrue,
    );
    expect(output.join(), '\x1b[D' * 6);
    expect(events, ['input', 'output', 'cursor moved']);
  });

  testWidgets('mouse clicks on a system-selection terminal are left to the '
      'screen', (tester) async {
    terminal.write('${_prompt}ls -la');
    await pumpView(tester, useSystemSelection: true);
    expect(
      viewKey.currentState!.leavesTapToParent(PointerDeviceKind.mouse),
      isTrue,
    );
    expect(
      viewKey.currentState!.leavesTapToParent(PointerDeviceKind.stylus),
      isFalse,
    );

    // The selection takes the click.
    await click(tester, cellCenter(2, 0));
    expect(output, isEmpty);
  });

  testWidgets('prompts that did not ask for clicks keep plain taps', (
    tester,
  ) async {
    terminal.write('\x1b]133;A\x07\$ \x1b]133;B\x07ls');
    await pumpView(tester);
    expect(viewKey.currentState!.canMoveTerminalPromptCursor, isFalse);

    await click(tester, cellCenter(2, 0));
    expect(output, isEmpty);
  });
}
