import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

import '../test/helpers/terminal_session_fixture.dart';

Future<double> _waitForKeyboardInset(
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

Offset _cellCenter(MonkeyRenderTerminal renderTerminal, CellOffset offset) =>
    renderTerminal.localToGlobal(
      renderTerminal.getOffset(offset) +
          renderTerminal.cellSize.center(Offset.zero),
    );

Future<void> _dragStartHandleToCell(
  WidgetTester tester,
  MonkeyRenderTerminal renderTerminal, {
  required CellOffset targetCell,
}) async {
  final startSelectionPoint = renderTerminal.value.startSelectionPoint;
  expect(startSelectionPoint, isNotNull);
  final startHandlePosition = renderTerminal.localToGlobal(
    startSelectionPoint!.localPosition,
  );
  final handleDragPosition =
      startHandlePosition + Offset(0, renderTerminal.cellSize.height);

  await tester.timedDragFrom(
    handleDragPosition,
    _cellCenter(renderTerminal, targetCell) - handleDragPosition,
    const Duration(milliseconds: 600),
  );
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const SSHPtyConfig());
    registerFallbackValue(Uint8List(0));
  });

  testWidgets(
    'first long press keeps selection toolbar visible after keyboard input',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final fixture = TerminalSessionFixture(hostId: 1, connectionId: 7);
      final session = fixture.session;
      session.terminal!
        ..setMouseMode(MouseMode.upDownScroll)
        ..setMouseReportMode(MouseReportMode.sgr);

      await fixture.pump(tester);
      await tester.pump();
      await tester.pump();

      session.terminal!.write(
        List<String>.generate(
          28,
          (index) => index == 27 ? 'alpha bravo' : 'line $index',
        ).join('\r\n'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(MonkeyTerminalView));
      final shownKeyboardInset = await _waitForKeyboardInset(
        tester,
        visible: true,
      );
      expect(shownKeyboardInset, greaterThan(0));
      await tester.pumpAndSettle();

      final terminalViewState = tester.state<MonkeyTerminalViewState>(
        find.byType(MonkeyTerminalView),
      );
      final renderTerminal = terminalViewState.renderTerminal;
      Offset? target;
      for (
        var row =
            (session.terminal!.buffer.lines.length -
                    session.terminal!.viewHeight)
                .clamp(0, session.terminal!.buffer.lines.length - 1);
        row < session.terminal!.buffer.lines.length;
        row += 1
      ) {
        final text = session.terminal!.buffer.lines[row].getText(
          0,
          session.terminal!.buffer.viewWidth,
        );
        final startColumn = text.indexOf('alpha');
        if (startColumn == -1) {
          continue;
        }

        target = renderTerminal.localToGlobal(
          renderTerminal.getOffset(CellOffset(startColumn + 2, row)) +
              renderTerminal.cellSize.center(Offset.zero),
        );
        break;
      }
      expect(target, isNotNull);

      var streamIndex = 0;
      final streamTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        session.terminal!.write('\r\nstream $streamIndex');
        streamIndex += 1;
      });
      addTearDown(streamTimer.cancel);

      final gesture = await tester.startGesture(target!);
      await tester.pump(const Duration(milliseconds: 650));
      streamTimer.cancel();
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final selectionKeyboardInset = await _waitForKeyboardInset(
        tester,
        visible: true,
      );
      expect(selectionKeyboardInset, greaterThan(0));
      expect(renderTerminal.getSelectedContent()?.plainText, 'alpha');
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

      await _dragStartHandleToCell(
        tester,
        renderTerminal,
        targetCell: const CellOffset(0, 26),
      );
      expect(
        renderTerminal.getSelectedContent()?.plainText,
        contains('line 26'),
      );
      expect(renderTerminal.getSelectedContent()?.plainText, contains('alpha'));

      for (var index = 0; index < 12; index += 1) {
        session.terminal!.write('\rprogress $index');
        await tester.pump(const Duration(milliseconds: 50));
        expect(renderTerminal.getSelectedContent(), isNotNull);
        expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      }
    },
  );

  testWidgets('selection survives animated progress on selected line', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fixture = TerminalSessionFixture(
      hostId: 43,
      connectionId: 43,
      stdout: const Stream<Uint8List>.empty(),
    );
    final session = fixture.session;
    await fixture.pump(tester);
    await tester.pump();
    await tester.pump();

    session.terminal!.write(
      List<String>.generate(
        24,
        (index) => index == 23 ? 'progress 0' : 'line $index',
      ).join('\r\n'),
    );
    await tester.pumpAndSettle();

    final terminalViewState = tester.state<MonkeyTerminalViewState>(
      find.byType(MonkeyTerminalView),
    );
    final renderTerminal = terminalViewState.renderTerminal;
    final target = _cellCenter(renderTerminal, const CellOffset(3, 23));

    await tester.longPressAt(target);
    await tester.pumpAndSettle();

    expect(renderTerminal.getSelectedContent()?.plainText, 'progress');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    for (var index = 1; index <= 12; index += 1) {
      session.terminal!.write('\r\x1b[2Kprogress $index');
      await tester.pump(const Duration(milliseconds: 50));

      expect(renderTerminal.getSelectedContent()?.plainText, 'progress');
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    }
  });
}
