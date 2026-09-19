// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_code_block.dart';
import 'package:monkeyssh/presentation/widgets/acp_diff.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_markdown.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_chip.dart';
import 'package:monkeyssh/presentation/widgets/acp_thought.dart';
import 'package:monkeyssh/presentation/widgets/acp_tool_call.dart';

import 'acp_attachment_strip_cases.dart';
import 'acp_concurrency_choice_cases.dart';
import 'acp_config_option_controls_cases.dart';
import 'acp_native_starting_view_cases.dart';
import 'acp_permission_surface_cases.dart';
import 'acp_slash_command_picker_cases.dart';

final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget wrap(Widget child) => MaterialApp(
  theme: FluttyTheme.dark,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

// Pumps enough frames for the async header-inspection (ImageDescriptor) flow
// to settle to a ready/error state.
Future<void> settleImage(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

int _pngCrc(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

List<int> _pngChunk(String type, List<int> data) {
  final body = [...type.codeUnits, ...data];
  return [..._be32(data.length), ...body, ..._be32(_pngCrc(body))];
}

// Builds a structurally valid PNG whose IHDR declares [w]x[h]; the pixel data
// is intentionally minimal so only the header dimensions are meaningful.
Uint8List buildPng(int w, int h) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ..._pngChunk('IHDR', [..._be32(w), ..._be32(h), 8, 6, 0, 0, 0]),
  ..._pngChunk('IDAT', [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]),
  ..._pngChunk('IEND', const []),
]);

void main() {
  group('acp_components', () {
    setUp(() {
      FluttyTheme.debugUseSystemFonts = true;
      clearAcpInlineImageCache();
    });
    tearDown(() => FluttyTheme.debugUseSystemFonts = false);

    group('AcpToolCallView', () {
      testWidgets('renders every status with an icon and label', (
        tester,
      ) async {
        const expectations = {
          AcpToolStatus.pending: ('Pending', Icons.schedule),
          AcpToolStatus.running: ('Running', Icons.sync),
          AcpToolStatus.completed: ('Completed', Icons.check_circle_outline),
          AcpToolStatus.failed: ('Failed', Icons.error_outline),
          AcpToolStatus.cancelled: ('Cancelled', Icons.cancel_outlined),
        };
        for (final entry in expectations.entries) {
          await tester.pumpWidget(
            wrap(
              AcpToolCallView(
                toolCall: AcpToolCall(
                  id: '1',
                  title: 'Run tests',
                  status: entry.key,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text(entry.value.$1), findsOneWidget);
          expect(find.byIcon(entry.value.$2), findsOneWidget);
          final height = tester.getSize(find.byType(AcpToolCallView)).height;
          if (entry.key == AcpToolStatus.pending ||
              entry.key == AcpToolStatus.running) {
            expect(find.textContaining('result: …'), findsOneWidget);
            expect(height, greaterThan(44));
          } else {
            expect(height, closeTo(44, 0.1));
          }
        }
      });

      testWidgets('expands to show input and output', (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpToolCallView(
              toolCall: AcpToolCall(
                id: '1',
                title: 'Read file',
                status: AcpToolStatus.completed,
                rawInput: 'path: pubspec.yaml',
                rawOutput: 'name: monkeyssh',
              ),
            ),
          ),
        );
        await tester.pump();
        // Collapsed initially.
        expect(find.textContaining('input:'), findsNothing);

        await tester.tap(find.text('Read file'));
        await tester.pump();
        expect(
          find.textContaining(
            'input:\n  path: pubspec.yaml\nresult:\n  name: monkeyssh',
          ),
          findsOneWidget,
        );
      });

      testWidgets(
        'streams active calls and collapses each one as it finishes',
        (tester) async {
          Widget build(AcpToolStatus firstStatus, {String? firstOutput}) =>
              wrap(
                Column(
                  children: [
                    AcpToolCallView(
                      key: const ValueKey('first-tool'),
                      toolCall: AcpToolCall(
                        id: 'first',
                        title: 'Search files',
                        status: firstStatus,
                        rawInput: 'query: TODO',
                        rawOutput: firstOutput,
                      ),
                    ),
                    AcpToolCallView(
                      key: const ValueKey('second-tool'),
                      toolCall: AcpToolCall(
                        id: 'second',
                        title: 'Run tests',
                        status: AcpToolStatus.running,
                        rawInput: 'command: flutter test',
                      ),
                    ),
                  ],
                ),
              );

          await tester.pumpWidget(build(AcpToolStatus.running));
          // Active tools show a compact header preview plus their expanded payload.
          expect(find.textContaining('query: TODO'), findsNWidgets(2));
          expect(
            find.textContaining('command: flutter test'),
            findsNWidgets(2),
          );
          expect(find.textContaining('result: …'), findsNWidgets(2));

          await tester.pumpWidget(
            build(AcpToolStatus.running, firstOutput: 'matches: 3'),
          );
          await tester.pump();
          expect(find.textContaining('matches: 3'), findsOneWidget);
          expect(find.textContaining('result: …'), findsOneWidget);

          await tester.pumpWidget(
            build(AcpToolStatus.completed, firstOutput: 'matches: 3'),
          );
          await tester.pump();
          expect(find.textContaining('matches: 3'), findsNothing);
          expect(find.textContaining('query: TODO'), findsOneWidget);
          expect(
            find.textContaining('command: flutter test'),
            findsNWidgets(2),
          );

          await tester.tap(find.text('Search files'));
          await tester.pump();
          expect(find.textContaining('matches: 3'), findsOneWidget);
        },
      );

      testWidgets('bounds live output to a recent repaint window', (
        tester,
      ) async {
        final output = List.generate(
          200,
          (index) => 'line $index ${'x' * 80}',
        ).join('\n');
        await tester.pumpWidget(
          wrap(
            AcpToolCallView(
              toolCall: AcpToolCall(
                id: 'stream',
                title: 'Long-running command',
                status: AcpToolStatus.running,
                rawOutput: output,
              ),
            ),
          ),
        );
        await tester.pump();

        final streamText = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .single
            .data!;
        expect(streamText.length, lessThan(5000));
        expect(streamText, startsWith('result:\n  …'));
        expect(streamText, contains('line 199'));
        expect(streamText, isNot(contains('line 0 ')));
      });

      testWidgets('renders locations and fires open callback', (tester) async {
        AcpToolLocation? opened;
        await tester.pumpWidget(
          wrap(
            AcpToolCallView(
              initiallyExpanded: true,
              onOpenLocation: (loc) => opened = loc,
              toolCall: AcpToolCall(
                id: '1',
                title: 'Edit',
                status: AcpToolStatus.completed,
                locations: const [
                  AcpToolLocation(path: 'lib/main.dart', line: 42),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        // The collapsed-density preview and expanded location row share the
        // same useful target text; the latter remains independently tappable.
        expect(find.text('lib/main.dart:42'), findsNWidgets(2));
        await tester.tap(find.text('lib/main.dart:42').last);
        expect(opened?.path, 'lib/main.dart');
        expect(opened?.line, 42);
      });

      testWidgets('keeps YAML list output monospaced instead of Markdown', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpToolCallView(
              initiallyExpanded: true,
              toolCall: AcpToolCall(
                id: 'yaml',
                title: 'Batch',
                status: AcpToolStatus.completed,
                rawOutput: 'calls:\n  - tool: grep\n    status: completed',
                rawOutputIsStructured: true,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(AcpMarkdown), findsNothing);
        expect(find.textContaining('tool: grep'), findsOneWidget);
      });

      testWidgets('renders rich Markdown and fenced code tool results', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpToolCallView(
              initiallyExpanded: true,
              toolCall: AcpToolCall(
                id: 'rich',
                title: 'Analyze',
                status: AcpToolStatus.completed,
                rawOutput:
                    '''
**Summary**

```dart
void main() {}
```
'''
                        .trim(),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(AcpMarkdown), findsOneWidget);
        expect(find.byType(AcpCodeBlock), findsOneWidget);
        expect(find.text('Summary'), findsOneWidget);
        expect(find.textContaining('void main()'), findsOneWidget);
      });

      testWidgets('renders a unified diff inside a tool call', (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpToolCallView(
              initiallyExpanded: true,
              toolCall: AcpToolCall(
                id: '1',
                title: 'Apply patch',
                kind: AcpToolKind.edit,
                status: AcpToolStatus.completed,
                diffs: const [
                  AcpDiff(
                    path: 'lib/a.dart',
                    unifiedDiff:
                        '@@ -1,2 +1,2 @@\n-old line\n+new line\n context',
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(AcpDiffView), findsOneWidget);
        expect(find.text('-old line'), findsOneWidget);
        expect(find.text('+new line'), findsOneWidget);
      });
    });

    group('AcpDiffView', () {
      testWidgets('shows path header and diff lines', (tester) async {
        await tester.pumpWidget(
          wrap(
            const AcpDiffView(
              diff: AcpDiff(
                path: 'src/file.ts',
                unifiedDiff: '@@ -1 +1 @@\n-a\n+b',
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('src/file.ts'), findsOneWidget);
        expect(find.text('-a'), findsOneWidget);
        expect(find.text('+b'), findsOneWidget);
      });
    });

    group('AcpThoughtView', () {
      testWidgets('collapsed by default and expands on tap', (tester) async {
        await tester.pumpWidget(
          wrap(
            const AcpThoughtView(
              entry: AcpThoughtEntry(
                id: 'th1',
                markdown: 'secret reasoning here',
                title: 'Analysis',
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Analysis'), findsOneWidget);
        expect(find.text('secret reasoning here'), findsNothing);

        await tester.tap(find.text('Analysis'));
        await tester.pump();
        expect(find.text('secret reasoning here'), findsOneWidget);
      });

      testWidgets('shows streaming label while streaming', (tester) async {
        await tester.pumpWidget(
          wrap(
            const AcpThoughtView(
              entry: AcpThoughtEntry(
                id: 'th1',
                markdown: 'x',
                status: AcpStreamStatus.streaming,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Thinking…'), findsOneWidget);
      });
    });

    group('AcpInlineImage', () {
      testWidgets('renders in-memory bytes', (tester) async {
        await tester.pumpWidget(
          wrap(AcpInlineImage(image: AcpImageContent(bytes: _pngBytes))),
        );
        await settleImage(tester);
        expect(find.byType(Image), findsOneWidget);
      });

      testWidgets('decodes a data URI', (tester) async {
        const dataUri =
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
            'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
        await tester.pumpWidget(
          wrap(AcpInlineImage(image: AcpImageContent(uri: dataUri))),
        );
        await settleImage(tester);
        expect(find.byType(Image), findsOneWidget);
      });

      testWidgets('shows placeholder when a network image has no resolver', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(
                uri: 'https://example.com/a.png',
                label: 'remote diagram',
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(Image), findsNothing);
        expect(find.text('remote diagram'), findsOneWidget);
      });

      testWidgets('uses the resolver for file/network images', (tester) async {
        var called = false;
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(uri: 'file:///tmp/a.png'),
              resolver: (image) async {
                called = true;
                return _pngBytes;
              },
            ),
          ),
        );
        await settleImage(tester);
        expect(called, isTrue);
        expect(find.byType(Image), findsOneWidget);
      });

      testWidgets('shows an error placeholder when resolver returns null', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(uri: 'file:///tmp/a.png'),
              resolver: (image) async => null,
            ),
          ),
        );
        await settleImage(tester);
        expect(find.text('Image failed to load'), findsOneWidget);
        expect(
          tester.getSize(find.byType(AcpInlineImage)).height,
          lessThan(80),
          reason:
              'failed images must not reserve a large blank transcript area',
        );
      });

      testWidgets('fires tap callback', (tester) async {
        AcpImageContent? tapped;
        // A network image without a resolver renders a fixed-size placeholder,
        // giving a stable, decode-independent tap target.
        final image = AcpImageContent(
          uri: 'https://example.com/a.png',
          label: 'diagram',
        );
        await tester.pumpWidget(
          wrap(AcpInlineImage(image: image, onTap: (i) => tapped = i)),
        );
        await tester.pump();
        await tester.tap(find.byType(AcpInlineImage));
        expect(tapped, image);
      });

      testWidgets('rejects oversized in-memory bytes before decode', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(
                bytes: Uint8List.fromList(List<int>.filled(64, 0)),
              ),
              maxBytes: 8,
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(Image), findsNothing);
        expect(find.text('Image too large to display'), findsOneWidget);
      });

      testWidgets('rejects an oversized data URI', (tester) async {
        const dataUri =
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
            'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(image: AcpImageContent(uri: dataUri), maxBytes: 8),
          ),
        );
        await tester.pump();
        expect(find.byType(Image), findsNothing);
        expect(find.text('Image too large to display'), findsOneWidget);
      });

      testWidgets('rejects a non-positive decode hint', (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(bytes: _pngBytes, decodeWidth: -1),
            ),
          ),
        );
        await settleImage(tester);
        expect(find.byType(Image), findsNothing);
        expect(find.text('Image failed to load'), findsOneWidget);
      });

      testWidgets('bounds both decode dimensions for a tall image', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(image: AcpImageContent(bytes: buildPng(2, 20000))),
          ),
        );
        await settleImage(tester);
        final image = tester.widget<Image>(find.byType(Image));
        final resize = image.image as ResizeImage;
        expect(resize.width, lessThanOrEqualTo(kAcpMaxImageDecodeDimension));
        expect(resize.height, lessThanOrEqualTo(kAcpMaxImageDecodeDimension));
        // Longer (height) edge is bounded to the default budget; aspect ratio is
        // preserved, so the short edge shrinks accordingly.
        expect(resize.height, kAcpDefaultImageDecodeDimension);
        expect(resize.width, 1);
        expect(
          resize.width! * resize.height!,
          lessThanOrEqualTo(kAcpMaxImageDecodePixels),
        );
      });

      testWidgets('bounds both decode dimensions for a wide image', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(image: AcpImageContent(bytes: buildPng(20000, 2))),
          ),
        );
        await settleImage(tester);
        final image = tester.widget<Image>(find.byType(Image));
        final resize = image.image as ResizeImage;
        expect(resize.width, kAcpDefaultImageDecodeDimension);
        expect(resize.height, 1);
        expect(
          resize.width! * resize.height!,
          lessThanOrEqualTo(kAcpMaxImageDecodePixels),
        );
      });

      testWidgets('rejects decompression-bomb dimensions', (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(bytes: buildPng(100000, 100000)),
            ),
          ),
        );
        await settleImage(tester);
        expect(find.byType(Image), findsNothing);
        expect(find.text('Image too large to display'), findsOneWidget);
      });

      testWidgets('applies a bounded default decode dimension without hints', (
        tester,
      ) async {
        // A 512x512 source is bounded by the default budget without upscaling.
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(image: AcpImageContent(bytes: buildPng(2000, 1000))),
          ),
        );
        await settleImage(tester);
        final image = tester.widget<Image>(find.byType(Image));
        expect(image.image, isA<ResizeImage>());
        final resize = image.image as ResizeImage;
        expect(resize.width, kAcpDefaultImageDecodeDimension);
        expect(resize.height, kAcpDefaultImageDecodeDimension ~/ 2);
      });

      testWidgets('caps an oversized decode hint', (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(
                bytes: buildPng(8000, 8000),
                decodeWidth: 999999,
              ),
            ),
          ),
        );
        await settleImage(tester);
        final image = tester.widget<Image>(find.byType(Image));
        final resize = image.image as ResizeImage;
        expect(resize.width, lessThanOrEqualTo(kAcpMaxImageDecodeDimension));
        expect(resize.height, lessThanOrEqualTo(kAcpMaxImageDecodeDimension));
        expect(
          resize.width! * resize.height!,
          lessThanOrEqualTo(kAcpMaxImageDecodePixels),
        );
      });

      testWidgets('stale resolver completion cannot overwrite a newer image', (
        tester,
      ) async {
        final slow = Completer<Uint8List?>();
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(uri: 'file:///a.png'),
              resolver: (image) => slow.future,
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(Image), findsNothing);

        // A newer image/resolver supersedes the pending one and resolves fast.
        await tester.pumpWidget(
          wrap(
            AcpInlineImage(
              image: AcpImageContent(uri: 'file:///b.png'),
              resolver: (image) async => _pngBytes,
            ),
          ),
        );
        await settleImage(tester);
        expect(find.byType(Image), findsOneWidget);

        // The stale completion arrives last and must be ignored.
        slow.complete(null);
        await settleImage(tester);
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('Image failed to load'), findsNothing);
      });
    });

    group('AcpResourceChip', () {
      testWidgets('shows name, metadata and fires open/copy callbacks', (
        tester,
      ) async {
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

        AcpResourceRef? opened;
        AcpResourceRef? copied;
        await tester.pumpWidget(
          wrap(
            AcpResourceChip(
              resource: const AcpResourceRef(
                uri: 'file:///a/report.pdf',
                mimeType: 'application/pdf',
                sizeBytes: 2048,
              ),
              onOpen: (r) => opened = r,
              onCopy: (r) => copied = r,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('application/pdf · 2 KB'), findsOneWidget);

        await tester.tap(find.text('report.pdf'));
        expect(opened?.uri, 'file:///a/report.pdf');

        await tester.tap(find.byIcon(Icons.copy_rounded));
        await tester.pump();
        expect(copied?.uri, 'file:///a/report.pdf');
        expect(
          (clipboardCalls.single.arguments as Map)['text'],
          'file:///a/report.pdf',
        );

        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
    });

    group('AcpDiffView paging', () {
      String bigDiff(int lines) => List.generate(
        lines,
        (i) => 'ctx-${i.toString().padLeft(4, '0')}',
      ).join('\n');

      testWidgets('bounds huge diffs and pages with show more/less', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            AcpDiffView(
              diff: AcpDiff(path: 'big.txt', unifiedDiff: bigDiff(5000)),
            ),
          ),
        );
        await tester.pump();

        // Only the first page of lines is built.
        expect(find.text('ctx-0000'), findsOneWidget);
        expect(find.text('ctx-0199'), findsOneWidget);
        expect(find.text('ctx-0200'), findsNothing);
        expect(find.text('Showing 200 of 5000 lines'), findsOneWidget);
        expect(find.textContaining('Show more lines'), findsOneWidget);
        expect(find.text('Show less'), findsNothing);

        // Reveal another page.
        await tester.ensureVisible(find.textContaining('Show more lines'));
        await tester.pump();
        await tester.tap(find.textContaining('Show more lines'));
        await tester.pump();
        expect(find.text('ctx-0200'), findsOneWidget);
        expect(find.text('ctx-0399'), findsOneWidget);
        expect(find.text('ctx-0400'), findsNothing);
        expect(find.text('Show less'), findsOneWidget);

        // Collapse back to the initial cap.
        await tester.ensureVisible(find.text('Show less'));
        await tester.pump();
        await tester.tap(find.text('Show less'));
        await tester.pump();
        expect(find.text('ctx-0200'), findsNothing);
        expect(find.text('Showing 200 of 5000 lines'), findsOneWidget);
      });

      testWidgets('small diffs show no paging control', (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpDiffView(
              diff: AcpDiff(path: 'small.txt', unifiedDiff: bigDiff(10)),
            ),
          ),
        );
        await tester.pump();
        expect(find.textContaining('Show more lines'), findsNothing);
        expect(find.textContaining('Showing'), findsNothing);
        expect(find.text('ctx-0009'), findsOneWidget);
      });

      testWidgets('respects a custom initial line cap', (tester) async {
        await tester.pumpWidget(
          wrap(
            AcpDiffView(
              diff: AcpDiff(path: 'mid.txt', unifiedDiff: bigDiff(20)),
              initialLineCap: 5,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('ctx-0004'), findsOneWidget);
        expect(find.text('ctx-0005'), findsNothing);
        expect(find.text('Showing 5 of 20 lines'), findsOneWidget);
      });

      testWidgets('truncates a huge single-line source before splitting', (
        tester,
      ) async {
        // A single enormous line with no newlines must not be split wholesale.
        final huge = 'x' * 5000;
        await tester.pumpWidget(
          wrap(
            AcpDiffView(
              diff: AcpDiff(path: 'oneline.txt', unifiedDiff: huge),
              maxSourceChars: 100,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Diff truncated (very large)'), findsOneWidget);
        // Only the bounded 100-char prefix is rendered as a single line.
        final rendered = tester.widget<Text>(
          find.textContaining(RegExp(r'^x+$')),
        );
        expect(rendered.data, hasLength(100));
      });

      testWidgets('truncates huge multi-line source and shows a notice', (
        tester,
      ) async {
        final huge = List.generate(2000, (i) => 'ctx-$i').join('\n');
        await tester.pumpWidget(
          wrap(
            AcpDiffView(
              diff: AcpDiff(path: 'many.txt', unifiedDiff: huge),
              maxSourceChars: 50,
              initialLineCap: 5,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Diff truncated (very large)'), findsOneWidget);
        // The line list is derived only from the bounded 50-char prefix, so far
        // fewer than 2000 lines exist.
        expect(find.text('ctx-1999'), findsNothing);
      });

      testWidgets('exposes truncation in semantics', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          wrap(
            AcpDiffView(
              diff: AcpDiff(path: 'big.txt', unifiedDiff: 'x' * 5000),
              maxSourceChars: 100,
            ),
          ),
        );
        await tester.pump();
        expect(
          find.bySemanticsLabel(
            RegExp('Diff truncated because it exceeds 100 characters'),
          ),
          findsOneWidget,
        );
        handle.dispose();
      });
    });
  });
  registerAcpAttachmentStripTests();
  registerAcpConcurrencyChoiceTests();
  registerAcpConfigOptionControlsTests();
  registerAcpNativeStartingViewTests();
  registerAcpPermissionSurfaceTests();
  registerAcpSlashCommandPickerTests();
}
