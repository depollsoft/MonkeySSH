import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight;

import '../../app/theme.dart';
import 'acp_chat_typography.dart';
import 'highlight_nodes.dart';
import 'syntax_highlight_theme.dart';

/// Builds syntax-highlighted [TextSpan]s for a block of [code].
///
/// [language] is a highlight.js language identifier (e.g. `dart`). When it is
/// `null`, highlight.js auto-detection is used. [theme] maps highlight.js class
/// names to [TextStyle]s (see [buildSyntaxThemeFromTerminal] and the default
/// syntax themes). On any failure the whole [code] is returned as a single
/// unstyled span so rendering never throws.
List<TextSpan> buildAcpHighlightSpans(
  String code, {
  required Map<String, TextStyle> theme,
  String? language,
}) {
  try {
    final result = language != null && language.isNotEmpty
        ? highlight.parse(code, language: language)
        : highlight.parse(code, autoDetection: true);
    final nodes = result.nodes;
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
/// Colors follow the resolved app theme; syntax colors come from [syntaxTheme]
/// or a brightness-appropriate default so the block stays legible under
/// terminal-driven themes. The block never logs its content.
class AcpCodeBlock extends StatefulWidget {
  /// Creates a code block.
  const AcpCodeBlock({
    required this.code,
    super.key,
    this.language,
    this.syntaxTheme,
    this.onCopy,
  });

  /// The code to display.
  final String code;

  /// The highlight.js language identifier, or `null` to auto-detect.
  final String? language;

  /// Optional highlight.js theme map; defaults to a brightness-appropriate map.
  final Map<String, TextStyle>? syntaxTheme;

  /// Optional callback invoked (with the copied code) after a successful copy.
  final ValueChanged<String>? onCopy;

  @override
  State<AcpCodeBlock> createState() => _AcpCodeBlockState();
}

class _AcpCodeBlockState extends State<AcpCodeBlock> {
  bool _copied = false;

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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final syntaxTheme =
        widget.syntaxTheme ?? defaultAcpSyntaxTheme(theme.brightness);
    final baseStyle = AcpChatTypography.monoStyleOf(
      context,
    ).copyWith(color: scheme.onSurface, height: 1.4);
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
                child: SelectableText.rich(
                  TextSpan(
                    style: baseStyle,
                    children: buildAcpHighlightSpans(
                      widget.code,
                      theme: syntaxTheme,
                      language: language,
                    ),
                  ),
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
              style: AcpChatTypography.monoStyleOf(
                context,
              ).copyWith(fontSize: 11, color: scheme.onSurfaceVariant),
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
