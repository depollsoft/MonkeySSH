import 'package:markdown/markdown.dart' as md;

import '../screens/terminal/terminal_screen_policy.dart';

const _remotePathScheme = 'monkeyssh-sftp-path';

/// Encodes a remote path as a native-chat link destination.
String acpMarkdownPathHref(String path) =>
    Uri(scheme: _remotePathScheme, queryParameters: {'path': path}).toString();

/// Detects remote paths without joining separate logical lines.
///
/// Terminal detection can reassemble visually wrapped paths. Native text has
/// real newlines, so each line must keep its own path boundaries.
List<({String path, int start, int end})> detectAcpFilePaths(String text) {
  final paths = <({String path, int start, int end})>[];
  var offset = 0;
  for (final line in text.split('\n')) {
    for (final match in detectTerminalFilePaths(line)) {
      paths.add((
        path: match.path,
        start: offset + match.start,
        end: offset + match.end,
      ));
    }
    offset += line.length + 1;
  }
  return paths;
}

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
/// inline parser. Code-span paths contain an anchor so link decoration overrides
/// the configured code style without changing its monospace face.
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
      final matches = detectAcpFilePaths(text);
      if (path != null &&
          matches.length == 1 &&
          matches.single.start == 0 &&
          matches.single.path == path) {
        final children = element.children!;
        final anchor = _anchor(path, [...children]);
        children
          ..clear()
          ..add(anchor);
        return element;
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
    for (final match in detectAcpFilePaths(text)) {
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
      md.Element('a', children)..attributes['href'] = acpMarkdownPathHref(path);
}
