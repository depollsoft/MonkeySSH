import 'package:flutter/widgets.dart';
import 'package:highlight/highlight.dart' show highlight;

import 'highlight_nodes.dart';

/// Maximum text length (in characters) for which syntax highlighting is
/// applied.
///
/// Files larger than this threshold are rendered as plain text to avoid
/// frame-rate drops caused by the highlighting pass inside [buildTextSpan].
///
/// The SFTP screen gates on the raw byte length before creating the
/// controller; this character-based guard is a secondary safety net inside
/// [SyntaxHighlightController.buildTextSpan].
const syntaxHighlightSizeLimit = 100 * 1024; // 100 K characters

/// A [TextEditingController] that produces syntax-highlighted [TextSpan]s.
///
/// Uses the `highlight` package to tokenize the controller text and maps
/// highlight.js CSS class names to [TextStyle]s via the supplied [theme] map.
///
/// Highlighting is automatically skipped when the text exceeds
/// [syntaxHighlightSizeLimit] characters.
class SyntaxHighlightController extends TextEditingController {
  /// Creates a [SyntaxHighlightController].
  ///
  /// [theme] maps highlight.js class names (e.g. `'keyword'`, `'string'`) to
  /// [TextStyle]s.  The special `'root'` key provides the base text style.
  ///
  /// [language] is the highlight.js language identifier (e.g. `'dart'`).
  /// When `null`, `highlight.parse` attempts auto-detection.
  SyntaxHighlightController({required this.theme, super.text, this.language});

  /// The highlight.js language name, or `null` for auto-detection.
  final String? language;

  /// Highlight.js theme map (class name → [TextStyle]).
  final Map<String, TextStyle> theme;

  // Cached highlight children keyed on the raw text value so base styles can
  // change without re-tokenizing unchanged text.
  String? _cachedText;
  List<TextSpan>? _cachedChildren;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    // ignore: always_put_required_named_parameters_first
    required bool withComposing,
  }) {
    final source = text;

    // During active IME composing, fall back to the default controller so
    // the composing underline decoration is preserved.
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    // Skip highlighting for empty or oversized text.
    if (source.isEmpty || source.length > syntaxHighlightSizeLimit) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    // Return cached result when the text has not changed.
    final cachedChildren = _cachedChildren;
    if (source == _cachedText && cachedChildren != null) {
      return TextSpan(style: style, children: cachedChildren);
    }

    try {
      final result = highlight.parse(source, language: language);
      final nodes = result.nodes;
      if (nodes == null || nodes.isEmpty) {
        return super.buildTextSpan(
          context: context,
          style: style,
          withComposing: withComposing,
        );
      }

      final highlightedChildren = convertHighlightNodes(nodes, theme);
      final highlighted = TextSpan(style: style, children: highlightedChildren);

      _cachedText = source;
      _cachedChildren = highlightedChildren;
      return highlighted;
    } on Object {
      // If the highlighter fails for any reason, fall through to plain text.
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
  }
}
