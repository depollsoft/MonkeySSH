import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/syntax_highlight_controller.dart';

void main() {
  group('SyntaxHighlightController', () {
    late SyntaxHighlightController controller;

    tearDown(() {
      controller.dispose();
    });

    test('buildTextSpan returns highlighted spans for Dart code', () {
      controller = SyntaxHighlightController(
        theme: const {
          'keyword': TextStyle(color: Color(0xFFFF00FF)),
          'string': TextStyle(color: Color(0xFF00FF00)),
          'comment': TextStyle(color: Color(0xFF808080)),
        },
        text: 'void main() { print("hello"); }',
        language: 'dart',
      );

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // The span should have children (highlighted tokens), not just plain
      // text from the default controller.
      expect(span.children, isNotNull);
      expect(span.children, isNotEmpty);

      // Verify the full text reconstructed from spans matches the source.
      expect(span.toPlainText(), 'void main() { print("hello"); }');
    });

    test('buildTextSpan returns plain span for empty text', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: '',
        language: 'dart',
      );

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // Empty text should produce no children or a plain span.
      expect(span.toPlainText(), isEmpty);
    });

    test('caches result when text does not change', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'var x = 1;',
        language: 'dart',
      );

      final span1 = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      final span2 = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // On the second call the cached highlighted children are reused.
      expect(span2.children, same(span1.children));
    });

    test('uses latest base style with cached highlighted children', () {
      controller = SyntaxHighlightController(
        theme: const {
          'keyword': TextStyle(color: Color(0xFFFF00FF)),
          'string': TextStyle(color: Color(0xFF00FF00)),
        },
        text: 'void main() { print("hello"); }',
        language: 'dart',
      );

      final smallSpan = controller.buildTextSpan(
        context: _FakeBuildContext(),
        style: const TextStyle(fontSize: 12),
        withComposing: false,
      );
      final largeSpan = controller.buildTextSpan(
        context: _FakeBuildContext(),
        style: const TextStyle(fontSize: 20),
        withComposing: false,
      );

      expect(smallSpan.style!.fontSize, 12);
      expect(largeSpan.style!.fontSize, 20);
      expect(largeSpan.children, same(smallSpan.children));
      _expectChildrenDoNotSetFontSize(largeSpan, 12);
    });

    test('re-highlights after text changes', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'var x = 1;',
        language: 'dart',
      );

      // First build triggers highlighting; second assignment changes text.
      // ignore: cascade_invocations
      controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      // ignore: cascade_invocations
      controller.text = 'final y = 2;';

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(span.toPlainText(), 'final y = 2;');
    });

    test('skips highlighting for text exceeding size limit', () {
      final largeText = 'x' * (syntaxHighlightSizeLimit + 1);
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: largeText,
        language: 'dart',
      );

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );

      // Should fall through to super (plain text).
      expect(span.toPlainText(), largeText);
    });

    test('falls back to plain text on highlight failure', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'some text',
        language: 'not_a_real_language_xyz',
      );

      // Should not throw — falls back to plain text.
      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: false,
      );
      expect(span.toPlainText(), 'some text');
    });

    test('falls back to super during active IME composing', () {
      controller = SyntaxHighlightController(
        theme: const {'keyword': TextStyle(color: Color(0xFFFF00FF))},
        text: 'var x = 1;',
        language: 'dart',
      );

      // Simulate an active composing range.
      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 4, end: 9),
      );

      final span = controller.buildTextSpan(
        context: _FakeBuildContext(),
        withComposing: true,
      );

      // The plain text should still be intact (handled by super).
      expect(span.toPlainText(), 'var x = 1;');
    });
  });
}

/// Minimal fake [BuildContext] for testing [buildTextSpan] which does not
/// use the context for syntax-highlighting purposes.
class _FakeBuildContext extends Fake implements BuildContext {}

void _expectChildrenDoNotSetFontSize(TextSpan span, double fontSize) {
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) {
      expect(child.style?.fontSize, isNot(fontSize));
      _expectChildrenDoNotSetFontSize(child, fontSize);
    }
  }
}
