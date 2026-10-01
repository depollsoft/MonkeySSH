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

  test('retains inline code styling and line suffixes', () {
    final nodes = parse('Open `lib/main.dart:42` now.');
    final link = elements(nodes, 'a').single;
    expect(resolveAcpMarkdownPath(link.attributes['href']!), 'lib/main.dart');
    expect(link.children!.single, isA<md.Element>());
    expect((link.children!.single as md.Element).tag, 'code');
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
    ]) {
      expect(resolveAcpMarkdownPath(href), isNull, reason: href);
    }
  });
}
