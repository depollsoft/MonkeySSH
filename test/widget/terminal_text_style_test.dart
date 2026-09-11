import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_style.dart';

void main() {
  for (final allowRuntimeFetching in [false, true]) {
    testWidgets(
      'default terminal font is bundled with runtime fetching $allowRuntimeFetching',
      (tester) async {
        final previousFetching = GoogleFonts.config.allowRuntimeFetching;
        addTearDown(() {
          GoogleFonts.config.allowRuntimeFetching = previousFetching;
        });
        GoogleFonts.config.allowRuntimeFetching = allowRuntimeFetching;

        for (final platform in [
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        ]) {
          final style = resolveMonospaceTextStyle(
            'JetBrains Mono',
            platform: platform,
            fontSize: 17,
          );
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text('Terminal', style: style),
            ),
          );
          final richText = tester.widget<RichText>(find.byType(RichText));
          expect(richText.text.style?.fontFamily, 'JetBrains Mono');
          expect(richText.text.style?.fontSize, 17);
          expect(tester.takeException(), isNull);
        }
        await GoogleFonts.pendingFonts();
      },
    );
  }

  test(
    'bundled terminal style leaves weight and italic available to callers',
    () {
      final style = resolveConfiguredMonospaceTextStyle('JetBrains Mono')!;
      expect(style.fontFamily, 'JetBrains Mono');
      expect(style.fontSize, isNull);
      expect(style.height, isNull);
      expect(style.letterSpacing, isNull);
      final boldItalic = style.copyWith(
        fontWeight: FontWeight.bold,
        fontStyle: FontStyle.italic,
      );
      expect(boldItalic.fontFamily, 'JetBrains Mono');
      expect(boldItalic.fontWeight, FontWeight.bold);
      expect(boldItalic.fontStyle, FontStyle.italic);
      // An explicit wght axis would override subsequent fontWeight changes.
      expect(boldItalic.fontVariations, isNull);
    },
  );
}
