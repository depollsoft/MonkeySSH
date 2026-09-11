// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = luminanceA > luminanceB ? luminanceA : luminanceB;
  final darkest = luminanceA > luminanceB ? luminanceB : luminanceA;
  return (brightest + 0.05) / (darkest + 0.05);
}

void main() {
  Widget buildTerminal({
    required Terminal terminal,
    required Size size,
    Key? terminalKey,
    double keyboardInset = 0,
    FocusNode? focusNode,
    bool readOnly = true,
    bool resizeTerminalToViewport = true,
    bool notifyPixelSizeChanges = true,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        viewInsets: EdgeInsets.only(bottom: keyboardInset),
      ),
      child: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MonkeyTerminalView(
            key: terminalKey,
            terminal,
            focusNode: focusNode,
            hardwareKeyboardOnly: true,
            readOnly: readOnly,
            resizeTerminalToViewport: resizeTerminalToViewport,
            notifyPixelSizeChanges: notifyPixelSizeChanges,
          ),
        ),
      ),
    ),
  );

  testWidgets('auto resize reports total viewport pixels', (tester) async {
    final terminal = Terminal();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 240)),
    );

    expect(resizeEvents, isNotEmpty);
    final event = resizeEvents.last;
    expect(event.width, greaterThan(0));
    expect(event.height, greaterThan(0));
    expect(event.pixelWidth, 320);
    expect(event.pixelHeight, 240);
  });

  testWidgets(
    'shared grid suppresses pixel-only resize until explicit refresh',
    (tester) async {
      final terminal = Terminal()..resize(160, 48);
      final terminalKey = GlobalKey<MonkeyTerminalViewState>();
      final resizeEvents =
          <({int width, int height, int pixelWidth, int pixelHeight})>[];
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        resizeEvents.add((
          width: width,
          height: height,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
        ));
      };

      await tester.pumpWidget(
        buildTerminal(
          terminal: terminal,
          terminalKey: terminalKey,
          size: const Size(320, 240),
          resizeTerminalToViewport: false,
          notifyPixelSizeChanges: false,
        ),
      );
      // Keep the remote-owned 160x48 grid mismatched from this local viewport.
      // Passive layout must still key notifications to local viewport changes,
      // not repeatedly reassert the same mismatch.
      resizeEvents.clear();
      final state = terminalKey.currentState!;
      final rows = state.viewportCellSize!.rows;
      final lineHeight = state.renderTerminal.lineHeight;
      final nextHeight = 241.0 ~/ lineHeight == rows ? 241.0 : 239.0;
      expect(nextHeight ~/ lineHeight, rows);

      // One physical pixel does not cross a cell boundary. Updating terminal
      // pixel metrics here would still SIGWINCH a remote Pi process and make it
      // rebuild the whole transcript for no visible grid change.
      await tester.pumpWidget(
        buildTerminal(
          terminal: terminal,
          terminalKey: terminalKey,
          size: Size(320, nextHeight),
          resizeTerminalToViewport: false,
          notifyPixelSizeChanges: false,
        ),
      );
      expect(resizeEvents, isEmpty);

      terminalKey.currentState!.refreshTerminalSize();
      expect(resizeEvents, hasLength(1));
      expect(resizeEvents.single.pixelHeight, nextHeight.round());
    },
  );

  test('host-requested resize does not echo a resize event', () {
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    final hostResizeEvents = <({int width, int height})>[];
    final terminal = Terminal()
      ..canResizeFromHost = (() => true)
      ..onResize = (width, height, pixelWidth, pixelHeight) {
        resizeEvents.add((
          width: width,
          height: height,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
        ));
      }
      ..onHostResize = (width, height) {
        hostResizeEvents.add((width: width, height: height));
      }
      ..write('\x1b[?8;50;160t');

    expect(terminal.viewWidth, 160);
    expect(terminal.viewHeight, 50);
    expect(resizeEvents, isEmpty);
    expect(hostResizeEvents, [(width: 160, height: 50)]);
    expect(terminal.hostResizeGeneration, 1);

    terminal.resetHostResizeState();

    expect(terminal.hostResizeGeneration, 0);
  });

  test('standard host resize still reports the new size', () {
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    final terminal = Terminal()
      ..onResize = (width, height, pixelWidth, pixelHeight) {
        resizeEvents.add((
          width: width,
          height: height,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
        ));
      }
      ..write('\x1b[8;40;120t');

    expect(terminal.viewWidth, 120);
    expect(terminal.viewHeight, 40);
    expect(resizeEvents, hasLength(1));
    expect(resizeEvents.single.width, 120);
    expect(resizeEvents.single.height, 40);
  });

  testWidgets(
    'shared terminal grid is clipped instead of resized to viewport',
    (tester) async {
      final terminal = Terminal()..resize(160, 50);
      final terminalKey = GlobalKey<MonkeyTerminalViewState>();
      final resizeEvents =
          <({int width, int height, int pixelWidth, int pixelHeight})>[];
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        resizeEvents.add((
          width: width,
          height: height,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
        ));
      };

      await tester.pumpWidget(
        buildTerminal(
          terminal: terminal,
          terminalKey: terminalKey,
          size: const Size(320, 240),
          resizeTerminalToViewport: false,
        ),
      );

      final viewportCellSize = terminalKey.currentState!.viewportCellSize!;
      expect(viewportCellSize.columns, lessThan(160));
      expect(viewportCellSize.rows, lessThan(50));
      expect(terminal.viewWidth, 160);
      expect(terminal.viewHeight, 50);
      expect(resizeEvents.last.width, viewportCellSize.columns);
      expect(resizeEvents.last.height, viewportCellSize.rows);

      terminal.write('x' * 120);

      expect(terminal.buffer.cursorX, 120);
      expect(
        terminal.buffer.lines[terminal.buffer.absoluteCursorY].isWrapped,
        isFalse,
      );
    },
  );

  testWidgets('size refresh re-sends the current viewport dimensions', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    expect(resizeEvents, isNotEmpty);
    final initialEvent = resizeEvents.last;
    final initialCount = resizeEvents.length;

    terminalKey.currentState!.refreshTerminalSize();

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last, initialEvent);
  });

  testWidgets('display refresh re-sends the current viewport dimensions', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    expect(resizeEvents, isNotEmpty);
    final initialEvent = resizeEvents.last;
    final initialCount = resizeEvents.length;

    terminalKey.currentState!.refreshTerminalDisplay(revealLatestOutput: true);

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last, initialEvent);
  });

  testWidgets('remounting an already-sized terminal skips passive resize', (
    tester,
  ) async {
    final terminal = Terminal();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 240)),
    );

    expect(resizeEvents, isNotEmpty);
    final initialCount = resizeEvents.length;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 240)),
    );

    expect(resizeEvents, hasLength(initialCount));
  });

  testWidgets('size refresh repairs stale terminal cell dimensions', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    final viewportColumns = terminal.viewWidth;
    final viewportRows = terminal.viewHeight;
    expect(viewportColumns, greaterThan(1));
    expect(viewportRows, greaterThan(1));

    terminal.resize(viewportColumns - 1, viewportRows - 1);
    expect(terminal.viewWidth, viewportColumns - 1);
    expect(terminal.viewHeight, viewportRows - 1);

    terminalKey.currentState!.refreshTerminalSize();

    expect(terminal.viewWidth, viewportColumns);
    expect(terminal.viewHeight, viewportRows);
    expect(resizeEvents.last.width, viewportColumns);
    expect(resizeEvents.last.height, viewportRows);
  });

  testWidgets('same-size refresh preserves terminal scroll margins', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    expect(resizeEvents, isNotEmpty);
    final initialCount = resizeEvents.length;
    terminal.setMargins(1, 2);
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);

    terminalKey.currentState!.refreshTerminalSize();

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);
  });

  testWidgets('pixel-only resize preserves terminal scroll margins', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
      ),
    );

    final renderTerminal = terminalKey.currentState!.renderTerminal;
    final cellSize = renderTerminal.cellSize;
    final columns = terminal.viewWidth;
    final rows = terminal.viewHeight;
    final nextSize = Size(
      (columns * cellSize.width) + (cellSize.width * 0.5),
      (rows * cellSize.height) + (cellSize.height * 0.5),
    );
    final initialCount = resizeEvents.length;

    terminal.setMargins(1, 2);
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: nextSize,
      ),
    );

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last.width, columns);
    expect(resizeEvents.last.height, rows);
    expect(resizeEvents.last.pixelWidth, nextSize.width.round());
    expect(resizeEvents.last.pixelHeight, nextSize.height.round());
    expect(terminal.buffer.marginTop, 1);
    expect(terminal.buffer.marginBottom, 2);
  });

  testWidgets('keyboard inset changes debounce before the final resize', (
    tester,
  ) async {
    final terminal = Terminal();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 400)),
    );

    expect(resizeEvents, isNotEmpty);
    final initialEvent = resizeEvents.last;
    final initialCount = resizeEvents.length;

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        size: const Size(320, 240),
        keyboardInset: 160,
      ),
    );

    expect(resizeEvents, hasLength(initialCount));
    expect(terminal.viewWidth, initialEvent.width);
    expect(terminal.viewHeight, initialEvent.height);

    await tester.pump(terminalKeyboardResizeDebounceDuration);

    expect(resizeEvents, hasLength(initialCount + 1));
    final keyboardShownEvent = resizeEvents.last;
    expect(keyboardShownEvent.width, initialEvent.width);
    expect(keyboardShownEvent.height, lessThan(initialEvent.height));
    expect(keyboardShownEvent.pixelWidth, 320);
    expect(keyboardShownEvent.pixelHeight, 240);

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 400)),
    );

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last, keyboardShownEvent);

    await tester.pump(terminalKeyboardResizeDebounceDuration);

    expect(resizeEvents, hasLength(initialCount + 2));
    expect(resizeEvents.last.width, initialEvent.width);
    expect(resizeEvents.last.height, initialEvent.height);
    expect(resizeEvents.last.pixelWidth, initialEvent.pixelWidth);
    expect(resizeEvents.last.pixelHeight, initialEvent.pixelHeight);
  });

  testWidgets('size refresh can flush a pending keyboard resize', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final resizeEvents =
        <({int width, int height, int pixelWidth, int pixelHeight})>[];
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizeEvents.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 400),
      ),
    );

    final initialCount = resizeEvents.length;
    final initialEvent = resizeEvents.last;

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        terminalKey: terminalKey,
        size: const Size(320, 240),
        keyboardInset: 160,
      ),
    );

    expect(resizeEvents, hasLength(initialCount));

    terminalKey.currentState!.refreshTerminalSize(flushKeyboardResize: true);

    expect(resizeEvents, hasLength(initialCount + 1));
    expect(resizeEvents.last.width, initialEvent.width);
    expect(resizeEvents.last.height, lessThan(initialEvent.height));
    expect(resizeEvents.last.pixelWidth, 320);
    expect(resizeEvents.last.pixelHeight, 240);

    await tester.pump(terminalKeyboardResizeDebounceDuration);

    expect(resizeEvents, hasLength(initialCount + 1));
  });

  testWidgets('emits focus reports when focus reporting mode is enabled', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()
      ..write('\x1b[?1004h')
      ..onOutput = output.add;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        size: const Size(320, 240),
        focusNode: focusNode,
        readOnly: false,
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    expect(output, contains('\x1b[I'));

    focusNode.unfocus();
    await tester.pump();

    expect(output, contains('\x1b[O'));
  });

  testWidgets('refreshFocusReport resends focus gained when requested', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()
      ..write('\x1b[?1004h')
      ..onOutput = output.add;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      buildTerminal(
        terminal: terminal,
        size: const Size(320, 240),
        focusNode: focusNode,
        readOnly: false,
      ),
    );

    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshFocusReport();

    expect(output, ['\x1b[I']);

    output.clear();
    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshFocusReport(forceTransition: true);

    expect(output, ['\x1b[O']);
    await tester.pump(const Duration(milliseconds: 50));
    expect(output, ['\x1b[O', '\x1b[I']);

    terminal.write('\x1b[?1004l');
    output.clear();
    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshFocusReport();

    expect(output, isEmpty);

    tester
        .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
        .refreshFocusReport(forceTransition: true, force: true);

    expect(output, ['\x1b[O']);
    await tester.pump(const Duration(milliseconds: 50));
    expect(output, ['\x1b[O', '\x1b[I']);
  });

  testWidgets('refreshThemeModeReport sends xterm theme mode report', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;

    await tester.pumpWidget(
      buildTerminal(terminal: terminal, size: const Size(320, 240)),
    );

    final terminalViewState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );

    for (final isDark in [true, false]) {
      terminalViewState.refreshThemeModeReport(isDark: isDark);
    }

    expect(output, ['\x1b[?997;1n', '\x1b[?997;2n']);
  });

  testWidgets('focused block cursor repaints the covered glyph', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    const hiddenColor = Color(0xFFE53935);
    const backgroundColor = Color(0xFF0D1A20);
    final hiddenTheme = monkey_themes.TerminalThemes.defaultDarkTheme
        .copyWith(
          foreground: hiddenColor,
          background: backgroundColor,
          cursor: hiddenColor,
        )
        .toXtermTheme();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 240,
          child: MonkeyTerminalView(
            key: terminalKey,
            terminal,
            theme: hiddenTheme,
            focusNode: focusNode,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    terminal.write('A\x1b[1D');
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
    final renderTerminal = terminalKey.currentState!.renderTerminal;
    // Row glyphs are now recorded per line into a cached picture (replayed as a
    // drawPicture), so the only *direct* drawParagraph left is the focused block
    // cursor repainting the glyph it covers, clipped to that cell with a
    // readable color.
    expect(
      renderTerminal,
      paints
        ..something((symbol, arguments) => symbol == #clipRect)
        ..paragraph(),
    );
    expect(
      resolveMonkeyTerminalCursorForegroundColor(
        cursor: hiddenColor,
        background: hiddenColor,
        foreground: hiddenColor,
      ),
      isNot(hiddenColor),
    );
  });

  testWidgets(
    'line backgrounds are painted before glyphs so descenders are not clipped',
    (tester) async {
      final terminal = Terminal();
      final terminalKey = GlobalKey<MonkeyTerminalViewState>();

      const backgroundColor = Color(0xFF0D1A20);
      final theme = monkey_themes.TerminalThemes.defaultDarkTheme
          .copyWith(background: backgroundColor)
          .toXtermTheme();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 240,
            child: MonkeyTerminalView(
              key: terminalKey,
              terminal,
              theme: theme,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      // A descender glyph on the first row only. Its ink can extend past the
      // cell box, so every row's opaque background must be painted before this
      // glyph or the next row's background would clip the bottom of the "g".
      terminal.write('g');
      await tester.pump();

      final renderTerminal = terminalKey.currentState!.renderTerminal;
      final paintPattern = paints;
      for (var row = 0; row < terminal.viewHeight; row += 1) {
        paintPattern.rect(color: backgroundColor, style: PaintingStyle.fill);
      }
      // Each line's glyphs are recorded once into a cached picture and replayed
      // as a drawPicture in the second pass, so the first foreground draw still
      // lands after every row background.
      paintPattern.something((symbol, arguments) => symbol == #drawPicture);
      expect(renderTerminal, paintPattern);
    },
  );

  testWidgets(
    'terminal writes advance the change counter and paints advance the paint '
    'counter',
    (tester) async {
      final terminal = Terminal();
      final terminalKey = GlobalKey<MonkeyTerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 240,
            child: MonkeyTerminalView(
              key: terminalKey,
              terminal,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );
      await tester.pump();

      final state = terminalKey.currentState!;
      final changesBefore = state.terminalChangeCount;
      final paintsBefore = state.terminalPaintCount;
      expect(changesBefore, isNotNull);
      expect(paintsBefore, isNotNull);

      terminal.write('hello');
      await tester.pump();

      expect(state.terminalChangeCount, greaterThan(changesBefore!));
      expect(state.terminalPaintCount, greaterThan(paintsBefore!));
    },
  );

  testWidgets('forceFullRepaint produces a new frame from the current buffer', (
    tester,
  ) async {
    final terminal = Terminal();
    final terminalKey = GlobalKey<MonkeyTerminalViewState>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 240,
          child: MonkeyTerminalView(
            key: terminalKey,
            terminal,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final state = terminalKey.currentState!;
    // Let any initial frames settle so the counter is stable.
    await tester.pump();
    final paintsBefore = state.terminalPaintCount!;

    state.forceFullRepaint();
    await tester.pump();

    expect(state.terminalPaintCount, greaterThan(paintsBefore));
  });

  test('explicit xterm palette grayscale colors stay standard', () {
    final darkTheme = monkey_themes.TerminalThemes.defaultDarkTheme
        .toXtermTheme();
    final lightTheme = monkey_themes.TerminalThemes.defaultLightTheme
        .toXtermTheme();
    final darkPainter = MonkeyTerminalPainter(
      theme: darkTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final lightPainter = MonkeyTerminalPainter(
      theme: lightTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    for (final painter in [darkPainter, lightPainter]) {
      expect(
        painter.resolveForegroundColor(CellColor.palette | 244),
        const Color(0xFF808080),
      );
      expect(
        painter.resolveBackgroundColor(CellColor.palette | 235),
        const Color(0xFF262626),
      );
    }
  });

  test('runtime overrides replace extended xterm palette colors', () {
    final theme = monkey_themes.TerminalThemes.defaultDarkTheme
        .copyWith(
          paletteOverrides: const <int, Color>{
            16: Color(0xFF123456),
            244: Color(0xFFABCDEF),
          },
        )
        .toXtermTheme();
    final painter = MonkeyTerminalPainter(
      theme: theme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    expect(
      painter.resolveForegroundColor(CellColor.palette | 16),
      const Color(0xFF123456),
    );
    expect(
      painter.resolveBackgroundColor(CellColor.palette | 244),
      const Color(0xFFABCDEF),
    );
  });

  test('ANSI bright colors follow the active theme palette', () {
    final darkTheme = monkey_themes.TerminalThemes.defaultDarkTheme
        .toXtermTheme();
    final lightTheme = monkey_themes.TerminalThemes.defaultLightTheme
        .toXtermTheme();
    final darkPainter = MonkeyTerminalPainter(
      theme: darkTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final lightPainter = MonkeyTerminalPainter(
      theme: lightTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    expect(
      darkPainter.resolveForegroundColor(CellColor.named | 8),
      darkTheme.brightBlack,
    );
    expect(
      lightPainter.resolveForegroundColor(CellColor.named | 8),
      lightTheme.brightBlack,
    );
    expect(
      darkPainter.resolveForegroundColor(CellColor.named | 15),
      darkTheme.brightWhite,
    );
    expect(
      lightPainter.resolveForegroundColor(CellColor.named | 15),
      lightTheme.brightWhite,
    );
    expect(
      darkPainter.resolveBackgroundColor(CellColor.palette | 15),
      darkTheme.brightWhite,
    );
    expect(
      lightPainter.resolveBackgroundColor(CellColor.palette | 15),
      lightTheme.brightWhite,
    );
    expect(darkTheme.brightBlack, isNot(lightTheme.brightBlack));
    expect(darkTheme.brightWhite, isNot(darkTheme.white));
  });

  test('faint terminal text preserves each theme base readability', () {
    for (final theme in monkey_themes.TerminalThemes.all) {
      final faintForeground = resolveMonkeyTerminalFaintForegroundColor(
        foreground: theme.foreground,
        background: theme.background,
      );
      final baseContrast = _contrastRatio(theme.foreground, theme.background);
      final expectedContrast = baseContrast >= 4.5 ? 4.5 : baseContrast;

      expect(
        _contrastRatio(faintForeground, theme.background),
        greaterThanOrEqualTo(expectedContrast),
        reason:
            'Theme ${theme.name} should not let SGR 2 faint text fall below '
            'the base foreground contrast that its palette provides.',
      );
    }
  });

  test('faint terminal text remains dim when contrast allows it', () {
    const theme = monkey_themes.TerminalThemes.atomOneDark;
    final defaultFaint = Color.alphaBlend(
      theme.foreground.withAlpha(128),
      theme.background,
    );
    final readableFaint = resolveMonkeyTerminalFaintForegroundColor(
      foreground: theme.foreground,
      background: theme.background,
    );

    expect(_contrastRatio(defaultFaint, theme.background), lessThan(4.5));
    expect(
      _contrastRatio(readableFaint, theme.background),
      greaterThanOrEqualTo(4.5),
    );
    expect(readableFaint, isNot(theme.foreground));
  });

  test('cursor text stays readable against built-in cursor colors', () {
    for (final theme in monkey_themes.TerminalThemes.all) {
      final cursorForeground = resolveMonkeyTerminalCursorForegroundColor(
        cursor: theme.cursor,
        background: theme.background,
        foreground: theme.foreground,
      );

      expect(
        _contrastRatio(cursorForeground, theme.cursor),
        greaterThanOrEqualTo(4.5),
        reason:
            'Theme ${theme.name} should keep text under the block cursor '
            'readable.',
      );
    }
  });
}
