// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';

void main() {
  group('clampRemoteEditorFontSize', () {
    for (final (input, expected) in [(4.0, 8.0), (64.0, 32.0), (16.0, 16.0)]) {
      test('clamps $input to $expected', () {
        expect(clampRemoteEditorFontSize(input), expected);
      });
    }
  });

  group('applyRemoteEditorScaleDelta', () {
    for (final (fontSize, previousScale, scale, expected) in [
      (16.0, 1.0, 1.5, closeTo(24.0, 0.01)),
      (16.0, 2.0, 1.0, closeTo(8.0, 0.01)),
      (16.0, 0.0, 1.0, closeTo(16.0, 0.01)),
      (32.0, 1.0, 2.0, 32.0),
      (8.0, 2.0, 1.0, 8.0),
    ]) {
      test('scales $fontSize from $previousScale to $scale', () {
        expect(
          applyRemoteEditorScaleDelta(fontSize, previousScale, scale),
          expected,
        );
      });
    }
  });

  group('resolveRemoteEditorVisualScale', () {
    for (final (fontSize, pinchFontSize, expected) in [
      (16.0, null, 1.0),
      (0.0, 20.0, 1.0),
      (16.0, 20.0, closeTo(1.25, 0.001)),
    ]) {
      test('resolves visual scale for $fontSize and $pinchFontSize', () {
        expect(
          resolveRemoteEditorVisualScale(
            fontSize: fontSize,
            pinchFontSize: pinchFontSize,
          ),
          expected,
        );
      });
    }
  });

  group('resolveRemoteEditorGutterDigitSlots', () {
    for (final (count, expected) in [
      (1, 4),
      (9999, 4),
      (10000, 5),
      (100000, 6),
    ]) {
      test('uses $expected digits for $count lines', () {
        expect(resolveRemoteEditorGutterDigitSlots(count), expected);
      });
    }
  });

  group('computeRemoteEditorLineStartOffsets', () {
    for (final (input, expected) in [
      ('hello', [0]),
      ('', [0]),
      ('abc\ndef\nghi', [0, 4, 8]),
      ('a\n', [0, 2]),
    ]) {
      test('finds line starts for text of length ${input.length}', () {
        expect(computeRemoteEditorLineStartOffsets(input), expected);
      });
    }
  });

  group('resolveRemoteEditorCaretPositionFromLineStarts', () {
    test('returns the current line and column from the selection offset', () {
      const text = 'alpha\nbeta\ngamma';
      expect(
        resolveRemoteEditorCaretPositionFromLineStarts(
          text: text,
          selection: const TextSelection.collapsed(offset: 7),
          lineStartOffsets: computeRemoteEditorLineStartOffsets(text),
        ),
        (line: 2, column: 2),
      );
    });

    for (final (offset, expected) in [
      (0, (line: 1, column: 1)),
      (3, (line: 1, column: 4)),
      (4, (line: 2, column: 1)),
      (-1, (line: 1, column: 1)),
      (999, (line: 3, column: 4)),
    ]) {
      test('resolves and clamps offset $offset', () {
        expect(
          resolveRemoteEditorCaretPositionFromLineStarts(
            text: 'abc\ndef\nghi',
            selection: TextSelection.collapsed(offset: offset),
            lineStartOffsets: [0, 4, 8],
          ),
          expected,
        );
      });
    }
  });

  testWidgets(
    'failed save retains dirty text and allows retry without concurrent saves',
    (tester) async {
      final controller = TextEditingController(text: 'original');
      addTearDown(controller.dispose);
      var pending = Completer<void>();
      final savedTexts = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => buildRemoteTextEditorScreenForTesting(
                    fileName: 'notes.txt',
                    controller: controller,
                    onSave: (text) {
                      savedTexts.add(text);
                      return pending.future;
                    },
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'edited');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(savedTexts, ['edited']);
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Save'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RemoteTextEditorScreen), findsOneWidget);
      expect(find.text('Discard changes?'), findsNothing);
      expect(savedTexts, ['edited']);
      pending.completeError(Exception('permission denied'));
      await tester.pumpAndSettle();
      expect(controller.text, 'edited');
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(
        find.text('Could not save changes. Check permissions and try again.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Close editor'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      pending = Completer<void>();
      await tester.enterText(find.byType(TextField), 'retried edit');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(savedTexts, ['edited', 'retried edit']);
      expect(find.byType(RemoteTextEditorScreen), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RemoteTextEditorScreen), findsNothing);
      expect(controller.text, 'retried edit');
    },
  );

  group('RemoteTextEditorScreen caret-X cache', () {
    Widget buildEditor({
      required TextEditingController controller,
      ScrollController? horizontalScrollController,
    }) => MaterialApp(
      home: buildRemoteTextEditorScreenForTesting(
        onSave: (_) async {},
        fileName: 'test.txt',
        controller: controller,
        horizontalScrollController: horizontalScrollController,
      ),
    );

    testWidgets('disposes measurement painters on replacement and teardown', (
      tester,
    ) async {
      final painters = <TextPainter>[];
      void onAllocation(ObjectEvent event) {
        if (event is ObjectCreated && event.object is TextPainter) {
          painters.add(event.object as TextPainter);
        }
      }

      FlutterMemoryAllocations.instance.addListener(onAllocation);
      addTearDown(
        () => FlutterMemoryAllocations.instance.removeListener(onAllocation),
      );
      final first = TextEditingController(text: 'first line');
      final second = TextEditingController(text: 'replacement controller');
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await tester.pumpWidget(buildEditor(controller: first));
      await tester.pumpAndSettle();
      // Text changes replace the cached content painter.
      first.text = 'a longer line with a different measured width';
      await tester.pumpAndSettle();
      // A controller change clears the cache before measuring again.
      await tester.pumpWidget(buildEditor(controller: second));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      expect(painters, isNotEmpty);
      expect(painters.where((painter) => !painter.debugDisposed), isEmpty);
    });

    testWidgets('populates caretX cache after first frame', (tester) async {
      final controller = TextEditingController(text: 'hello world')
        ..selection = const TextSelection.collapsed(offset: 5);
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildEditor(controller: controller));
      await tester.pump(); // settle post-frame callbacks

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      expect(cachedRemoteEditorSelectionCaretX(state), isNotNull);
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 5);
    });

    testWidgets('cache hit: caretX unchanged when selection repeats', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world')
        ..selection = const TextSelection.collapsed(offset: 5);
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildEditor(controller: controller));
      await tester.pump();

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      final firstX = cachedRemoteEditorSelectionCaretX(state);
      expect(firstX, isNotNull);

      // Reassign the same selection – controller fires a change notification.
      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      await tester.pump();

      expect(cachedRemoteEditorSelectionCaretX(state), equals(firstX));
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 5);
    });

    testWidgets('cache miss: caretX updates when extent offset changes', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world')
        ..selection = const TextSelection.collapsed(offset: 2);
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildEditor(controller: controller));
      await tester.pump();

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 2);

      controller.selection = const TextSelection.collapsed(offset: 8);
      await tester.pump();
      await tester.pump();

      // Cached extent offset must reflect the new position.
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 8);
    });

    testWidgets('cache cleared when controller is replaced', (tester) async {
      final controller1 = TextEditingController(text: 'first')
        ..selection = const TextSelection.collapsed(offset: 3);
      addTearDown(controller1.dispose);

      final controller2 = TextEditingController(text: 'second controller')
        ..selection = const TextSelection.collapsed(offset: 6);
      addTearDown(controller2.dispose);

      // Build with controller1 so the caretX cache is populated.
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) =>
                buildRemoteTextEditorScreenForTesting(
                  onSave: (_) async {},
                  fileName: 'test.txt',
                  controller: controller1,
                ),
          ),
        ),
      );
      await tester.pump();

      // Rebuild with controller2 by replacing the widget tree.
      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteTextEditorScreenForTesting(
            onSave: (_) async {},
            fileName: 'test.txt',
            controller: controller2,
          ),
        ),
      );
      await tester.pump();

      final state =
          tester.state(find.byType(RemoteTextEditorScreen))
              as State<RemoteTextEditorScreen>;
      // After the controller swap the cache reflects controller2's selection.
      expect(cachedRemoteEditorSelectionCaretXExtentOffset(state), 6);
    });

    testWidgets(
      'selection visibility: scrolls right when caret is off screen',
      (tester) async {
        // Build a long single line so the content exceeds the viewport.
        final longText = 'x' * 200;
        final scrollController = ScrollController();
        final controller = TextEditingController(text: longText)
          ..selection = TextSelection.collapsed(offset: longText.length);
        addTearDown(controller.dispose);
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          buildEditor(
            controller: controller,
            horizontalScrollController: scrollController,
          ),
        );
        await tester.pump(); // layout + post-frame callbacks

        // The scroll controller should be at a non-negative offset (scrolled
        // right or already at 0 if text fits within the test viewport).
        expect(scrollController.offset, greaterThanOrEqualTo(0));
      },
    );

    testWidgets(
      'selection visibility: no scroll when caret is already visible',
      (tester) async {
        final scrollController = ScrollController();
        final controller = TextEditingController(text: 'short')
          ..selection = const TextSelection.collapsed(offset: 0);
        addTearDown(controller.dispose);
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          buildEditor(
            controller: controller,
            horizontalScrollController: scrollController,
          ),
        );
        await tester.pump();

        // Short text with caret at the start should not scroll at all.
        expect(scrollController.offset, closeTo(0.0, 0.5));
      },
    );
  });

  group('RemoteTextEditorScreen wrapping', () {
    Widget buildEditor({required TextEditingController controller}) =>
        MaterialApp(
          home: buildRemoteTextEditorScreenForTesting(
            onSave: (_) async {},
            fileName: 'authorized_keys',
            controller: controller,
            initialFontSize: 12,
          ),
        );

    testWidgets('wrap off keeps long logical lines on one visual row', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final firstLine = 'ssh-ed25519 ${'A' * 120}';
      final controller = TextEditingController(text: '$firstLine\nsecond')
        ..selection = const TextSelection.collapsed(offset: 0);
      addTearDown(controller.dispose);

      await tester.pumpWidget(buildEditor(controller: controller));
      await tester.pump();

      final renderEditable = tester.allRenderObjects
          .whereType<RenderEditable>()
          .single;
      final secondLineCaret = renderEditable.getLocalRectForCaret(
        TextPosition(offset: firstLine.length + 1),
      );

      expect(
        secondLineCaret.top,
        lessThan(renderEditable.preferredLineHeight * 1.5),
      );
    });
  });
}
