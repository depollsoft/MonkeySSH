// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_audio_player.dart';

import '../helpers/fake_acp_audio_playback.dart';

const _clip = AcpAudioClip(
  data: 'AAAA',
  mimeType: 'audio/mpeg',
  sizeBytes: 1258291,
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: FluttyTheme.dark,
    home: Scaffold(
      body: Center(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  ),
);

Future<void> _settleLoad(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

Finder _toggle([Key? player]) => player == null
    ? find.byKey(const ValueKey('acp-audio-play-toggle'))
    : find.descendant(
        of: find.byKey(player),
        matching: find.byKey(const ValueKey('acp-audio-play-toggle')),
      );

void main() {
  testWidgets('shows metadata and decodes nothing until play is pressed', (
    tester,
  ) async {
    final cache = FakeAcpAudioClipCache();
    final controller = FakeAcpAudioController();
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      AcpAudioPlayer(
        clip: _clip,
        cache: cache,
        controllerFactory: (_) => controller,
        playbackSupported: true,
      ),
    );

    expect(find.text('Audio clip'), findsOneWidget);
    expect(find.text('MP3 · 1.2 MB'), findsOneWidget);
    expect(find.byTooltip('Play audio clip'), findsOneWidget);
    expect(cache.acquired, 0);
    expect(find.bySemanticsLabel('Audio clip, MP3 · 1.2 MB'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('plays, reports position, and pauses', (tester) async {
    final cache = FakeAcpAudioClipCache();
    final controller = FakeAcpAudioController();
    await _pump(
      tester,
      AcpAudioPlayer(
        clip: _clip,
        cache: cache,
        controllerFactory: (_) => controller,
        playbackSupported: true,
      ),
    );

    await tester.tap(_toggle());
    await _settleLoad(tester);

    expect(cache.acquired, 1);
    expect(controller.playCount, 1);
    expect(find.byTooltip('Pause audio clip'), findsOneWidget);
    expect(find.text('0:00 / 1:03'), findsOneWidget);
    expect(find.byKey(const ValueKey('acp-audio-seek')), findsOneWidget);

    await controller.seekTo(const Duration(seconds: 12));
    await tester.pump();
    expect(find.text('0:12 / 1:03'), findsOneWidget);

    await tester.tap(_toggle());
    await tester.pump();
    expect(controller.pauseCount, 1);
    expect(find.byTooltip('Play audio clip'), findsOneWidget);
  });

  testWidgets('scrubbing seeks once the drag ends', (tester) async {
    final controller = FakeAcpAudioController();
    await _pump(
      tester,
      AcpAudioPlayer(
        clip: _clip,
        cache: FakeAcpAudioClipCache(),
        controllerFactory: (_) => controller,
        playbackSupported: true,
      ),
    );
    await tester.tap(_toggle());
    await _settleLoad(tester);

    await tester.drag(
      find.byKey(const ValueKey('acp-audio-seek')),
      const Offset(80, 0),
    );
    await tester.pump();

    expect(controller.lastSeek, isNotNull);
    expect(controller.lastSeek, greaterThan(Duration.zero));
  });

  testWidgets('disposal stops playback and releases the decoded clip', (
    tester,
  ) async {
    final cache = FakeAcpAudioClipCache();
    final controller = FakeAcpAudioController();
    await _pump(
      tester,
      AcpAudioPlayer(
        clip: _clip,
        cache: cache,
        controllerFactory: (_) => controller,
        playbackSupported: true,
      ),
    );
    await tester.tap(_toggle());
    await _settleLoad(tester);
    expect(cache.outstanding, 1);

    await _pump(tester, const SizedBox());

    expect(controller.disposed, isTrue);
    expect(cache.outstanding, 0);
  });

  testWidgets('starting one clip pauses another', (tester) async {
    final first = FakeAcpAudioController();
    final second = FakeAcpAudioController();
    final cache = FakeAcpAudioClipCache();
    await _pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AcpAudioPlayer(
            key: const ValueKey('first'),
            clip: _clip,
            cache: cache,
            controllerFactory: (_) => first,
            playbackSupported: true,
          ),
          AcpAudioPlayer(
            key: const ValueKey('second'),
            clip: const AcpAudioClip(data: 'BBBB', mimeType: 'audio/wav'),
            cache: cache,
            controllerFactory: (_) => second,
            playbackSupported: true,
          ),
        ],
      ),
    );

    await tester.tap(_toggle(const ValueKey('first')));
    await _settleLoad(tester);
    await tester.tap(_toggle(const ValueKey('second')));
    await _settleLoad(tester);

    expect(first.pauseCount, 1);
    expect(first.value.isPlaying, isFalse);
    expect(second.value.isPlaying, isTrue);
  });

  testWidgets('offers open and save where playback is unsupported', (
    tester,
  ) async {
    final cache = FakeAcpAudioClipCache();
    final opened = <AcpAudioExport>[];
    final saved = <AcpAudioExport>[];
    await _pump(
      tester,
      AcpAudioPlayer(
        clip: const AcpAudioClip(data: 'AAAA', mimeType: 'audio/x-wav'),
        cache: cache,
        playbackSupported: false,
        onOpenExternally: (_, export) async => opened.add(export),
        onSave: (_, export) async => saved.add(export),
      ),
    );

    expect(_toggle(), findsNothing);
    expect(find.text('WAV · Plays in another app'), findsOneWidget);

    // Android is the default test platform, so "open" is the share sheet.
    await tester.tap(find.byTooltip('Share audio clip'));
    await tester.pump();
    await tester.tap(find.byTooltip('Save audio clip'));
    await tester.pump();

    expect(opened.single.mimeType, 'audio/wav');
    expect(saved.single.fileName, 'audio-clip.wav');
    expect(cache.outstanding, 0);
  });

  testWidgets('falls back to open and save when the clip cannot play', (
    tester,
  ) async {
    final saved = <AcpAudioExport>[];
    final controller = FakeAcpAudioController(failInitialize: true);
    await _pump(
      tester,
      AcpAudioPlayer(
        clip: const AcpAudioClip(data: 'AAAA', mimeType: 'audio/ogg'),
        cache: FakeAcpAudioClipCache(),
        controllerFactory: (_) => controller,
        playbackSupported: true,
        onSave: (_, export) async => saved.add(export),
      ),
    );

    await tester.tap(_toggle());
    await _settleLoad(tester);

    expect(find.textContaining('Can’t play here'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(controller.disposed, isTrue);
    await tester.tap(find.byTooltip('Save audio clip'));
    await tester.pump();
    expect(saved.single.fileName, 'audio-clip.ogg');
  });

  testWidgets('marks undecodable payloads as damaged without actions', (
    tester,
  ) async {
    await _pump(
      tester,
      AcpAudioPlayer(
        clip: _clip,
        cache: FakeAcpAudioClipCache(fail: true),
        controllerFactory: (_) => FakeAcpAudioController(),
        playbackSupported: true,
      ),
    );

    await tester.tap(_toggle());
    await _settleLoad(tester);

    expect(find.textContaining('Couldn’t decode this clip'), findsOneWidget);
    expect(_toggle(), findsNothing);
    expect(find.byTooltip('Save audio clip'), findsNothing);
  });

  testWidgets('shows a placeholder for clips above the playback cap', (
    tester,
  ) async {
    await _pump(
      tester,
      const AcpAudioPlayer(
        clip: AcpAudioClip(
          mimeType: 'audio/wav',
          sizeBytes: kAcpAttachmentAudioMaxBytes + 1,
        ),
        playbackSupported: true,
      ),
    );

    expect(
      find.textContaining('Too large to play · 10 MB max'),
      findsOneWidget,
    );
    expect(_toggle(), findsNothing);
    expect(find.byTooltip('Save audio clip'), findsNothing);
  });

  test('playback support follows the video_player platform matrix', () {
    expect(acpAudioPlaybackSupported(TargetPlatform.iOS), isTrue);
    expect(acpAudioPlaybackSupported(TargetPlatform.android), isTrue);
    expect(acpAudioPlaybackSupported(TargetPlatform.macOS), isTrue);
    expect(acpAudioPlaybackSupported(TargetPlatform.windows), isFalse);
    expect(acpAudioPlaybackSupported(TargetPlatform.linux), isFalse);
  });

  test('formats durations compactly', () {
    expect(formatAcpAudioDuration(Duration.zero), '0:00');
    expect(formatAcpAudioDuration(const Duration(seconds: 63)), '1:03');
    expect(
      formatAcpAudioDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });
}
