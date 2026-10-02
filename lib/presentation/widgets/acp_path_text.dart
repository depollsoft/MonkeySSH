import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'acp_markdown_paths.dart';

/// Selectable literal text with underlined remote paths, without Markdown parsing.
///
/// Optional highlight spans retain their syntax styles outside paths. Detection
/// runs on the complete text so paths can cross highlight-token boundaries.
class AcpPathText extends StatefulWidget {
  /// Creates literal native-chat text with optional remote path actions.
  const AcpPathText({
    required this.text,
    super.key,
    this.style,
    this.spans,
    this.onTapPath,
  });

  /// Literal text to display and copy through text selection.
  final String text;

  /// Base text style.
  final TextStyle? style;

  /// Optional syntax-highlighted spans representing [text].
  final List<TextSpan>? spans;

  /// Opens a detected remote path. Null leaves paths undecorated and inert.
  final ValueChanged<String>? onTapPath;

  @override
  State<AcpPathText> createState() => _AcpPathTextState();
}

class _AcpPathTextState extends State<AcpPathText> {
  List<({String path, int start, int end})> _paths = [];
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _syncPaths();
  }

  @override
  void didUpdateWidget(AcpPathText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        (oldWidget.onTapPath == null) != (widget.onTapPath == null)) {
      _syncPaths();
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _syncPaths() {
    _disposeRecognizers();
    _paths = widget.onTapPath == null ? [] : detectAcpFilePaths(widget.text);
    for (final path in _paths) {
      _recognizers.add(
        TapGestureRecognizer()..onTap = () => widget.onTapPath?.call(path.path),
      );
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spans = widget.spans ?? [TextSpan(text: widget.text)];
    if (_paths.isEmpty) {
      if (widget.spans == null) {
        return SelectableText(widget.text, style: widget.style);
      }
      return SelectableText.rich(
        TextSpan(style: widget.style, children: spans),
      );
    }
    final color = Theme.of(context).colorScheme.primary;
    final linked = <TextSpan>[];
    var offset = 0;
    var pathIndex = 0;

    void append(TextSpan span, TextStyle parentStyle) {
      final style = parentStyle.merge(span.style);
      final text = span.text;
      if (text != null) {
        var start = 0;
        while (start < text.length) {
          while (pathIndex < _paths.length &&
              _paths[pathIndex].end <= offset + start) {
            pathIndex++;
          }
          final path = pathIndex < _paths.length ? _paths[pathIndex] : null;
          final isLink = path != null && path.start <= offset + start;
          final boundary = path == null
              ? text.length
              : (isLink ? path.end : path.start) - offset;
          final end = boundary.clamp(start + 1, text.length);
          linked.add(
            TextSpan(
              text: text.substring(start, end),
              style: isLink
                  ? style.copyWith(
                      color: color,
                      decoration: TextDecoration.combine([
                        if (style.decoration != null) style.decoration!,
                        TextDecoration.underline,
                      ]),
                      decorationColor: color,
                    )
                  : style,
              recognizer: isLink ? _recognizers[pathIndex] : null,
              mouseCursor: isLink ? SystemMouseCursors.click : null,
            ),
          );
          start = end;
        }
        offset += text.length;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (child is TextSpan) append(child, style);
      }
    }

    for (final span in spans) {
      append(span, widget.style ?? const TextStyle());
    }
    return SelectableText.rich(TextSpan(children: linked));
  }
}
