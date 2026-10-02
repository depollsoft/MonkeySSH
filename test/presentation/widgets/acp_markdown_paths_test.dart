// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:monkeyssh/presentation/widgets/acp_markdown_paths.dart';

List<md.Node> parse(String source) => md.Document(
  inlineSyntaxes: [AcpMarkdownPathSyntax()],
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
).parse(source);

Iterable<md.Element> elements(List<md.Node> nodes, String tag) sync* {
  for (final node in nodes.whereType<md.Element>()) {
    if (node.tag == tag) yield node;
    yield* elements(node.children ?? [], tag);
  }
}

void main() {
  for (final (source, path) in [
    ('/home/dev/project/lib/main.dart', '/home/dev/project/lib/main.dart'),
    ('~/project/', '~/project/'),
    ('./lib/main.dart', './lib/main.dart'),
    ('../lib/main.dart', '../lib/main.dart'),
    ('lib/main.dart', 'lib/main.dart'),
    ('lib/main.dart:42:3', 'lib/main.dart'),
    (r'C:\Users\dev\main.dart:12', 'C:/Users/dev/main.dart'),
    ('(/tmp/output.log).', '/tmp/output.log'),
  ]) {
    test('links $source without changing the displayed text', () {
      final nodes = parse('See $source now.');
      final links = elements(nodes, 'a').toList();
      expect(links, hasLength(1));
      expect(resolveAcpMarkdownPath(links.single.attributes['href']!), path);
      expect(nodes.single.textContent, 'See $source now.');
    });
  }

  for (final newline in ['\n', '\r\n']) {
    test(
      'native line boundaries keep separate paths, CRLF: ${newline.length == 2}',
      () {
        final text = '/tmp/output.log:42${newline}lib/main.dart';
        final paths = detectAcpFilePaths(text);
        expect(paths.map((match) => match.path), [
          '/tmp/output.log',
          'lib/main.dart',
        ]);
        expect(paths.map((match) => text.substring(match.start, match.end)), [
          '/tmp/output.log',
          'lib/main.dart',
        ]);
        final links = elements(parse(text), 'a');
        expect(
          links.map((link) => resolveAcpMarkdownPath(link.attributes['href']!)),
          ['/tmp/output.log', 'lib/main.dart'],
        );
      },
    );
  }

  test('retains inline code styling and line suffixes', () {
    final nodes = parse('Open `lib/main.dart:42` now.');
    final link = elements(nodes, 'a').single;
    expect(resolveAcpMarkdownPath(link.attributes['href']!), 'lib/main.dart');
    expect(elements(nodes, 'code').single.children!.single, same(link));
    expect(link.textContent, 'lib/main.dart:42');
  });

  test('does not link commands, expressions or fenced code', () {
    final nodes = parse('''
`cat lib/main.dart` and `value / count` and `not a path`
`https://example.com/lib/main.dart` and `mailto:dev@example.com`
`print("lib/main.dart")` and `cat lib/main.dart`

```sh
cat /tmp/output.log
```
''');
    expect(elements(nodes, 'a'), isEmpty);
    expect(elements(nodes, 'pre'), hasLength(1));
  });

  test('keeps explicit, reference and automatic URLs intact', () {
    final nodes = parse('''
[lib/main.dart](https://example.com/docs) and [`/tmp/file`](./other.dart)

[lib/main.dart][ref]

https://example.com/lib/main.dart

[ref]: https://example.com/reference
''');
    final links = elements(nodes, 'a').toList();
    expect(links.map((link) => link.attributes['href']), [
      'https://example.com/docs',
      './other.dart',
      'https://example.com/reference',
      'https://example.com/lib/main.dart',
    ]);
    for (final link in links) {
      expect(elements(link.children!, 'a'), isEmpty);
    }
  });

  test('keeps image destinations and alt text intact', () {
    final nodes = parse('![lib/main.dart](file:///tmp/image.png)');
    expect(elements(nodes, 'a'), isEmpty);
    final image = elements(nodes, 'img').single;
    expect(image.attributes['src'], 'file:///tmp/image.png');
    expect(image.attributes['alt'], 'lib/main.dart');
  });

  test('links paths inside emphasis, lists, headings and tables', () {
    final nodes = parse('''
# /tmp/header.md

- **lib/main.dart**
- */tmp/output.log*

| File |
| --- |
| `./lib/main.dart` |
''');
    expect(elements(nodes, 'a'), hasLength(4));
    expect(elements(nodes, 'strong'), hasLength(1));
    expect(elements(nodes, 'table'), hasLength(1));
  });

  for (final (href, path) in [
    ('file:///tmp/my%20file.dart:42', '/tmp/my file.dart'),
    ('file:///tmp/my%2520file.dart', '/tmp/my%20file.dart'),
    ('lib/my%20file.dart', 'lib/my file.dart'),
    ('./lib/my%20file.dart', 'lib/my file.dart'),
    ('../lib/my%20file.dart:42', '../lib/my file.dart'),
    ('/tmp/my%20file.dart', '/tmp/my file.dart'),
    ('~/my%20project/main.dart', '~/my project/main.dart'),
    ('lib/my%2520file.dart', 'lib/my%20file.dart'),
    ('lib/my%23file.dart#L42', 'lib/my#file.dart'),
    ('lib/main.dart?view=source#L42', 'lib/main.dart'),
    (r'C:\Users\dev\my%20file.dart', 'C:/Users/dev/my file.dart'),
    ('C:/Users/dev/my%20file.dart', 'C:/Users/dev/my file.dart'),
    ('C:%5CUsers%5Cdev%5Cmy%20file.dart', 'C:/Users/dev/my file.dart'),
    (
      'C:/Users/dev/my%20file.dart?view=source#L42',
      'C:/Users/dev/my file.dart',
    ),
  ]) {
    test('decodes explicit Markdown destination $href exactly once', () {
      expect(resolveAcpMarkdownPath(href), path);
      final anchor = elements(parse('[source]($href)'), 'a').single;
      expect(resolveAcpMarkdownPath(anchor.attributes['href']!), path);
    });
  }

  for (final source in ['/tmp/my%20file.dart', '`/tmp/my%20file.dart`']) {
    test('preserves literal percent escapes in detected path $source', () {
      final anchor = elements(parse(source), 'a').single;
      expect(
        resolveAcpMarkdownPath(anchor.attributes['href']!),
        '/tmp/my%20file.dart',
      );
    });
  }

  test('ignores invalid UTF-8 in a percent-encoded path', () {
    expect(resolveAcpMarkdownPath('lib/%FF.dart'), isNull);
    expect(resolveAcpMarkdownPath('file:///tmp/%FF.dart'), isNull);
  });

  test('resolves file URLs and relative Markdown destinations', () {
    expect(resolveAcpMarkdownPath('file:///tmp/a%20b.txt'), '/tmp/a b.txt');
    expect(resolveAcpMarkdownPath('lib/main.dart:12'), 'lib/main.dart');
    expect(resolveAcpMarkdownPath('~/project'), '~/project');
    expect(
      resolveAcpMarkdownPath(r'C:\Users\dev\main.dart'),
      'C:/Users/dev/main.dart',
    );
  });

  test('does not route external or unsupported schemes to SFTP', () {
    for (final href in [
      'https://example.com/lib/main.dart',
      'mailto:dev@example.com',
      'javascript:alert(1)',
      'data:text/plain,/tmp/file',
      '#heading',
      '',
      'monkeyssh-sftp-path:',
      'file:',
      'file://remote-host',
    ]) {
      expect(resolveAcpMarkdownPath(href), isNull, reason: href);
    }
  });
}
