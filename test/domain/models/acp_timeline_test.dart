// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';

AcpContentChunkUpdate _chunk(String kind, String text, {String? messageId}) =>
    AcpContentChunkUpdate(
      kind: kind,
      content: AcpTextContent(text),
      messageId: messageId,
    );

/// Applies every update in order and returns the final timeline snapshot.
AcpTimeline _run(AcpTimelineBuilder builder, List<AcpSessionUpdate> updates) {
  for (final update in updates) {
    builder.apply(update);
  }
  return builder.snapshot();
}

void main() {
  group('AcpTimelineBuilder content grouping', () {
    test('groups chunks with the same message id into one entry', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'Hello ', messageId: 'm1'),
        _chunk('agent_message_chunk', 'world', messageId: 'm1'),
      ]);
      expect(timeline.entries, hasLength(1));
      final entry = timeline.entries.single as AcpMessageEntry;
      expect(entry.role, AcpMessageRole.agent);
      expect(entry.content, hasLength(2));
      expect((entry.content[0] as AcpTextContent).text, 'Hello ');
      expect((entry.content[1] as AcpTextContent).text, 'world');
    });

    test('separates different roles and message ids', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('user_message_chunk', 'hi', messageId: 'u1'),
        _chunk('agent_message_chunk', 'reply', messageId: 'a1'),
        _chunk('agent_thought_chunk', 'hmm', messageId: 't1'),
      ]);
      expect(timeline.entries, hasLength(3));
      expect(timeline.entries.map((e) => (e as AcpMessageEntry).role), [
        AcpMessageRole.user,
        AcpMessageRole.agent,
        AcpMessageRole.thought,
      ]);
    });

    test('appends unlabeled chunks to the open same-role message', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'a'),
        _chunk('agent_message_chunk', 'b'),
      ]);
      expect(timeline.entries, hasLength(1));
      expect(
        (timeline.entries.single as AcpMessageEntry).content,
        hasLength(2),
      );
    });

    test('separates anonymous subagent and top-level chunks', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpContentChunkUpdate(
          kind: 'agent_message_chunk',
          content: AcpTextContent('nested'),
          meta: {
            'claudeCode': {'parentToolUseId': 'agent-launch'},
          },
        ),
        _chunk('agent_message_chunk', 'top-level'),
      ]);

      final messages = timeline.entries.cast<AcpMessageEntry>();
      expect(messages.map((entry) => entry.parentToolCallId), [
        'agent-launch',
        null,
      ]);
      expect(
        messages.map((entry) => (entry.content.single as AcpTextContent).text),
        ['nested', 'top-level'],
      );
    });

    test('resumes an earlier message id after an interruption', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'a', messageId: 'm1'),
        const AcpToolCallUpdate(
          toolCallId: 't1',
          isInitial: true,
          title: 'Read',
        ),
        _chunk('agent_message_chunk', 'b', messageId: 'm1'),
      ]);
      expect(timeline.entries, hasLength(2));
      final message = timeline.entries.whereType<AcpMessageEntry>().single;
      expect(message.content, hasLength(2));
    });
  });

  group('AcpTimelineBuilder local user prompts', () {
    test('shows a local prompt and suppresses the provider echo', () {
      final builder = AcpTimelineBuilder()
        ..appendLocalUserPrompt(const [AcpTextContent('hello')])
        ..apply(_chunk('user_message_chunk', 'hello', messageId: 'remote-user'))
        ..apply(_chunk('agent_message_chunk', 'hi', messageId: 'remote-agent'));

      final timeline = builder.snapshot();
      expect(timeline.entries, hasLength(2));
      final user = timeline.entries.first as AcpMessageEntry;
      expect(user.role, AcpMessageRole.user);
      expect((user.content.single as AcpTextContent).text, 'hello');
      expect(
        (timeline.entries.last as AcpMessageEntry).role,
        AcpMessageRole.agent,
      );
    });

    test('does not suppress unrelated user updates after non-echoed turns', () {
      final builder = AcpTimelineBuilder();
      for (var turn = 0; turn < 600; turn++) {
        builder
          ..appendLocalUserPrompt([AcpTextContent('prompt-$turn')])
          ..apply(_chunk('agent_message_chunk', 'reply-$turn'));
      }
      builder.apply(_chunk('user_message_chunk', 'another client'));

      final timeline = builder.snapshot();
      expect(timeline.overflowed, isTrue);
      final last = timeline.entries.last as AcpMessageEntry;
      expect(last.role, AcpMessageRole.user);
      expect((last.content.single as AcpTextContent).text, 'another client');
    });

    test('suppresses queued prompt echoes only after dispatch', () {
      final builder = AcpTimelineBuilder();
      final first = builder.appendLocalUserPrompt(const [
        AcpTextContent('one'),
      ]);
      final second = builder.appendLocalUserPrompt(const [
        AcpTextContent('two'),
      ], queued: true);
      builder
        ..apply(_chunk('user_message_chunk', 'one', messageId: 'remote-one'))
        ..apply(_chunk('agent_message_chunk', 'reply'))
        ..apply(_chunk('user_message_chunk', 'unrelated', messageId: 'other'))
        ..markLocalUserPromptDispatched(second)
        ..apply(_chunk('user_message_chunk', 'two', messageId: 'remote-two'));

      expect(
        builder
            .snapshot()
            .entries
            .whereType<AcpMessageEntry>()
            .where((entry) => entry.role == AcpMessageRole.user)
            .map((entry) => entry.messageId),
        [first, second, 'other'],
      );
    });

    test('rolls back only the failed optimistic prompt', () {
      final builder = AcpTimelineBuilder()
        ..apply(_chunk('agent_message_chunk', 'earlier', messageId: 'agent-1'));
      final localId = builder.appendLocalUserPrompt(const [
        AcpTextContent('retry me'),
      ]);

      final timeline = builder.removeLocalUserPrompt(localId);

      expect(timeline.entries, hasLength(1));
      expect(
        ((timeline.entries.single as AcpMessageEntry).content.single
                as AcpTextContent)
            .text,
        'earlier',
      );
    });
  });

  group('AcpTimelineBuilder tool merging', () {
    test('merges tool_call and tool_call_update by id', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpToolCallUpdate(
          toolCallId: 't1',
          isInitial: true,
          title: 'Read file',
          status: AcpToolStatus.pending,
        ),
        const AcpToolCallUpdate(
          toolCallId: 't1',
          status: AcpToolStatus.completed,
        ),
      ]);
      expect(timeline.entries, hasLength(1));
      final entry = timeline.entries.single as AcpToolCallEntry;
      expect(entry.title, 'Read file');
      expect(entry.status, AcpToolStatus.completed);
    });

    test('keeps distinct tool calls separate and preserves order', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpToolCallUpdate(toolCallId: 't1', isInitial: true),
        const AcpToolCallUpdate(toolCallId: 't2', isInitial: true),
      ]);
      expect(timeline.entries, hasLength(2));
      expect(timeline.entries.map((e) => (e as AcpToolCallEntry).toolCallId), [
        't1',
        't2',
      ]);
    });

    test('preserves Claude subagent launch and parent transcript metadata', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpToolCallUpdate(
          toolCallId: 'agent-launch',
          isInitial: true,
          title: 'Agent',
          meta: <String, Object?>{
            'claudeCode': <String, Object?>{'subagent': true},
          },
        ),
        const AcpContentChunkUpdate(
          kind: 'agent_message_chunk',
          messageId: 'nested-message',
          content: AcpTextContent('nested reply'),
          meta: <String, Object?>{
            'claudeCode': <String, Object?>{'parentToolUseId': 'agent-launch'},
          },
        ),
        const AcpContentChunkUpdate(
          kind: 'agent_message_chunk',
          messageId: 'nested-message',
          content: AcpTextContent(' continued'),
        ),
        const AcpToolCallUpdate(
          toolCallId: 'nested-tool',
          isInitial: true,
          title: 'Read',
          meta: <String, Object?>{
            'claudeCode': <String, Object?>{'parentToolUseId': 'agent-launch'},
          },
        ),
      ]);

      final launch = timeline.entries[0] as AcpToolCallEntry;
      final message = timeline.entries[1] as AcpMessageEntry;
      final nestedTool = timeline.entries[2] as AcpToolCallEntry;
      expect(launch.isSubagent, isTrue);
      expect(message.parentToolCallId, 'agent-launch');
      expect(message.content, hasLength(2));
      expect(nestedTool.parentToolCallId, 'agent-launch');
    });

    test('ignores empty tool-call ids', () {
      final timeline = _run(AcpTimelineBuilder(), [
        const AcpToolCallUpdate(toolCallId: '', isInitial: true),
      ]);
      expect(timeline.entries, isEmpty);
    });
  });

  group('AcpTimelineBuilder session-scoped updates', () {
    test('does not affect the timeline', () {
      final builder = AcpTimelineBuilder();
      expect(builder.apply(const AcpPlanUpdate()), isNull);
      expect(builder.apply(const AcpUsageUpdate(used: 1, size: 2)), isNull);
      expect(builder.apply(const AcpAvailableCommandsUpdate()), isNull);
    });
  });

  group('AcpTimelineBuilder bounded memory', () {
    test('drops the oldest entries once maxEntries is exceeded', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(maxEntries: 3),
      );
      AcpTimeline? last;
      for (var i = 0; i < 5; i++) {
        last = builder.apply(
          _chunk('agent_message_chunk', 'msg$i', messageId: 'm$i'),
        );
      }
      expect(last!.entries, hasLength(3));
      expect(last.overflowed, isTrue);
      expect(last.droppedEntryCount, 2);
      // The most recent entries are preserved; oldest are gone.
      final texts = last.entries
          .map(
            (e) =>
                ((e as AcpMessageEntry).content.single as AcpTextContent).text,
          )
          .toList();
      expect(texts, ['msg2', 'msg3', 'msg4']);
    });

    test('truncates a single oversized text chunk', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(maxEntryBytes: 16),
      );
      final timeline = _run(builder, [
        _chunk('agent_message_chunk', 'x' * 1000, messageId: 'm1'),
      ]);
      expect(timeline.overflowed, isTrue);
      final entry = timeline.entries.single as AcpMessageEntry;
      final text = (entry.content.single as AcpTextContent).text;
      expect(text.length, lessThan(1000));
      expect(text, contains('truncated'));
    });

    test('keeps a safe pasted image instead of replacing it with a marker', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntryBytes: 512,
          maxRetainedImageBytes: 2 * 1024 * 1024,
          maxTotalBytes: 8 * 1024 * 1024,
        ),
      );
      final image = AcpImageContent(
        data: 'A' * (1024 * 1024),
        mimeType: 'image/png',
      );

      builder.appendLocalUserPrompt([image]);
      final timeline = builder.snapshot();
      final entry = timeline.entries.single as AcpMessageEntry;

      expect(entry.content.single, same(image));
      expect(timeline.overflowed, isFalse);
    });

    test('keeps an image while bounding accompanying pasted text', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntryBytes: 512,
          maxRetainedImageBytes: 2048,
          maxTotalBytes: 8192,
        ),
      );
      final image = AcpImageContent(data: 'A' * 1024, mimeType: 'image/png');

      builder.appendLocalUserPrompt([image, AcpTextContent('x' * 1000)]);
      final timeline = builder.snapshot();
      final content = (timeline.entries.single as AcpMessageEntry).content;

      expect(content.whereType<AcpImageContent>().single, same(image));
      expect(
        content.whereType<AcpTextContent>().single.text,
        contains('truncated'),
      );
    });

    for (final field in ['annotations', 'meta', 'extensions']) {
      for (final image in [true, false]) {
        test('bounds ${image ? 'image' : 'text'} $field', () {
          final large = {'payload': 'x' * 4096};
          final meta = field == 'meta' ? large : <String, Object?>{};
          final extensions = field == 'extensions'
              ? large
              : <String, Object?>{};
          final annotations = field != 'annotations'
              ? null
              : image
              ? AcpAnnotations(extensions: large)
              : AcpAnnotations(meta: large);
          final content = image
              ? AcpImageContent(
                  data: 'AAAA',
                  mimeType: 'image/png',
                  annotations: annotations,
                  meta: meta,
                  extensions: extensions,
                )
              : AcpTextContent(
                  'short',
                  annotations: annotations,
                  meta: meta,
                  extensions: extensions,
                );
          if (image) {
            expect(approximateContentBlockBytes(content), greaterThan(4096));
          }
          final builder = AcpTimelineBuilder(
            limits: const AcpTimelineLimits(maxEntryBytes: 512),
          )..appendLocalUserPrompt([content]);
          final entry = _expectBounded(builder) as AcpMessageEntry;
          if (!image) {
            final text = entry.content.single as AcpTextContent;
            expect(text.text, 'short');
            expect(text.annotations, isNull);
            expect(text.meta, isEmpty);
            expect(text.extensions, isEmpty);
          }
        });
      }
    }

    for (final field in ['meta', 'extensions']) {
      for (final kind in ['content', 'diff', 'terminal']) {
        test('bounds tool $kind wrapper $field', () {
          final large = {'payload': 'x' * 4096};
          final meta = field == 'meta' ? large : <String, Object?>{};
          final extensions = field == 'extensions'
              ? large
              : <String, Object?>{};
          final content = switch (kind) {
            'diff' => AcpToolDiff(
              path: '/file',
              newText: 'x',
              meta: meta,
              extensions: extensions,
            ),
            'terminal' => AcpToolTerminal(
              terminalId: 't1',
              meta: meta,
              extensions: extensions,
            ),
            _ => AcpToolContentBlock(
              content: const AcpTextContent('short'),
              meta: meta,
              extensions: extensions,
            ),
          };
          final builder =
              AcpTimelineBuilder(
                limits: const AcpTimelineLimits(maxEntryBytes: 512),
              )..apply(
                AcpToolCallUpdate(
                  toolCallId: 'tool',
                  isInitial: true,
                  content: [content],
                ),
              );
          _expectBounded(builder);
        });
      }
    }

    test('bounds a single image message to the total budget', () {
      final builder =
          AcpTimelineBuilder(
            limits: const AcpTimelineLimits(
              maxEntryBytes: 8192,
              maxTotalBytes: 512,
            ),
          )..appendLocalUserPrompt([
            AcpImageContent(data: 'A' * 4096, mimeType: 'image/png'),
          ]);
      _expectBounded(builder);
    });

    test('retained image metadata counts toward the total budget', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntryBytes: 2048,
          maxTotalBytes: 4096,
        ),
      );
      for (var index = 0; index < 10; index++) {
        builder.appendLocalUserPrompt([
          AcpImageContent(
            data: 'AAAA',
            mimeType: 'image/png',
            meta: {'payload': '$index${'x' * 1024}'},
          ),
        ]);
      }
      final timeline = builder.snapshot();
      expect(timeline.droppedEntryCount, greaterThan(0));
      expect(
        timeline.entries.fold<int>(
          0,
          (sum, entry) => sum + approximateTimelineEntryBytes(entry),
        ),
        lessThanOrEqualTo(4096),
      );
    });

    test('still omits an image above the dedicated media budget', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntryBytes: 32,
          maxRetainedImageBytes: 64,
          maxTotalBytes: 8192,
        ),
      );

      final timeline =
          (builder..appendLocalUserPrompt([
                AcpImageContent(data: 'A' * 1024, mimeType: 'image/png'),
              ]))
              .snapshot();
      final content = (timeline.entries.single as AcpMessageEntry).content;

      expect(content.single, isA<AcpTextContent>());
      expect((content.single as AcpTextContent).text, contains('omitted'));
      expect(timeline.overflowed, isTrue);
    });

    test('bounds a single message entry even when thousands of small chunks '
        'share the same message id', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntries: 1000,
          maxEntryBytes: 2048,
          maxTotalBytes: 1 << 30,
        ),
      );
      AcpTimeline? last;
      for (var i = 0; i < 5000; i++) {
        last = builder.apply(
          _chunk('agent_message_chunk', 'chunk-$i ', messageId: 'm1'),
        );
      }
      // Still exactly one entry: every chunk shared the same message id, so
      // nothing should ever split into a second timeline entry.
      expect(last!.entries, hasLength(1));
      expect(last.overflowed, isTrue);
      final entry = last.entries.single as AcpMessageEntry;
      expect(approximateTimelineEntryBytes(entry), lessThanOrEqualTo(2048));
      // The most recent chunks are preserved; the earliest are dropped.
      final joined = entry.content
          .whereType<AcpTextContent>()
          .map((c) => c.text)
          .join();
      expect(joined, contains('chunk-4999'));
      expect(joined, isNot(contains('chunk-0 ')));
    });

    test('keeps a near-limit 4000-chunk replay below the ANR budget', () {
      final builder = AcpTimelineBuilder();
      final elapsed = Stopwatch()..start();

      for (var index = 0; index < 4000; index++) {
        builder.apply(
          _chunk(
            'agent_message_chunk',
            '${'x' * 200}$index',
            messageId: 'large-replay',
          ),
        );
      }

      expect(builder.snapshot().entries, hasLength(1));
      expect(
        elapsed.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason:
            'immutable historical blocks must not be JSON-encoded again for '
            'every later append on the UI isolate',
      );
    });

    test('a single accumulating message entry never grows the whole timeline '
        'past its total byte budget', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntries: 1000,
          maxEntryBytes: 512,
          maxTotalBytes: 1024,
        ),
      );
      AcpTimeline? last;
      for (var i = 0; i < 2000; i++) {
        last = builder.apply(
          _chunk('agent_message_chunk', 'x' * 10, messageId: 'm1'),
        );
      }
      expect(last!.entries, hasLength(1));
      expect(last.overflowed, isTrue);
      // The single entry's own cap keeps the whole timeline well within
      // its total budget too.
      final total = last.entries.fold<int>(
        0,
        (sum, entry) => sum + approximateTimelineEntryBytes(entry),
      );
      expect(total, lessThanOrEqualTo(1024));
    });

    test('drops oldest entries once the total byte budget is exceeded', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxEntries: 1000,
          maxTotalBytes: 200,
          maxEntryBytes: 1000,
        ),
      );
      AcpTimeline? last;
      for (var i = 0; i < 20; i++) {
        last = builder.apply(
          _chunk('agent_message_chunk', 'x' * 40, messageId: 'm$i'),
        );
      }
      expect(last!.overflowed, isTrue);
      expect(last.entries.length, lessThan(20));
      expect(last.droppedEntryCount, greaterThan(0));
    });

    test('truncates an oversized merged tool-call payload', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(maxEntryBytes: 32),
      );
      final timeline = _run(builder, [
        AcpToolCallUpdate(
          toolCallId: 't1',
          isInitial: true,
          title: 'Read',
          rawOutput: 'y' * 1000,
        ),
      ]);
      expect(timeline.overflowed, isTrue);
      final entry = timeline.entries.single as AcpToolCallEntry;
      expect(entry.title, 'Read');
      expect(entry.rawOutput, isNot('y' * 1000));
    });

    for (final field in ['path', 'meta', 'extensions', 'title', 'total']) {
      test('bounds oversized tool $field and preserves update identity', () {
        final large = '😀' * (field == 'total' ? 150 : 1024 * 1024);
        final titleOnly = field == 'title' || field == 'total';
        const smallLocation = AcpToolLocation(path: '/keep.dart', line: 7);
        final location = AcpToolLocation(
          path: field == 'path' ? large : '/large.dart',
          meta: field == 'meta' ? {'payload': large} : const {},
          extensions: field == 'extensions' ? {'payload': large} : const {},
        );
        final builder =
            AcpTimelineBuilder(
              limits: const AcpTimelineLimits(
                maxEntryBytes: 1024,
                maxTotalBytes: 512,
              ),
            )..apply(
              AcpToolCallUpdate(
                toolCallId: 'bounded',
                isInitial: true,
                title: titleOnly ? large : 'Read',
                status: AcpToolStatus.inProgress,
                locations: [if (!titleOnly) location, smallLocation],
              ),
            );
        final snapshot = builder.snapshot();
        final entry = snapshot.entries.single as AcpToolCallEntry;
        expect(snapshot.overflowed, isTrue);
        expect(approximateTimelineEntryBytes(entry), lessThanOrEqualTo(512));
        expect(entry.locations, [smallLocation]);
        expect(entry.title, titleOnly ? '😀' * 64 : 'Read');
        builder.apply(
          const AcpToolCallUpdate(
            toolCallId: 'bounded',
            status: AcpToolStatus.completed,
          ),
        );
        final merged = builder.snapshot().entries.single as AcpToolCallEntry;
        expect(merged.toolCallId, 'bounded');
        expect(merged.order, entry.order);
        expect(merged.status, AcpToolStatus.completed);
        expect(merged.locations, [smallLocation]);
      });
    }

    test('never drops below one entry even when it alone exceeds the '
        'total byte budget', () {
      final builder = AcpTimelineBuilder(
        limits: const AcpTimelineLimits(
          maxTotalBytes: 1,
          maxEntryBytes: 1 << 30,
        ),
      );
      final timeline = _run(builder, [
        _chunk('agent_message_chunk', 'single entry', messageId: 'm1'),
      ]);
      expect(timeline.entries, hasLength(1));
    });

    test('keeps unaffected timelines free of overflow state', () {
      final timeline = _run(AcpTimelineBuilder(), [
        _chunk('agent_message_chunk', 'small', messageId: 'm1'),
      ]);
      expect(timeline.overflowed, isFalse);
      expect(timeline.droppedEntryCount, 0);
    });
  });

  group('defensive lists', () {
    test('timeline entries are defensively copied and unmodifiable', () {
      final content = <AcpContentBlock>[const AcpTextContent('a')];
      final entry = AcpMessageEntry(
        role: AcpMessageRole.agent,
        order: 0,
        content: content,
      );
      content.clear();
      expect(entry.content, hasLength(1));
      expect(entry.content.clear, throwsUnsupportedError);
    });

    test(
      'AcpTimeline copies the caller list and exposes an immutable view',
      () {
        final entries = <AcpTimelineEntry>[
          AcpMessageEntry(role: AcpMessageRole.user, order: 0),
        ];
        final timeline = AcpTimeline(entries: entries);
        entries.clear();
        expect(timeline.entries, hasLength(1));
        expect(timeline.entries.clear, throwsUnsupportedError);
      },
    );
  });
}

AcpTimelineEntry _expectBounded(AcpTimelineBuilder builder) {
  final timeline = builder.snapshot();
  expect(timeline.overflowed, isTrue);
  final entry = timeline.entries.single;
  expect(approximateTimelineEntryBytes(entry), lessThanOrEqualTo(512));
  return entry;
}
