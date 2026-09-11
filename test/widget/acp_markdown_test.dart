// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_code_block.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/cursor_block.dart';

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

Uint8List _displayedImageBytes(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  return ((image.image as ResizeImage).imageProvider as MemoryImage).bytes;
}

Future<void> _pumpImage(
  WidgetTester tester,
  AcpImageContent image, {
  AcpImageResolver? resolver,
}) async {
  await tester.pumpWidget(
    wrap(AcpInlineImage(image: image, resolver: resolver)),
  );
  await tester.pumpAndSettle();
}

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

  testWidgets('reuses data-image decode across remounts', (tester) async {
    final image = AcpImageContent(uri: _pngUri, label: 'diagram');

    await tester.pumpWidget(wrap(AcpInlineImage(image: image)));
    await tester.pumpAndSettle();
    expect(acpInlineDataImageDecodeCount, 1);
    expect(acpInlineImageCacheEntryCount, 1);

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(wrap(AcpInlineImage(image: image)));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpAndSettle();

    expect(acpInlineDataImageDecodeCount, 1);
    expect(acpInlineImageCacheEntryCount, 1);
  });

  for (final changeResolver in [false, true]) {
    testWidgets(
      'resolves file images again on remount, new resolver: $changeResolver',
      (tester) async {
        var firstCalls = 0;
        var secondCalls = 0;
        final firstBytes = base64Decode(_pngData);
        final secondBytes = Uint8List.fromList([...firstBytes, 0]);
        var currentBytes = firstBytes;
        final image = AcpImageContent(uri: 'file:///tmp/result.png');
        Future<Uint8List?> firstResolver(AcpImageContent _) async {
          firstCalls++;
          return currentBytes;
        }

        Future<Uint8List?> secondResolver(AcpImageContent _) async {
          secondCalls++;
          return secondBytes;
        }

        // Rebuilding a mounted image must not trigger another remote read.
        for (var frame = 0; frame < 2; frame++) {
          await _pumpImage(tester, image, resolver: firstResolver);
          expect(_displayedImageBytes(tester), firstBytes);
          expect(firstCalls, 1);
          expect(acpInlineImageCacheEntryCount, 0);
        }
        await tester.pumpWidget(wrap(const SizedBox.shrink()));
        currentBytes = secondBytes;
        await _pumpImage(
          tester,
          image,
          resolver: changeResolver ? secondResolver : firstResolver,
        );

        expect(firstCalls, changeResolver ? 1 : 2);
        expect(secondCalls, changeResolver ? 1 : 0);
        expect(_displayedImageBytes(tester), secondBytes);
        expect(acpInlineImageCacheEntryCount, 0);
      },
    );
  }

  testWidgets(
    'malformed inline data resolves its original URI without caching remote bytes',
    (tester) async {
      final bytes = base64Decode(_pngData);
      final image = AcpImageContent(
        dataUri: 'data:image/png;base64,not-base64!!!',
        uri: 'file:///tmp/fallback.png',
      );
      var calls = 0;
      Future<Uint8List?> resolve(AcpImageContent fallback) async {
        calls++;
        expect(fallback.uri, image.uri);
        expect(fallback.sourceKind, AcpImageSourceKind.fileUri);
        return bytes;
      }

      await _pumpImage(tester, image, resolver: resolve);
      expect(_displayedImageBytes(tester), bytes);
      expect(calls, 1);
      expect(acpInlineImageCacheEntryCount, 0);
    },
  );

  testWidgets(
    'encoded image cache follows data even when the original URI is unchanged',
    (tester) async {
      final bytes = base64Decode(_pngData);
      for (final payload in [
        bytes,
        Uint8List.fromList([...bytes, 0]),
      ]) {
        await _pumpImage(
          tester,
          AcpImageContent(
            dataUri: 'data:image/png;base64,${base64Encode(payload)}',
            uri: 'file:///tmp/result.png',
          ),
        );
        expect(_displayedImageBytes(tester), payload);
      }
      expect(acpInlineDataImageDecodeCount, 2);
      expect(acpInlineImageCacheEntryCount, 2);
    },
  );

  for (final size in [6 * 1024 * 1024, kAcpAttachmentImageDisplayMaxBytes]) {
    testWidgets('decodes a $size byte data image through the worker', (
      tester,
    ) async {
      final png = base64Decode(_pngData);
      // Trailing PNG bytes exercise the worker limit without a huge bitmap.
      final bytes = Uint8List(size)..setRange(0, png.length, png);
      final image = AcpImageContent(
        dataUri: 'data:image/png;base64,${base64Encode(bytes)}',
        uri: 'attachment://local/large.png',
      );
      var resolveCalls = 0;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: image,
              resolver: (_) async {
                resolveCalls++;
                return null;
              },
            ),
          ),
        );
        for (
          var attempt = 0;
          attempt < 200 && find.byType(Image).evaluate().isEmpty;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(find.text('Image too large to display'), findsNothing);
      expect(_displayedImageBytes(tester).length, size);
      expect(acpInlineDataImageDecodeCount, 1);
      expect(resolveCalls, 0);
    });
  }

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

  testWidgets('streaming assistant leaves cursor to chat viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AcpMessageThread(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          entries: [
            AcpAssistantMessageEntry(
              id: 'a1',
              markdown: 'thinking',
              status: AcpStreamStatus.streaming,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CursorBlock), findsNothing);
  });

  testWidgets('completed assistant message has no cursor block', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AcpMessageThread(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          entries: [AcpAssistantMessageEntry(id: 'a1', markdown: 'done')],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CursorBlock), findsNothing);
  });

  testWidgets('buildAcpHighlightSpans is resilient to bad input', (
    tester,
  ) async {
    final spans = buildAcpHighlightSpans(
      'plain text',
      theme: defaultAcpSyntaxTheme(Brightness.dark),
    );
    expect(spans, isNotEmpty);
  });
}
