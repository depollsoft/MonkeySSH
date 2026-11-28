// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/presentation/widgets/acp_chat_typography.dart';
import 'package:monkeyssh/presentation/widgets/acp_code_block.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown_paths.dart';

import '../helpers/tap_selectable_text.dart';

Iterable<TextSpan> leafSpans(
  TextSpan span, [
  TextStyle parent = const TextStyle(),
]) sync* {
  final style = parent.merge(span.style);
  if (span.text != null) {
    yield TextSpan(text: span.text, style: style, recognizer: span.recognizer);
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) yield* leafSpans(child, style);
  }
}

Widget wrap(Widget child) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

const _pngData =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

const _pngUri = 'data:image/png;base64,$_pngData';

void main() {
  setUp(() {
    FluttyTheme.debugUseSystemFonts = true;
    clearAcpInlineImageCache();
  });
  tearDown(() => FluttyTheme.debugUseSystemFonts = false);

  testWidgets('renders tables, lists and quotes without error', (tester) async {
    await tester.pumpWidget(
      wrap(
        const AcpMarkdown(
          data: '''
# Heading

- item one
- item two

> a quote

| A | B |
|---|---|
| 1 | 2 |
''',
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('item one'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
  });

  testWidgets('uses readable proportional paragraph rhythm', (tester) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: 'First paragraph.\n\nSecond paragraph.')),
    );
    await tester.pump();

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.styleSheet?.p?.fontSize, 15);
    expect(markdown.styleSheet?.p?.height, 1.45);
    expect(markdown.styleSheet?.blockSpacing, FluttyTheme.spacingSm);
    expect(
      markdown.styleSheet?.p?.fontFamily,
      isNot(FluttyTheme.monoStyle.fontFamily),
    );
    expect(
      markdown.styleSheet?.code?.fontFamily,
      FluttyTheme.monoStyle.fontFamily,
    );
  });

  testWidgets('keeps headings and explicit machine content monospaced', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '# Heading\n\nhello world')),
    );
    await tester.pump();
    var body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.selectable, isTrue);
    expect(body.styleSheet?.h1?.fontFamily, FluttyTheme.monoStyle.fontFamily);
    expect(
      body.styleSheet?.tableHead?.fontFamily,
      FluttyTheme.monoStyle.fontFamily,
    );

    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: 'literal output', machineContent: true)),
    );
    await tester.pump();
    body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.styleSheet?.p?.fontFamily, FluttyTheme.monoStyle.fontFamily);
  });

  testWidgets('renders a syntax-highlighted code block from markdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '```dart\nvoid main() {}\n```')),
    );
    await tester.pump();
    expect(find.byType(AcpCodeBlock), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
  });

  testWidgets('paints no fill around a code block outside its rounded box', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '```dart\nvoid main() {}\n```')),
    );
    await tester.pump();

    // The markdown package wraps each `pre` in a decorated container. Only the
    // code block's own rounded box may paint; a filled wrapper bleeds past it.
    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    final wrapper = body.styleSheet?.codeblockDecoration;
    expect(wrapper, isA<BoxDecoration>());
    expect((wrapper! as BoxDecoration).color, isNull);
    expect(body.styleSheet?.codeblockPadding, EdgeInsets.zero);
    final ancestors = find.ancestor(
      of: find.byType(AcpCodeBlock),
      matching: find.byType(Container),
    );
    for (final container in tester.widgetList<Container>(ancestors)) {
      final decoration = container.decoration;
      if (decoration is BoxDecoration) {
        expect(decoration.color, isNull);
      }
    }
  });

  testWidgets('copies code and shows copied state', (tester) async {
    final copied = <String>[];
    final clipboardCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardCalls.add(call);
        }
        return null;
      },
    );

    await tester.pumpWidget(
      wrap(
        AcpCodeBlock(code: 'print("hi")', language: 'dart', onCopy: copied.add),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();

    expect(copied, ['print("hi")']);
    expect(clipboardCalls, hasLength(1));
    expect((clipboardCalls.first.arguments as Map)['text'], 'print("hi")');
    expect(find.byIcon(Icons.check), findsOneWidget);

    // The copied state reverts after the timeout.
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  for (final source in ['lib/main.dart', '`lib/main.dart`']) {
    testWidgets('tapping $source opens the remote path', (tester) async {
      String? openedPath;
      await tester.pumpWidget(
        wrap(
          AcpMarkdown(
            data: source,
            onTapLink: (_, href, _) =>
                openedPath = resolveAcpMarkdownPath(href!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('lib/main.dart', findRichText: true).first);
      await tester.pump();
      expect(openedPath, 'lib/main.dart');
      expect(tester.takeException(), isNull);
    });
  }

  for (final machineContent in [false, true]) {
    testWidgets(
      'path underlines survive terminal styling, machine: $machineContent',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpChatTypography(
              monoStyle: const TextStyle(
                inherit: false,
                fontFamily: 'test-mono',
                decoration: TextDecoration.none,
              ),
              child: AcpMarkdown(
                data: 'lib/plain.dart and `lib/inline.dart`',
                machineContent: machineContent,
                onTapLink: (_, _, _) {},
              ),
            ),
          ),
        );
        final links = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .expand((text) => leafSpans(text.textSpan!))
            .where((span) => span.recognizer != null)
            .toList();
        expect(links, hasLength(2));
        for (final link in links) {
          expect(
            link.style?.decoration?.contains(TextDecoration.underline),
            isTrue,
          );
          expect(link.style?.color, FluttyTheme.dark.colorScheme.primary);
        }
        expect(links.last.style?.fontFamily, 'test-mono');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['', 'text', 'plaintext', 'sh', 'dart']) {
    testWidgets('fenced $language blocks have underlined tappable paths', (
      tester,
    ) async {
      String? opened;
      const code = 'open lib/main.dart:42';
      await tester.pumpWidget(
        wrap(
          AcpMarkdown(
            data: '```$language\n$code\n```',
            onTapLink: (_, href, _) => opened = resolveAcpMarkdownPath(href!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), code);
      final links = leafSpans(selectable.textSpan!)
          .where((span) => span.recognizer != null);
      expect(links.map((span) => span.text).join(), 'lib/main.dart');
      for (final link in links) {
        expect(
          link.style?.decoration?.contains(TextDecoration.underline),
          isTrue,
        );
      }
      await tapSelectableSubstring(tester, 'lib/main.dart');
      await tester.pump();
      expect(opened, 'lib/main.dart');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('copying a linked text block preserves its literal contents', (
    tester,
  ) async {
    const code = 'cat lib/main.dart:42\n/tmp/output.log';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      wrap(
        AcpMarkdown(
          data: '```text\n$code\n```',
          onTapLink: (_, _, _) {},
          onCopyCode: (text) => copied = text,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    expect(copied, code);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('wires custom link handler to MarkdownBody', (tester) async {
    var tappedHref = '';
    await tester.pumpWidget(
      wrap(
        AcpMarkdown(
          data: '[docs](https://example.com)',
          onTapLink: (text, href, title) => tappedHref = href ?? '',
        ),
      ),
    );
    await tester.pump();
    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.onTapLink, isNotNull);
    body.onTapLink!('docs', 'https://example.com', '');
    expect(tappedHref, 'https://example.com');
  });

  testWidgets('renders inline image embedded in markdown', (tester) async {
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '![diagram]($_pngUri)')),
    );
    await tester.pumpAndSettle();
    final image = find.byType(AcpInlineImage);
    expect(image, findsOneWidget);
    final outlinedFrames = tester
        .widgetList<DecoratedBox>(
          find.descendant(of: image, matching: find.byType(DecoratedBox)),
        )
        .where(
          (box) =>
              box.decoration is BoxDecoration &&
              (box.decoration as BoxDecoration).border != null,
        );
    expect(outlinedFrames, isEmpty);
  });

  testWidgets('keeps parsed Markdown stable across parent rebuilds', (
    tester,
  ) async {
    late StateSetter rebuildParent;
    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) {
            rebuildParent = setState;
            return const AcpMarkdown(data: '![diagram]($_pngUri)');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.widget<MarkdownBody>(find.byType(MarkdownBody));

    rebuildParent(() {});
    await tester.pump();
    final after = tester.widget<MarkdownBody>(find.byType(MarkdownBody));

    expect(identical(after, before), isTrue);
    expect(identical(after.data, before.data), isTrue);
  });

  testWidgets('rejects assistant Markdown image data above the display limit', (
    tester,
  ) async {
    final data = base64Encode(
      Uint8List(kAcpAttachmentImageDisplayMaxBytes + 1),
    );
    await tester.pumpWidget(
      wrap(AcpMarkdown(data: '![image](data:image/png;base64,$data)')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Image too large to display'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('renders a provider-wrapped inline data image', (tester) async {
    const wrappedDataUri =
        'data:image/\n'
        'png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC\n'
        'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    await tester.pumpWidget(
      wrap(const AcpMarkdown(data: '![diagram]($wrappedDataUri)')),
    );
    await tester.pump();

    expect(find.textContaining('base64'), findsNothing);
    expect(find.byType(AcpInlineImage), findsOneWidget);
  });

  test('buildAcpHighlightSpans is resilient to bad input', () {
    final spans = buildAcpHighlightSpans(
      'plain text',
      theme: defaultAcpSyntaxTheme(Brightness.dark),
    );
    expect(spans, isNotEmpty);
  });
}
