import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_paste_upload_strip.dart';

void main() {
  group('TerminalPasteUploadProgress', () {
    test('reports a clamped fraction when the total is known', () {
      expect(
        const TerminalPasteUploadProgress(
          uploadedBytes: 25,
          totalBytes: 100,
        ).fraction,
        0.25,
      );
      expect(
        const TerminalPasteUploadProgress(
          uploadedBytes: 150,
          totalBytes: 100,
        ).fraction,
        1.0,
      );
    });

    test('is indeterminate without a usable total', () {
      expect(
        const TerminalPasteUploadProgress(uploadedBytes: 25).fraction,
        isNull,
      );
      expect(
        const TerminalPasteUploadProgress(
          uploadedBytes: 25,
          totalBytes: 0,
        ).fraction,
        isNull,
      );
    });

    test('describes progress for assistive technology', () {
      expect(
        describeTerminalPasteUploadProgress(
          const TerminalPasteUploadProgress(uploadedBytes: 1, totalBytes: 3),
        ),
        'Uploading paste, 33 percent',
      );
      expect(
        describeTerminalPasteUploadProgress(
          const TerminalPasteUploadProgress(uploadedBytes: 1),
        ),
        'Uploading paste',
      );
    });
  });

  group('TerminalPasteUploadStrip', () {
    Future<void> pumpStrip(
      WidgetTester tester,
      TerminalPasteUploadProgress progress, {
      bool disableAnimations = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TerminalPasteUploadStrip(progress: progress),
            ),
          ),
        ),
      ),
    );

    testWidgets('renders a determinate 3px line with the accent color', (
      tester,
    ) async {
      await pumpStrip(
        tester,
        const TerminalPasteUploadProgress(uploadedBytes: 40, totalBytes: 80),
      );

      final line = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey<String>('terminal-paste-upload-line')),
      );
      expect(line.value, 0.5);
      expect(line.minHeight, TerminalPasteUploadStrip.lineHeight);
      final colorScheme = Theme.of(
        tester.element(find.byType(TerminalPasteUploadStrip)),
      ).colorScheme;
      expect(line.color, colorScheme.primary);
      expect(line.backgroundColor, colorScheme.surfaceContainerHighest);
      expect(
        tester.getSize(find.byType(TerminalPasteUploadStrip)).height,
        TerminalPasteUploadStrip.lineHeight,
      );
      expect(find.byType(Text), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('is indeterminate when the total is unknown', (tester) async {
      await pumpStrip(
        tester,
        const TerminalPasteUploadProgress(uploadedBytes: 40),
      );

      final line = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey<String>('terminal-paste-upload-line')),
      );
      expect(line.value, isNull);
    });

    testWidgets('holds a static half line when animations are disabled', (
      tester,
    ) async {
      await pumpStrip(
        tester,
        const TerminalPasteUploadProgress(uploadedBytes: 40),
        disableAnimations: true,
      );

      final line = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey<String>('terminal-paste-upload-line')),
      );
      expect(line.value, 0.5);
    });

    testWidgets('exposes progress as a single semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStrip(
        tester,
        const TerminalPasteUploadProgress(uploadedBytes: 1, totalBytes: 4),
      );

      expect(
        tester.getSemantics(find.byType(TerminalPasteUploadStrip)),
        matchesSemantics(label: 'Uploading paste, 25 percent', value: '25'),
      );
      handle.dispose();
    });
  });
}
