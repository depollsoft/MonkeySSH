import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';

Widget _buildRemoteEditorWithKeyboardInset({
  required ValueNotifier<double> keyboardInset,
  required TextEditingController controller,
  required ScrollController horizontalScrollController,
}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.android),
  home: Builder(
    builder: (context) => ValueListenableBuilder<double>(
      valueListenable: keyboardInset,
      builder: (context, inset, _) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(viewInsets: EdgeInsets.only(bottom: inset)),
        child: buildRemoteTextEditorScreenForTesting(
          onSave: (_) async {},
          fileName: 'notes.txt',
          controller: controller,
          horizontalScrollController: horizontalScrollController,
        ),
      ),
    ),
  ),
);

class _WideTokenController extends TextEditingController {
  _WideTokenController({required super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    required bool withComposing,
    TextStyle? style,
  }) {
    const plainPrefix = 'plain ';
    final baseStyle = style ?? const TextStyle();
    return TextSpan(
      style: baseStyle,
      children: [
        TextSpan(text: text.substring(0, plainPrefix.length)),
        TextSpan(
          text: text.substring(plainPrefix.length),
          style: baseStyle.copyWith(letterSpacing: 10),
        ),
      ],
    );
  }
}

void main() {
  group('resolveRemoteEditorGutterDigitSlots', () {
    test('keeps four digits by default and grows for larger files', () {
      expect(resolveRemoteEditorGutterDigitSlots(1), 4);
      expect(resolveRemoteEditorGutterDigitSlots(9999), 4);
      expect(resolveRemoteEditorGutterDigitSlots(10000), 5);
    });
  });

  group('remote editor zoom helpers', () {
    test('clamps remote editor font size to the supported range', () {
      expect(clampRemoteEditorFontSize(2), 8);
      expect(clampRemoteEditorFontSize(18), 18);
      expect(clampRemoteEditorFontSize(64), 32);
    });

    test(
      'applies pinch scale deltas safely when previous scale is nonpositive',
      () {
        expect(applyRemoteEditorScaleDelta(16, 0, 2), 32);
        expect(applyRemoteEditorScaleDelta(16, -1, 0.5), 8);
      },
    );

    test('resolves the transient visual editor scale from pinch sizing', () {
      expect(resolveRemoteEditorVisualScale(fontSize: 14), 1);
      expect(
        resolveRemoteEditorVisualScale(fontSize: 14, pinchFontSize: 21),
        1.5,
      );
    });
  });

  group('buildRemoteTextEditorScreenForTesting', () {
    test('uses Menlo for the system monospace font on iOS', () {
      expect(
        resolveRemoteEditorTextStyle(
          'monospace',
          platform: TargetPlatform.iOS,
        ).fontFamily,
        'Menlo',
      );
    });

    test('uses the configured terminal font family when provided', () {
      expect(
        resolveRemoteEditorTextStyle(
          'Custom Mono',
          platform: TargetPlatform.android,
        ).fontFamily,
        'Custom Mono',
      );
    });

    testWidgets('shows an explicit close affordance in the editor app bar', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'alpha');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteTextEditorScreenForTesting(
            onSave: (_) async {},
            fileName: 'notes.txt',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Close editor'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('shows the full remote path in the editor app bar', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'alpha');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteTextEditorScreenForTesting(
            onSave: (_) async {},
            fileName: 'notes.txt',
            filePath: '/home/demo/project/notes.txt',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit /home/demo/project/notes.txt'), findsOneWidget);
    });

    testWidgets('close affordance warns before discarding unsaved edits', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'alpha');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<String>(
                    builder: (_) => buildRemoteTextEditorScreenForTesting(
                      onSave: (_) async {},
                      fileName: 'notes.txt',
                      controller: controller,
                    ),
                  ),
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'beta');
      await tester.pump();
      await tester.tap(find.byTooltip('Close editor'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Edit notes.txt'), findsOneWidget);
    });

    testWidgets(
      'starts at line 1 when the incoming controller selection is invalid',
      (tester) async {
        final controller = TextEditingController(text: 'alpha\nbeta');
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: buildRemoteTextEditorScreenForTesting(
              onSave: (_) async {},
              fileName: 'notes.txt',
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.selection, const TextSelection.collapsed(offset: 0));
        expect(find.text('Line 1, Column 1'), findsOneWidget);
      },
    );

    testWidgets(
      'keeps the nowrap viewport fixed while scrolling the selection into view',
      (tester) async {
        final longLine = List<String>.filled(80, '0123456789').join();
        final controller = TextEditingController(text: longLine)
          ..selection = TextSelection.collapsed(offset: longLine.length);
        final horizontalScrollController = ScrollController();

        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          horizontalScrollController.dispose();
          controller.dispose();
        });

        await tester.binding.setSurfaceSize(const Size(420, 720));
        await tester.pumpWidget(
          MaterialApp(
            home: buildRemoteTextEditorScreenForTesting(
              onSave: (_) async {},
              fileName: 'notes.txt',
              controller: controller,
              horizontalScrollController: horizontalScrollController,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .getSize(
                find.byKey(
                  const ValueKey<String>('remoteTextEditorNowrapViewport'),
                ),
              )
              .width,
          closeTo(308.0, 0.1),
        );
        expect(
          tester
              .getSize(
                find.byKey(const ValueKey<String>('remoteTextEditorSurface')),
              )
              .width,
          closeTo(396, 0.1),
        );
        expect(
          tester
              .getTopRight(
                find.byKey(
                  const ValueKey<String>('remoteTextEditorNowrapViewport'),
                ),
              )
              .dx,
          lessThanOrEqualTo(
            tester
                .getTopRight(
                  find.byKey(const ValueKey<String>('remoteTextEditorSurface')),
                )
                .dx,
          ),
        );
        expect(horizontalScrollController.offset, greaterThan(0));
        expect(find.byType(InputDecorator), findsNothing);
      },
    );

    testWidgets(
      'keeps the editor input connection open across keyboard inset changes',
      (tester) async {
        final longLine = List<String>.filled(80, '0123456789').join();
        final controller = TextEditingController(text: longLine)
          ..selection = TextSelection.collapsed(offset: longLine.length);
        final horizontalScrollController = ScrollController();
        final keyboardInset = ValueNotifier<double>(260);

        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          keyboardInset.dispose();
          horizontalScrollController.dispose();
          controller.dispose();
        });

        await tester.binding.setSurfaceSize(const Size(420, 720));
        await tester.pumpWidget(
          _buildRemoteEditorWithKeyboardInset(
            keyboardInset: keyboardInset,
            controller: controller,
            horizontalScrollController: horizontalScrollController,
          ),
        );
        await tester.pumpAndSettle();

        final scrollbarFinder = find.descendant(
          of: find.byKey(
            const ValueKey<String>('remoteTextEditorNowrapViewport'),
          ),
          matching: find.byType(Scrollbar),
        );
        final editableTextFinder = find.byType(EditableText);
        final textFieldFinder = find.byType(TextField);
        final openViewportRect = tester.getRect(
          find.byKey(const ValueKey<String>('remoteTextEditorNowrapViewport')),
        );
        final openEditableText = tester.widget<EditableText>(
          editableTextFinder,
        );
        final openSelection = controller.selection;
        final openText = controller.text;

        await tester.showKeyboard(textFieldFinder);
        await tester.pump();

        expect(scrollbarFinder, findsOneWidget);
        expect(openEditableText.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(controller.selection, openSelection);
        expect(controller.text, openText);

        keyboardInset.value = 0;
        await tester.pump();
        await tester.pumpAndSettle();

        final closedViewportRect = tester.getRect(
          find.byKey(const ValueKey<String>('remoteTextEditorNowrapViewport')),
        );
        final closedEditableText = tester.widget<EditableText>(
          editableTextFinder,
        );

        expect(scrollbarFinder, findsOneWidget);
        expect(closedEditableText.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(controller.selection, openSelection);
        expect(controller.text, openText);
        expect(closedViewportRect.height, greaterThan(openViewportRect.height));
      },
    );

    testWidgets('does not soft-wrap rich highlighted text when wrap is off', (
      tester,
    ) async {
      final longLine = 'plain ${List<String>.filled(80, 'wide').join(' ')}';
      final controller = _WideTokenController(text: longLine);

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        controller.dispose();
      });

      await tester.binding.setSurfaceSize(const Size(420, 720));
      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteTextEditorScreenForTesting(
            onSave: (_) async {},
            fileName: 'notes.txt',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final renderEditableFinder = find.byElementPredicate(
        (element) => element.renderObject is RenderEditable,
      );
      final renderEditable = tester.renderObject<RenderEditable>(
        renderEditableFinder,
      );
      final firstLineStart = renderEditable.getLocalRectForCaret(
        const TextPosition(offset: 0),
      );
      final firstLineEnd = renderEditable.getLocalRectForCaret(
        TextPosition(offset: longLine.length),
      );

      expect(firstLineEnd.top, closeTo(firstLineStart.top, 0.1));
    });

    testWidgets('shows status details plus wrap and zoom controls', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'alpha\nbeta')
        ..selection = const TextSelection.collapsed(offset: 7);

      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: buildRemoteTextEditorScreenForTesting(
            onSave: (_) async {},
            fileName: 'notes.txt',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Line 2, Column 2'), findsOneWidget);
      expect(find.text('Wrap off'), findsOneWidget);
      expect(find.text('14 pt'), findsOneWidget);
      expect(find.byTooltip('Enable line wrap'), findsOneWidget);
      expect(find.byTooltip('Zoom out'), findsOneWidget);
      expect(find.byTooltip('Zoom in'), findsOneWidget);

      await tester.tap(find.byTooltip('Enable line wrap'));
      await tester.pumpAndSettle();

      expect(find.text('Wrap on'), findsOneWidget);
      expect(find.byTooltip('Disable line wrap'), findsOneWidget);
    });

    testWidgets('hides zoom buttons on touch-first platforms', (tester) async {
      final controller = TextEditingController(text: 'alpha\nbeta');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: buildRemoteTextEditorScreenForTesting(
            onSave: (_) async {},
            fileName: 'notes.txt',
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Zoom out'), findsNothing);
      expect(find.byTooltip('Zoom in'), findsNothing);
    });

    testWidgets(
      'pinch zoom scales the editor surface during the gesture then commits font size',
      (tester) async {
        final controller = TextEditingController(text: 'alpha\nbeta\ngamma');
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: buildRemoteTextEditorScreenForTesting(
              onSave: (_) async {},
              fileName: 'notes.txt',
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final editableTextFinder = find.byType(EditableText);
        final transformFinder = find.byKey(
          const ValueKey<String>('remoteTextEditorContentTransform'),
        );
        final target = find.byKey(
          const ValueKey<String>('remoteTextEditorSurface'),
        );

        expect(
          tester.widget<EditableText>(editableTextFinder).style.fontSize,
          14,
        );
        expect(
          tester
              .widget<Transform>(transformFinder)
              .transform
              .getMaxScaleOnAxis(),
          1,
        );

        final center = tester.getCenter(target);
        final firstGesture = await tester.createGesture(pointer: 10);
        await firstGesture.down(center - const Offset(30, 0));
        await tester.pump();

        final secondGesture = await tester.createGesture(pointer: 11);
        await secondGesture.down(center + const Offset(30, 0));
        await tester.pump();

        await firstGesture.moveBy(const Offset(-20, 0));
        await secondGesture.moveBy(const Offset(20, 0));
        await tester.pump();

        expect(
          tester
              .widget<Transform>(transformFinder)
              .transform
              .getMaxScaleOnAxis(),
          closeTo(1.67, 0.01),
        );
        expect(
          tester.widget<EditableText>(editableTextFinder).style.fontSize,
          14,
        );
        expect(find.text('23 pt'), findsOneWidget);

        await firstGesture.up();
        await secondGesture.up();
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<Transform>(transformFinder)
              .transform
              .getMaxScaleOnAxis(),
          1,
        );
        expect(
          tester.widget<EditableText>(editableTextFinder).style.fontSize,
          closeTo(23.3, 0.1),
        );
      },
    );
  });
}
