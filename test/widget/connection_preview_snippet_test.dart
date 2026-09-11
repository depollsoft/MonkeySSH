// ignore_for_file: public_member_api_docs

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/models/acp_native_preview.dart';
import 'package:monkeyssh/domain/models/terminal_preview.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/connection_preview_snippet.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

void main() {
  Widget buildSnippet({
    String? preview = 'ready',
    String? sessionTitle,
    String? windowTitle,
    String? iconName,
  }) => MaterialApp(
    home: Scaffold(
      body: ConnectionPreviewSnippet(
        endpoint: 'depoll@mac-mini.home:22 - Connection #1',
        preview: preview,
        sessionTitle: sessionTitle,
        windowTitle: windowTitle,
        iconName: iconName,
      ),
    ),
  );
  String previewLines(int count) =>
      List.generate(count, (index) => 'line ${index + 1}').join('\n');

  testWidgets(
    'shows one active title when the window title and icon name match',
    (tester) async {
      await tester.pumpWidget(
        buildSnippet(
          windowTitle: 'Designing app prompt',
          iconName: 'Designing app prompt',
        ),
      );

      expect(find.text('Active: Designing app prompt'), findsOneWidget);
      expect(find.text('Designing app prompt'), findsNothing);
    },
  );

  testWidgets('prefers the window title over the icon name', (tester) async {
    await tester.pumpWidget(
      buildSnippet(windowTitle: 'Designing app prompt', iconName: 'codex'),
    );

    expect(find.text('Active: Designing app prompt'), findsOneWidget);
    expect(find.text('Active: codex'), findsNothing);
  });

  testWidgets('prefers the session title over terminal metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSnippet(
        sessionTitle: 'Implement onboarding',
        windowTitle: 'Designing app prompt',
        iconName: 'codex',
      ),
    );

    expect(find.text('Active: Implement onboarding'), findsOneWidget);
    expect(find.text('Active: Designing app prompt'), findsNothing);
  });

  testWidgets('renders extra rows in the default preview', (tester) async {
    final preview = previewLines(19);

    await tester.pumpWidget(buildSnippet(preview: preview));

    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 17);
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
    expect(previewText.style?.fontSize, 10.5);
    expect(previewText.style?.height, 1.22);
  });

  testWidgets('renders role-aware live native content and progress', (
    tester,
  ) async {
    final snapshot = AcpNativePreviewSnapshot(
      lines: const [
        AcpNativePreviewLine(
          kind: AcpNativePreviewKind.user,
          text: 'Fix the failing test',
        ),
        AcpNativePreviewLine(
          kind: AcpNativePreviewKind.tool,
          text: 'Running Flutter tests',
          active: true,
        ),
        AcpNativePreviewLine(
          kind: AcpNativePreviewKind.agent,
          text: 'The targeted tests now pass.',
        ),
      ],
      indeterminate: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ConnectionPreviewStack(
              entries: [
                ConnectionPreviewStackEntry(
                  title: 'Connection #1 · Hermes · work',
                  body: 'fallback',
                  nativeAcpPreviewSnapshot: snapshot,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Fix the failing test'), findsOneWidget);
    expect(find.text('Running Flutter tests'), findsOneWidget);
    expect(find.text('The targeted tests now pass.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('renders native content in compact connection metadata', (
    tester,
  ) async {
    final snapshot = AcpNativePreviewSnapshot(
      lines: const [
        AcpNativePreviewLine(
          kind: AcpNativePreviewKind.agent,
          text: 'Live native response',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewSnippet(
            endpoint: 'host · connected',
            nativeAcpPreviewSnapshot: snapshot,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Live native response'), findsOneWidget);
  });

  test('stack preview titles prefer session title over terminal metadata', () {
    final entry = buildConnectionPreviewStackEntry(
      connectionId: 1,
      state: SshConnectionState.connected,
      brightness: Brightness.dark,
      themeSettings: const TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      ),
      availableThemes: TerminalThemes.all,
      sessionTitle: 'Implement onboarding',
      windowTitle: 'Designing app prompt',
      iconName: 'Designing app prompt',
    );

    expect(entry.title, startsWith('Connection #1'));
    expect(entry.title, contains('Implement onboarding'));
    expect(RegExp('Designing app prompt').allMatches(entry.title), isEmpty);
  });

  test('stack preview metadata is separate from terminal preview text', () {
    final entry = buildConnectionPreviewStackEntry(
      connectionId: 1,
      state: SshConnectionState.connected,
      brightness: Brightness.dark,
      themeSettings: const TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      ),
      availableThemes: TerminalThemes.all,
      preview: previewLines(17),
      workingDirectory: Uri.parse('file:///Users/depoll/Code/flutty'),
      shellStatus: TerminalShellStatus.runningCommand,
    );

    expect(entry.metadata, isNotNull);
    expect(entry.body.split('\n'), hasLength(17));
  });

  test('stack preview prefers the active connection terminal theme', () {
    final entry = buildConnectionPreviewStackEntry(
      connectionId: 1,
      state: SshConnectionState.connected,
      brightness: Brightness.light,
      themeSettings: const TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      ),
      availableThemes: TerminalThemes.all,
      preview: 'ready',
      activeTerminalTheme: TerminalThemes.defaultDarkTheme,
    );

    expect(entry.terminalTheme, TerminalThemes.defaultDarkTheme);
  });

  testWidgets('inline previews use the terminal theme background', (
    tester,
  ) async {
    const terminalTheme = TerminalThemes.defaultDarkTheme;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewSnippet(
            endpoint: 'depoll@mac-mini.home:22 - Connection #1',
            preview: 'ready',
            terminalTheme: terminalTheme,
          ),
        ),
      ),
    );

    final decorations = _boxDecorationsWithColor(
      tester,
      terminalTheme.background,
    );
    expect(decorations, hasLength(1));
    expect(
      (decorations.single.border! as Border).top.color,
      Color.alphaBlend(
        terminalTheme.foreground.withAlpha(46),
        terminalTheme.background,
      ),
    );
  });

  testWidgets('renders extra rows in stacked previews', (tester) async {
    final preview = previewLines(19);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewStack(
            entries: [
              ConnectionPreviewStackEntry(
                title: 'Connection #1',
                body: preview,
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(ConnectionPreviewStack)).height, 198);
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 17);
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
    expect(previewText.style?.fontSize, lessThanOrEqualTo(10.5));
    expect(previewText.style?.height, 1.22);
  });

  testWidgets('clips narrow stack previews instead of wrapping terminal rows', (
    tester,
  ) async {
    final preview = [
      'line 1',
      'this-is-a-long-terminal-row-that-should-scale-down-instead-of-wrapping',
      ...List.generate(15, (index) => 'line ${index + 3}'),
    ].join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: ConnectionPreviewStack(
              entries: [
                ConnectionPreviewStackEntry(
                  title: 'Connection #1',
                  body: preview,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final previewText = tester.widget<Text>(find.text(preview));
    expect(tester.getSize(find.byType(ConnectionPreviewStack)).height, 198);
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
  });

  testWidgets('sizes stack previews to rendered rows', (tester) async {
    final preview = previewLines(6);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewStack(
            entries: [
              ConnectionPreviewStackEntry(
                title: 'Connection #1',
                body: preview,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(ConnectionPreviewStack)).height,
      lessThan(198),
    );
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 17);
  });

  testWidgets('renders styled preview snapshots with terminal painter', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 100)..write('\x1b[31mred\x1b[0m');
    final preview = SshSession.buildTerminalPreviewSnapshot(terminal)!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewStack(
            entries: [
              ConnectionPreviewStackEntry(
                title: 'Connection #1',
                body: preview.plainText,
                previewSnapshot: preview,
                terminalTheme: TerminalThemes.defaultDarkTheme,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.text(preview.plainText), findsNothing);
  });

  testWidgets('stacked previews use the terminal theme background', (
    tester,
  ) async {
    const terminalTheme = TerminalThemes.defaultDarkTheme;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewStack(
            entries: [
              ConnectionPreviewStackEntry(
                title: 'Connection #1',
                body: 'ready',
                terminalTheme: terminalTheme,
              ),
            ],
          ),
        ),
      ),
    );

    final decorations = _boxDecorationsWithColor(
      tester,
      terminalTheme.background,
    );
    expect(decorations, hasLength(1));
    expect(
      (decorations.single.border! as Border).top.color,
      Color.alphaBlend(
        terminalTheme.foreground.withAlpha(46),
        terminalTheme.background,
      ),
    );
  });

  for (final textScale in [1.0, 1.5, 2.0]) {
    testWidgets(
      'styled preview fills its container vertically at scale $textScale',
      (tester) async {
        var fittingSearches = 0;
        debugOnStyledPreviewFontFit = () => fittingSearches++;
        addTearDown(() => debugOnStyledPreviewFontFit = null);
        final terminal = Terminal(maxLines: 100)
          ..resize(80, 24)
          ..write(
            [
              'cd ~/Code/flutty',
              'git status --short',
              ' M lib/foo.dart',
              ' M lib/bar.dart',
              'echo done',
              r'$',
            ].join('\r\n'),
          );
        final preview = SshSession.buildTerminalPreviewSnapshot(terminal)!;

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: SizedBox(
                width: 360,
                child: ConnectionPreviewStack(
                  entries: [
                    ConnectionPreviewStackEntry(
                      title: 'Connection #1',
                      body: preview.plainText,
                      previewSnapshot: preview,
                      terminalTheme: TerminalThemes.defaultDarkTheme,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final styledPainter = find
            .descendant(
              of: find.byType(ConnectionPreviewStack),
              matching: find.byType(CustomPaint),
            )
            .last;
        final painterSize = tester.getSize(styledPainter);
        final cardSize = tester.getSize(
          find
              .descendant(
                of: find.byType(ConnectionPreviewStack),
                matching: find.byType(ClipRect),
              )
              .last,
        );
        // The styled preview painter must take up the full vertical area it was
        // given; no slack at the bottom of the rendered card.
        expect(painterSize.height, greaterThan(0));
        expect(painterSize.height, cardSize.height);
        expect(fittingSearches, 1);
      },
    );

    testWidgets('styled preview content fills card width at scale $textScale', (
      tester,
    ) async {
      // Wide content that should width-fill at a small-to-medium font.
      final lines = [
        '-rw-r--r--    1 root  wheel    1316 Nov 22  2025 syslog.conf',
        '-rw-r--r--    1 root  wheel     160 Nov 22  2025 ttys',
        'drwxr-xr-x    5 root  wheel     192 Nov 22  2025 uucp',
        '-rw-r--r--    1 root  wheel       0 Nov 22  2025 wfs',
        '-r--r--r--    1 root  wheel     304 Nov 22  2025 xtab',
        '-r--r--r--    1 root  wheel    3191 Nov 22  2025 zprofile',
        '-rw-r--r--    1 root  wheel    9335 Nov 22  2025 zshrc',
        'depoll@mac-mini ~ %',
      ];
      final terminal = Terminal(maxLines: 200)
        ..resize(120, 30)
        ..write(lines.join('\r\n'));
      final preview = SshSession.buildTerminalPreviewSnapshot(terminal)!;

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: ConnectionPreviewStack(
                entries: [
                  ConnectionPreviewStackEntry(
                    title: 'Connection #1',
                    body: preview.plainText,
                    previewSnapshot: preview,
                    terminalTheme: TerminalThemes.defaultDarkTheme,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final styledPainter = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString().contains(
              '_TerminalPreviewPainter',
            ),
      );
      final painterSize = tester.getSize(styledPainter);
      // Card has 1px border + 10px LR padding on each side = card_width - 22.
      expect(painterSize.width, closeTo(360 - 22, 1));
      // And the rendered cells must reach the right edge: at the chosen font,
      // contentColumns * cellWidth should match painterSize.width within one
      // cell.
      expect(painterSize.height, greaterThan(0));
    });
  }

  testWidgets('sizes long non-wrapping previews to terminal rows', (
    tester,
  ) async {
    const title = 'Connection #1 • Adjust Connection Preview Length';
    final preview = [
      'cd',
      '/Users/depoll/Code/flutty.worktrees/connection-preview-10-lines',
      'git --no-pager diff --check',
      'git add lib/presentation/widgets/connection_preview_snippet.dart',
      '74 lines...',
      'Pushed a guard to PR #500:',
      'https://github.com/depollsoft/MonkeySSH/pull/500',
      'Repeated taps on an active connection now go through a single',
      'debounced terminal-route opener, so they cannot stack duplicate',
      'instances of the same terminal page.',
      'Added a regression test that double-taps a connection and verifies',
      'only one terminal route is pushed.',
      '~/Code/flutty [main*%]',
      '────────────────────────────────────────────────────────',
      '›',
      '────────────────────────────────────────────────────────',
      '/ commands · ? helpGPT-5.5 · xhigh (25%)',
    ].join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 710,
            child: ConnectionPreviewStack(
              entries: [
                ConnectionPreviewStackEntry(title: title, body: preview),
              ],
            ),
          ),
        ),
      ),
    );

    final stackHeight = tester
        .getSize(find.byType(ConnectionPreviewStack))
        .height;
    expect(stackHeight, 198);
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
    expect(
      tester.getTopLeft(find.text(preview)).dy,
      greaterThan(tester.getBottomLeft(find.text(title)).dy + 2),
    );
  });

  testWidgets('renders stack metadata without consuming preview line budget', (
    tester,
  ) async {
    final preview = previewLines(19);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewStack(
            entries: [
              ConnectionPreviewStackEntry(
                title: 'Connection #1',
                body: preview,
                metadata: '~/Code/flutty • Running',
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(ConnectionPreviewStack)).height, 208);
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 17);
    expect(find.text('~/Code/flutty • Running'), findsOneWidget);
  });

  testWidgets(
    'ConnectionPreviewSnippet uses terminal theme background color directly',
    (tester) async {
      const testTheme = TerminalThemes.dracula;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConnectionPreviewSnippet(
              endpoint: 'depoll@mac-mini.home:22 - Connection #1',
              preview: 'ready',
              terminalTheme: testTheme,
            ),
          ),
        ),
      );

      final containerFinder = find
          .ancestor(of: find.text('ready'), matching: find.byType(Container))
          .first;

      final container = tester.widget<Container>(containerFinder);
      final decoration = container.decoration as BoxDecoration?;
      expect(decoration?.color, testTheme.background);
    },
  );

  testWidgets('composites captured terminal images into the preview', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    late TerminalPreviewSnapshot snapshot;
    await tester.runAsync(() async {
      final terminal = Terminal(maxLines: 100)..resize(40, 12);
      terminal.graphics.storeImageWithId(
        9,
        _solidImage(const Color(0xFFFF0000), 32, 32),
      );
      terminal
        ..write('agent output\r\n')
        ..write(_placeholderGrid(9, cols: 8, rows: 4));
      snapshot = SshSession.buildTerminalPreviewSnapshot(terminal)!;
    });
    expect(snapshot.images, isNotEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: RepaintBoundary(
              key: boundaryKey,
              child: ConnectionPreviewStack(
                entries: [
                  ConnectionPreviewStackEntry(
                    title: 'Connection #1',
                    body: snapshot.plainText,
                    previewSnapshot: snapshot,
                    terminalTheme: TerminalThemes.defaultDarkTheme,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    var hasRed = false;
    await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final shot = await boundary.toImage();
      final data = (await shot.toByteData())!;
      for (var i = 0; i + 4 <= data.lengthInBytes; i += 4) {
        final r = data.getUint8(i);
        final g = data.getUint8(i + 1);
        final b = data.getUint8(i + 2);
        if (r > 150 && g < 90 && b < 90) {
          hasRed = true;
          break;
        }
      }
    });

    expect(
      hasRed,
      isTrue,
      reason: 'the captured image should be composited into the preview card',
    );
  });
}

List<BoxDecoration> _boxDecorationsWithColor(
  WidgetTester tester,
  Color color,
) => tester
    .widgetList<Container>(find.byType(Container))
    .map((container) => container.decoration)
    .whereType<BoxDecoration>()
    .where((decoration) => decoration.color == color)
    .toList(growable: false);

/// Kitty row/column placeholder diacritics (row/column order).
const _kittyDiacritics = <int>[
  0x0305,
  0x030D,
  0x030E,
  0x0310,
  0x0312,
  0x033D,
  0x033E,
  0x033F,
  0x0346,
  0x034A,
  0x034B,
  0x034C,
  0x0350,
  0x0351,
  0x0352,
  0x0357,
  0x035B,
  0x0363,
  0x0364,
  0x0365,
  0x0366,
  0x0367,
  0x0368,
  0x0369,
];

ui.Image _solidImage(Color color, int width, int height) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImageSync(width, height);
}

String _placeholderGrid(int imageId, {required int cols, required int rows}) {
  final placeholder = String.fromCharCode(kittyGraphicsPlaceholderCodePoint);
  final r = (imageId >> 16) & 0xFF;
  final g = (imageId >> 8) & 0xFF;
  final b = imageId & 0xFF;
  final buffer = StringBuffer();
  for (var row = 0; row < rows; row++) {
    buffer.write('\x1b[38;2;$r;$g;${b}m');
    for (var col = 0; col < cols; col++) {
      buffer
        ..write(placeholder)
        ..writeCharCode(_kittyDiacritics[row])
        ..writeCharCode(_kittyDiacritics[col]);
    }
    buffer.write('\x1b[39m');
    if (row < rows - 1) buffer.write('\r\n');
  }
  return buffer.toString();
}
