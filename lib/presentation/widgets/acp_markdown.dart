import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_chat_typography.dart';
import 'acp_code_block.dart';
import 'acp_inline_image.dart';
import 'acp_markdown_data_images.dart';
import 'acp_markdown_paths.dart';

/// URL schemes that [AcpMarkdown] will open by default.
const _allowedLinkSchemes = {'http', 'https', 'mailto', 'tel'};

/// Safely opens [href] if it uses an allowed scheme.
///
/// Unsupported or malformed links are ignored rather than launched, so tapping
/// a link can never trigger an arbitrary intent.
Future<void> launchAcpLink(String? href) async {
  if (href == null || href.isEmpty) {
    return;
  }
  final uri = Uri.tryParse(href);
  if (uri == null || !_allowedLinkSchemes.contains(uri.scheme.toLowerCase())) {
    return;
  }
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Renders assistant Markdown with selectable text, safe links, tables, lists,
/// blockquotes, inline images, and syntax-highlighted code blocks that expose a
/// copy action.
///
/// All colors are derived from the resolved [Theme] so the content follows the
/// active (including terminal-driven) palette. Code blocks reuse the shared
/// highlight utilities via [AcpCodeBlock]. Links are opened through
/// [launchAcpLink] unless a custom [onTapLink] is supplied.
class AcpMarkdown extends StatefulWidget {
  /// Creates a Markdown renderer.
  const AcpMarkdown({
    required this.data,
    super.key,
    this.selectable = true,
    this.onTapLink,
    this.imageResolver,
    this.onTapImage,
    this.onCopyCode,
    this.syntaxTheme,
    this.machineContent = false,
  });

  /// The Markdown source to render.
  final String data;

  /// Whether text is selectable.
  final bool selectable;

  /// Custom link tap handler; defaults to [launchAcpLink].
  final MarkdownTapLinkCallback? onTapLink;

  /// Resolver for non-inline images embedded in the Markdown.
  final AcpImageResolver? imageResolver;

  /// Called when an inline image is tapped.
  final ValueChanged<AcpImageContent>? onTapImage;

  /// Called after a code block's contents are copied.
  final ValueChanged<String>? onCopyCode;

  /// Optional highlight.js theme map for code blocks.
  final Map<String, TextStyle>? syntaxTheme;

  /// Keeps prose in the terminal monospace face for literal tool output.
  ///
  /// Assistant explanations default to the proportional UI body face while
  /// code, headings, paths, and explicitly machine-authored content stay mono.
  final bool machineContent;

  @override
  State<AcpMarkdown> createState() => _AcpMarkdownState();
}

class _AcpMarkdownState extends State<AcpMarkdown> {
  late String _normalizedData;
  late Widget _body;

  @override
  void initState() {
    super.initState();
    _normalizedData = normalizeAcpMarkdownDataImages(widget.data);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _body = _buildMarkdownBody(context);
  }

  @override
  void didUpdateWidget(AcpMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _normalizedData = normalizeAcpMarkdownDataImages(widget.data);
    }
    if (oldWidget.data != widget.data ||
        oldWidget.selectable != widget.selectable ||
        oldWidget.onTapLink != widget.onTapLink ||
        oldWidget.imageResolver != widget.imageResolver ||
        oldWidget.onTapImage != widget.onTapImage ||
        oldWidget.onCopyCode != widget.onCopyCode ||
        oldWidget.syntaxTheme != widget.syntaxTheme ||
        oldWidget.machineContent != widget.machineContent) {
      _body = _buildMarkdownBody(context);
    }
  }

  Widget _buildMarkdownBody(BuildContext context) {
    final machineContent = widget.machineContent;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = MarkdownStyleSheet.fromTheme(theme);
    TextStyle mono({
      double fontSize = 13,
      FontWeight fontWeight = FontWeight.w400,
      Color? color,
      FontStyle? fontStyle,
      TextDecoration? decoration,
    }) => AcpChatTypography.monoStyleOf(context).copyWith(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? scheme.onSurface,
      fontStyle: fontStyle,
      decoration: decoration,
      height: 1.4,
    );
    TextStyle prose({
      double fontSize = 15,
      FontWeight? fontWeight,
      Color? color,
      FontStyle? fontStyle,
      TextDecoration? decoration,
    }) => (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? scheme.onSurface,
      fontStyle: fontStyle,
      decoration: decoration,
      height: 1.45,
    );
    final body = machineContent ? mono() : prose();
    final link = machineContent
        ? mono(color: scheme.primary, decoration: TextDecoration.underline)
        : prose(color: scheme.primary, decoration: TextDecoration.underline);
    final styleSheet = base.copyWith(
      blockSpacing: FluttyTheme.spacingSm,
      p: body,
      a: link.copyWith(decorationColor: scheme.primary),
      code: mono().copyWith(
        color: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
      h1: mono(fontSize: 20, fontWeight: FontWeight.w700),
      h2: mono(fontSize: 18, fontWeight: FontWeight.w700),
      h3: mono(fontSize: 16, fontWeight: FontWeight.w600),
      h4: mono(fontWeight: FontWeight.w600),
      h5: mono(fontWeight: FontWeight.w600),
      h6: mono(fontWeight: FontWeight.w600),
      em: machineContent
          ? mono(fontStyle: FontStyle.italic)
          : prose(fontStyle: FontStyle.italic),
      strong: machineContent
          ? mono(fontWeight: FontWeight.w700)
          : prose(fontWeight: FontWeight.w700),
      del: machineContent
          ? mono(decoration: TextDecoration.lineThrough)
          : prose(decoration: TextDecoration.lineThrough),
      blockquote: machineContent
          ? mono(color: scheme.onSurfaceVariant)
          : prose(color: scheme.onSurfaceVariant),
      img: body,
      checkbox: body.copyWith(color: scheme.primary),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
      ),
      blockquotePadding: const EdgeInsets.all(FluttyTheme.spacingSm),
      listBullet: body,
      tableBorder: TableBorder.all(color: scheme.outline),
      tableHead: mono(fontWeight: FontWeight.w600),
      tableBody: machineContent ? mono() : prose(fontSize: 14),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
    );

    return MarkdownBody(
      data: _normalizedData,
      selectable: widget.selectable,
      styleSheet: styleSheet,
      softLineBreak: true,
      inlineSyntaxes: [if (widget.onTapLink != null) AcpMarkdownPathSyntax()],
      onTapLink: widget.onTapLink ?? _defaultOnTapLink,
      imageBuilder: _buildImage,
      builders: {
        'pre': _AcpCodeBlockBuilder(
          syntaxTheme: widget.syntaxTheme,
          onCopy: widget.onCopyCode,
        ),
      },
    );
  }

  @override
  Widget build(BuildContext context) => _body;

  void _defaultOnTapLink(String text, String? href, String title) {
    unawaited(launchAcpLink(href));
  }

  Widget _buildImage(Uri uri, String? title, String? alt) => Padding(
    padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
    child: AcpInlineImage(
      image: AcpImageContent(uri: uri.toString(), label: alt ?? title),
      resolver: widget.imageResolver,
      onTap: widget.onTapImage,
    ),
  );
}

class _AcpCodeBlockBuilder extends MarkdownElementBuilder {
  _AcpCodeBlockBuilder({this.syntaxTheme, this.onCopy});

  final Map<String, TextStyle>? syntaxTheme;
  final ValueChanged<String>? onCopy;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String? language;
    final children = element.children;
    if (children != null && children.isNotEmpty) {
      final first = children.first;
      if (first is md.Element) {
        final className = first.attributes['class'];
        if (className != null && className.startsWith('language-')) {
          language = className.substring('language-'.length);
        }
      }
    }
    var code = element.textContent;
    if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
      child: AcpCodeBlock(
        code: code,
        language: language,
        syntaxTheme: syntaxTheme,
        onCopy: onCopy,
      ),
    );
  }
}
