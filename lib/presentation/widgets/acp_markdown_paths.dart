import 'package:markdown/markdown.dart' as md;

import '../screens/terminal/terminal_screen_policy.dart';

const _remotePathScheme = 'monkeyssh-sftp-path';

/// Resolves generated path links and explicit Markdown file/path destinations.
///
/// Generated links carry the path separately so Windows drive letters, spaces,
/// and URI punctuation cannot change how the destination is interpreted.
String? resolveAcpMarkdownPath(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return null;
  if (uri.scheme == _remotePathScheme) {
    final path = uri.queryParameters['path'];
    return path == null || path.isEmpty ? null : path;
  }
  if (uri.scheme.toLowerCase() == 'file') {
    return resolveTerminalFileUriPath(href);
  }
  if (uri.hasScheme && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(href)) {
    return null;
  }
  final path = trimTerminalFilePathCandidate(href);
  return isSupportedTerminalFilePath(path) ? path : null;
}

/// Adds remote path anchors after normal Markdown inline parsing.
///
/// Parsing with the original document retains reference links and GFM syntax.
/// Existing links and images are left alone, and fenced code never enters the
/// inline parser. Inline code keeps its code styling inside the new anchor.
class AcpMarkdownPathSyntax extends md.InlineSyntax {
  /// Creates the native-chat path extension.
  AcpMarkdownPathSyntax() : super(r'[\s\S]+');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final inner = md.InlineParser(match[0]!, parser.document);
    inner.syntaxes.removeWhere((syntax) => syntax is AcpMarkdownPathSyntax);
    for (final node in _linkPaths(inner.parse())) {
      parser.addNode(node);
    }
    return true;
  }

  List<md.Node> _linkPaths(List<md.Node> nodes) => [
    for (final node in nodes)
      if (node is md.Text)
        ..._linkText(node.text)
      else if (node is md.Element &&
          node.tag != 'a' &&
          node.tag != 'img' &&
          node.tag != 'pre' &&
          node.children != null)
        _linkElement(node)
      else
        node,
  ];

  md.Element _linkElement(md.Element element) {
    if (element.tag == 'code') {
      // Only a path, not a command or expression, gets a code-span link.
      final text = element.textContent;
      final path = resolveAcpMarkdownPath(text);
      final matches = detectTerminalFilePaths(text);
      if (path != null &&
          matches.length == 1 &&
          matches.single.start == 0 &&
          matches.single.path == path) {
        return _anchor(path, [element]);
      }
      return element;
    }
    final children = element.children!;
    final linked = _linkPaths(children);
    children
      ..clear()
      ..addAll(linked);
    return element;
  }

  List<md.Node> _linkText(String text) {
    final nodes = <md.Node>[];
    var offset = 0;
    for (final match in detectTerminalFilePaths(text)) {
      if (match.start > offset) {
        nodes.add(md.Text(text.substring(offset, match.start)));
      }
      nodes.add(
        _anchor(match.path, [md.Text(text.substring(match.start, match.end))]),
      );
      offset = match.end;
    }
    if (offset < text.length) nodes.add(md.Text(text.substring(offset)));
    return nodes;
  }

  md.Element _anchor(String path, List<md.Node> children) =>
      md.Element('a', children)
        ..attributes['href'] = Uri(
          scheme: _remotePathScheme,
          queryParameters: {'path': path},
        ).toString();
}
