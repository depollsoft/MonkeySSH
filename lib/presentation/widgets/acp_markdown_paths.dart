import 'package:flutter/foundation.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../screens/terminal/terminal_screen_policy.dart';

const _remotePathScheme = 'monkeyssh-sftp-path';

final _windowsDrivePattern = RegExp(r'^[A-Za-z]:(?:[\\/]|%5[cC]|%2[fF])');

final _lineSuffixPattern = RegExp(r':\d+(?::\d+)?$');

/// Encodes a remote path as a native-chat link destination.
String acpMarkdownPathHref(String path) =>
    Uri(scheme: _remotePathScheme, queryParameters: {'path': path}).toString();

/// Routes taps on detected literal-text paths through a Markdown link handler.
ValueChanged<String>? acpPathTapHandler(MarkdownTapLinkCallback? onTapLink) =>
    onTapLink == null
    ? null
    : (path) => onTapLink(path, acpMarkdownPathHref(path), '');

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

/// Resolves generated path links and explicit file/path URI destinations.
///
/// Generated links carry the path separately so Windows drive letters, spaces,
/// and URI punctuation cannot change how the destination is interpreted.
/// Explicit destinations are URIs rather than prose: they are decoded once,
/// lose any query, fragment or `:line[:column]` suffix, and keep punctuation
/// that path detection would trim. Like any relative link, `main.dart` opens
/// against the session directory.
String? resolveAcpMarkdownPath(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return null;
  final String path;
  try {
    if (uri.scheme == _remotePathScheme) {
      path = uri.queryParameters['path'] ?? '';
      return path.isEmpty ? null : path;
    } else if (uri.isScheme('file')) {
      // The URI host, if any, is ignored: the path opens on the connected host.
      if (!isTerminalFileUri(uri)) return null;
      path = Uri.decodeComponent(uri.path);
    } else if (_windowsDrivePattern.hasMatch(href)) {
      path = Uri.decodeComponent('${href.substring(0, 2)}${uri.path}')
          .replaceAll(r'\', '/');
    } else if (!uri.hasScheme && !uri.hasAuthority && uri.path.isNotEmpty) {
      // A `//host/...` reference names another machine, not this host's root.
      path = Uri.decodeComponent(uri.path);
    } else {
      return null;
    }
  } on FormatException {
    return null;
  }
  final withoutLine = path.replaceFirst(_lineSuffixPattern, '');
  return withoutLine.isEmpty ? null : withoutLine;
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

  List<md.Node> _linkPaths(List<md.Node> nodes) {
    final linked = <md.Node>[];
    // package:markdown skips merging text inside a trailing element, so an
    // unmatched delimiter run (the `_` in `/srv/_data`) can split a path.
    final text = StringBuffer();
    void flushText() {
      if (text.isEmpty) return;
      linked.addAll(_linkText(text.toString()));
      text.clear();
    }

    for (final node in nodes) {
      if (node is md.Text) {
        text.write(node.text);
        continue;
      }
      flushText();
      linked.add(
        node is md.Element &&
                node.tag != 'a' &&
                node.tag != 'img' &&
                node.children != null
            ? _linkElement(node)
            : node,
      );
    }
    flushText();
    return linked;
  }

  md.Element _linkElement(md.Element element) {
    final children = element.children!;
    final linked = element.tag == 'code'
        ? _linkCodeSpan(element.textContent, [...children])
        : _linkPaths(children);
    children
      ..clear()
      ..addAll(linked);
    return element;
  }

  /// Links a code span only when it is a single path, not a command or
  /// expression. Code-span text is literal, unlike an explicit destination.
  List<md.Node> _linkCodeSpan(String text, List<md.Node> children) {
    final matches = detectAcpFilePaths(text);
    return matches.length == 1 &&
            matches.single.path == trimTerminalFilePathCandidate(text)
        ? [_anchor(matches.single.path, children)]
        : children;
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
