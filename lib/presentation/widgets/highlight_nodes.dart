import 'package:flutter/widgets.dart';
import 'package:highlight/highlight.dart' show Node;

/// Converts highlight.js [Node]s into styled [TextSpan]s using a highlight.js
/// class-name → [TextStyle] [theme] map.
List<TextSpan> convertHighlightNodes(
  List<Node> nodes,
  Map<String, TextStyle> theme,
) {
  final spans = <TextSpan>[];
  for (final node in nodes) {
    final className = node.className;
    final style = className != null ? theme[className] : null;
    if (node.value != null) {
      spans.add(TextSpan(text: node.value, style: style));
    } else if (node.children != null) {
      spans.add(
        TextSpan(
          style: style,
          children: convertHighlightNodes(node.children!, theme),
        ),
      );
    }
  }
  return spans;
}
