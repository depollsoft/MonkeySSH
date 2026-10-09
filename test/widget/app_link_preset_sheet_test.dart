// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/presentation/widgets/app_link_preset_sheet.dart';

const _preset = AgentLaunchPreset(
  tool: AgentLaunchTool.claudeCode,
  workingDirectory: '~/src/app',
  tmuxSessionName: 'agents',
  remoteMuxBackend: RemoteMuxBackend.monkeyMux,
);

AppLinkPresetReview _review({bool yolo = false}) => AppLinkPresetReview(
  hostLabel: 'build box',
  tool: _preset.tool,
  command: buildAgentLaunchCommand(_preset, startInYoloMode: yolo),
  yoloMode: yolo,
  yoloSwitches: yolo ? const ['--dangerously-skip-permissions'] : const [],
  muxSessionName: 'agents',
  muxBackend: RemoteMuxBackend.monkeyMux,
);

/// Pumps a launcher that opens the sheet and records its answer.
Future<List<bool>> _openSheet(
  WidgetTester tester,
  AppLinkPresetReview review, {
  ThemeData? theme,
  bool disableAnimations = false,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  final answers = <bool>[];
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? FluttyTheme.dark,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async =>
                    answers.add(await showAppLinkPresetSheet(context, review)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return answers;
}

void main() {
  testWidgets('shows the host, agent, session and exact command', (
    tester,
  ) async {
    final review = _review();
    await _openSheet(tester, review);

    expect(find.text('Run launch preset?'), findsOneWidget);
    expect(find.text('build box'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('agents (MonkeyMux)'), findsOneWidget);
    final command = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('app-link-preset-command')),
    );
    expect(command.data, review.command);
    expect(command.data, r'cd "$HOME/src/app" && claude');
    expect(find.textContaining('Nothing runs until'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('app-link-preset-yolo')),
      findsNothing,
    );
    expect(find.text('Run'), findsOneWidget);
  });

  testWidgets('calls out YOLO mode with an icon, words and the flag', (
    tester,
  ) async {
    final review = _review(yolo: true);
    await _openSheet(tester, review);

    final command = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('app-link-preset-command')),
    );
    expect(command.data, contains('--dangerously-skip-permissions'));
    final warning = find.byKey(const ValueKey<String>('app-link-preset-yolo'));
    expect(warning, findsOneWidget);
    expect(
      find.descendant(of: warning, matching: find.text('YOLO mode is on')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: warning,
        matching: find.byIcon(Icons.warning_amber_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: warning,
        matching: find.text('--dangerously-skip-permissions'),
      ),
      findsOneWidget,
    );
    expect(find.text('Run in YOLO mode'), findsOneWidget);
  });

  testWidgets('Run resolves true', (tester) async {
    final answers = await _openSheet(tester, _review());

    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(answers, [true]);
    expect(find.text('Run launch preset?'), findsNothing);
  });

  testWidgets('Cancel resolves false', (tester) async {
    final answers = await _openSheet(tester, _review(yolo: true));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(answers, [false]);
  });

  testWidgets('the close button resolves false', (tester) async {
    final answers = await _openSheet(tester, _review());

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();

    expect(answers, [false]);
  });

  testWidgets('tapping outside resolves false', (tester) async {
    final answers = await _openSheet(tester, _review());

    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();

    expect(answers, [false]);
  });

  testWidgets('actions meet the 44 point touch target', (tester) async {
    await _openSheet(tester, _review(yolo: true));

    for (final finder in [
      find.widgetWithText(FilledButton, 'Run in YOLO mode'),
      find.widgetWithText(TextButton, 'Cancel'),
      find.widgetWithIcon(IconButton, Icons.close),
    ]) {
      final size = tester.getSize(finder);
      expect(size.height, greaterThanOrEqualTo(44), reason: '$finder');
      expect(size.width, greaterThanOrEqualTo(44), reason: '$finder');
    }
  });

  testWidgets('actions stack instead of overflowing at large text sizes', (
    tester,
  ) async {
    final answers = await _openSheet(
      tester,
      _review(yolo: true),
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    final run = find.text('Run in YOLO mode');
    final cancel = find.text('Cancel');
    expect(run, findsOneWidget);
    expect(cancel, findsOneWidget);
    // Stacked, with Cancel nearest the thumb.
    expect(tester.getCenter(run).dy, lessThan(tester.getCenter(cancel).dy));
    expect(tester.getBottomRight(run).dx, lessThanOrEqualTo(320));

    await tester.tap(run);
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('tmux presets say an attached session starts nothing', (
    tester,
  ) async {
    await _openSheet(
      tester,
      const AppLinkPresetReview(
        hostLabel: 'build box',
        tool: AgentLaunchTool.codex,
        command: 'tmux new-session -A -s work codex',
        yoloMode: false,
        muxSessionName: 'work',
        muxBackend: RemoteMuxBackend.tmux,
      ),
    );

    expect(
      find.textContaining('tmux session work is already running'),
      findsOneWidget,
    );
  });

  testWidgets('long commands scroll inside the sheet', (tester) async {
    final review = AppLinkPresetReview(
      hostLabel: 'build box',
      tool: AgentLaunchTool.codex,
      command: 'codex ${List.filled(200, '--flag value').join(' ')}',
      yoloMode: true,
    );
    await _openSheet(tester, review);

    expect(tester.takeException(), isNull);
    expect(find.text('Run in YOLO mode'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Run in YOLO mode')).dy,
      lessThan(844),
    );
  });

  testWidgets('opens without animation when reduced motion is on', (
    tester,
  ) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: FluttyTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => answers.add(
                  await showAppLinkPresetSheet(context, _review()),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();

    final title = find.text('Run launch preset?');
    expect(title, findsOneWidget);
    final openedAt = tester.getTopLeft(title);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(title), openedAt);
  });
}
