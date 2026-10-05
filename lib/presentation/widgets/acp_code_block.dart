import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight;

import '../../app/theme.dart';
import 'acp_chat_typography.dart';
import 'acp_path_text.dart';
import 'highlight_nodes.dart';
import 'syntax_highlight_controller.dart' show syntaxHighlightSizeLimit;
import 'syntax_highlight_theme.dart';

/// Builds syntax-highlighted [TextSpan]s for a block of [code].
///
/// [language] is a highlight.js language identifier (e.g. `dart`). When it is
/// `null` or empty the code is rendered as plain text: auto-detection would run
/// every registered grammar over the text on the UI isolate. Code longer than
/// [syntaxHighlightSizeLimit] is also left plain. [theme] maps highlight.js
/// class names to [TextStyle]s. On any failure the whole [code] is returned as
/// a single unstyled span so rendering never throws.
List<TextSpan> buildAcpHighlightSpans(
  String code, {
  required Map<String, TextStyle> theme,
  String? language,
}) {
  if (language == null ||
      language.isEmpty ||
      code.length > syntaxHighlightSizeLimit) {
    return [TextSpan(text: code)];
  }
  try {
    final nodes = highlight.parse(code, language: language).nodes;
    if (nodes == null || nodes.isEmpty) {
      return [TextSpan(text: code)];
    }
    return convertHighlightNodes(nodes, theme);
  } on Object {
    return [TextSpan(text: code)];
  }
}

/// Resolves a sensible default syntax theme for the current [brightness].
Map<String, TextStyle> defaultAcpSyntaxTheme(Brightness brightness) =>
    brightness == Brightness.dark
    ? defaultDarkSyntaxTheme
    : defaultLightSyntaxTheme;

/// A read-only, syntax-highlighted, horizontally scrollable code block with a
/// copy action.
///
/// Colors follow the resolved app theme; syntax colors come from a
/// brightness-appropriate default so the block stays legible under
/// terminal-driven themes. The block never logs its content.
class AcpCodeBlock extends StatefulWidget {
  /// Creates a code block.
  const AcpCodeBlock({
    required this.code,
    super.key,
    this.language,
    this.onCopy,
    this.onTapPath,
  });

  /// The code to display.
  final String code;

  /// The highlight.js language identifier, or `null` for plain text.
  final String? language;

  /// Optional callback invoked (with the copied code) after a successful copy.
  final ValueChanged<String>? onCopy;

  /// Opens detected remote paths within the literal block text.
  final ValueChanged<String>? onTapPath;

  @override
  State<AcpCodeBlock> createState() => _AcpCodeBlockState();
}

class _AcpCodeBlockState extends State<AcpCodeBlock> {
  bool _copied = false;
  // Highlighting is tokenised once per (code, language, brightness) so the
  // copied badge, theme refreshes and unrelated ancestor rebuilds cost nothing.
  Brightness? _brightness;
  late List<TextSpan> _spans;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (brightness != _brightness) {
      _brightness = brightness;
      _spans = _highlight(brightness);
    }
  }

  @override
  void didUpdateWidget(AcpCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.language != widget.language) {
      _spans = _highlight(_brightness!);
    }
  }

  List<TextSpan> _highlight(Brightness brightness) => buildAcpHighlightSpans(
    widget.code,
    theme: defaultAcpSyntaxTheme(brightness),
    language: widget.language,
  );

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    widget.onCopy?.call(widget.code);
    if (!mounted) {
      return;
    }
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() => _copied = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseStyle = AcpChatTypography.monoStyleOf(context)
        .copyWith(color: scheme.onSurface, height: 1.4);
    final language = widget.language;

    return Semantics(
      label: language != null && language.isNotEmpty
          ? 'Code block, $language'
          : 'Code block',
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
          border: Border.all(color: scheme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _CodeBlockHeader(
              language: language,
              copied: _copied,
              onCopy: _copy,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingMd,
                FluttyTheme.spacingSm,
                FluttyTheme.spacingMd,
                FluttyTheme.spacingMd,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: AcpPathText(
                  text: widget.code,
                  style: baseStyle,
                  spans: _spans,
                  onTapPath: widget.onTapPath,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CodeBlockHeader extends StatelessWidget {
  const _CodeBlockHeader({
    required this.language,
    required this.copied,
    required this.onCopy,
  });

  final String? language;
  final bool copied;
  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingSm,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              language != null && language!.isNotEmpty ? language! : 'text',
              style: AcpChatTypography.monoStyleOf(context)
                  .copyWith(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          Tooltip(
            message: copied ? 'Copied' : 'Copy code',
            child: InkWell(
              onTap: onCopy,
              borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
              child: Padding(
                padding: const EdgeInsets.all(FluttyTheme.spacingSm),
                child: Icon(
                  copied ? Icons.check : Icons.copy_rounded,
                  size: 18,
                  color: copied ? scheme.primary : scheme.onSurfaceVariant,
                  semanticLabel: copied ? 'Copied' : 'Copy code',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
