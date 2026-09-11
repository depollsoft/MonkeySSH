// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart' as p;
import 'package:monkeyssh/presentation/models/acp_timeline_mapper.dart';

AcpSessionKey _key() => AcpSessionKey.of(
  hostId: 1,
  providerId: 'copilot',
  bridgeId: 'bridge',
  acpSessionId: 'session',
);

AcpSessionState _state({
  required AcpTimeline timeline,
  AcpPromptStatus promptStatus = AcpPromptStatus.idle,
  List<AcpPlanEntry> plan = const <AcpPlanEntry>[],
  AcpUsageUpdate? usage,
  AcpSessionError? error,
  AcpSessionError? warning,
  AcpConnectionStatus status = AcpConnectionStatus.ready,
  AcpStopReason? lastStopReason,
}) {
  final now = DateTime(2026);
  return AcpSessionState(
    key: _key(),
    providerLabel: 'Copilot',
    cwd: '/home',
    status: status,
    createdAt: now,
    lastActivityAt: now,
    promptStatus: promptStatus,
    plan: plan,
    usage: usage,
    error: error,
    warning: warning,
    lastStopReason: lastStopReason,
    timeline: timeline,
  );
}

p.AcpImageContent _mapUserImage(AcpImageContent block) {
  final entries = mapAcpSessionTimeline(
    _state(
      timeline: AcpTimeline(
        entries: [
          AcpMessageEntry(
            role: AcpMessageRole.user,
            order: 0,
            content: [block],
          ),
        ],
      ),
    ),
  );
  return ((entries.single as p.AcpUserPromptEntry).parts.single
          as p.AcpImagePart)
      .image;
}

void main() {
  test('builds previews from only the newest lines in chronological order', () {
    final entries = <p.AcpTimelineEntry>[
      for (var index = 0; index < 20; index++)
        p.AcpAssistantMessageEntry(
          id: 'preview-$index',
          markdown: 'message $index',
        ),
    ];

    expect(
      buildAcpConversationPreview(entries, maxLines: 3),
      'Agent: message 17\nAgent: message 18\nAgent: message 19',
    );
  });

  test('memoizes identical immutable session snapshots', () {
    final session = _state(
      timeline: AcpTimeline(
        entries: [
          AcpMessageEntry(
            role: AcpMessageRole.agent,
            order: 0,
            content: const [AcpTextContent('cached')],
          ),
        ],
      ),
    );
    final cache = AcpTimelineMapperCache();

    final first = cache.map(session);
    final second = cache.map(session);
    final afterNavigation = AcpTimelineMapperCache().map(session);

    expect(identical(first, second), isTrue);
    expect(identical(first, afterNavigation), isTrue);
  });

  test('maps ordered user content, assistant markdown, and tool calls', () {
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.user,
          order: 0,
          content: const [
            AcpTextContent('hello'),
            AcpResourceLinkContent(name: 'a.txt', uri: 'file:///a.txt'),
          ],
        ),
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 1,
          content: const [AcpTextContent('Hi '), AcpTextContent('there')],
        ),
        AcpToolCallEntry(
          toolCallId: 't1',
          order: 2,
          title: 'Edit file',
          toolKind: AcpToolKind.edit,
          status: AcpToolStatus.completed,
          locations: const [AcpToolLocation(path: 'lib/a.dart', line: 3)],
          content: const [
            AcpToolDiff(path: 'lib/a.dart', oldText: 'a', newText: 'b'),
            AcpToolContentBlock(
              content: AcpImageContent(data: 'aGk=', mimeType: 'image/png'),
            ),
          ],
        ),
      ],
    );

    final entries = mapAcpSessionTimeline(
      _state(
        timeline: timeline,
        promptStatus: AcpPromptStatus.streaming,
        plan: const [
          AcpPlanEntry(
            content: 'do it',
            priority: AcpPlanPriority.high,
            status: AcpPlanStatus.inProgress,
          ),
        ],
        usage: const AcpUsageUpdate(used: 10, size: 100),
      ),
    );

    final user = entries[0] as p.AcpUserPromptEntry;
    expect(user.parts[0], isA<p.AcpTextPart>());
    expect((user.parts[0] as p.AcpTextPart).text, 'hello');
    expect(user.parts[1], isA<p.AcpResourcePart>());
    expect((user.parts[1] as p.AcpResourcePart).resource.uri, 'file:///a.txt');

    final assistant = entries[1] as p.AcpAssistantMessageEntry;
    expect(assistant.markdown, 'Hi there');
    // The last agent message is the streaming tail while the turn streams.
    expect(assistant.status, p.AcpStreamStatus.streaming);

    final tool = entries[2] as p.AcpToolCallEntry;
    expect(tool.toolCall.kind, p.AcpToolKind.edit);
    expect(tool.toolCall.status, p.AcpToolStatus.completed);
    expect(tool.toolCall.locations.single.line, 3);
    expect(tool.toolCall.diffs.single.unifiedDiff, contains('-a'));
    expect(tool.toolCall.diffs.single.unifiedDiff, contains('+b'));
    expect(tool.toolCall.images, hasLength(1));
    expect(
      tool.toolCall.images.single.dataUri,
      startsWith('data:image/png;base64,'),
    );

    expect(
      entries.whereType<p.AcpPlanEntry>().single.plan.items.single.status,
      p.AcpPlanItemStatus.inProgress,
    );
    final usage = entries.whereType<p.AcpUsageEntry>().single.usage;
    expect(usage.contextUsedTokens, 10);
    expect(usage.contextWindow, 100);
  });

  test('preserves a reported zero usage update', () {
    final entries = mapAcpSessionTimeline(
      _state(
        timeline: AcpTimeline(),
        usage: const AcpUsageUpdate(used: 0, size: 0),
      ),
    );

    final usage = entries.whereType<p.AcpUsageEntry>().single.usage;
    expect(usage.contextUsedTokens, 0);
    expect(usage.contextWindow, 0);
    expect(usage.hasData, isTrue);
  });

  test('groups Claude parent-linked updates under the launching subagent', () {
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 'agent-launch',
          order: 0,
          title: 'Agent',
          isSubagent: true,
        ),
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 1,
          parentToolCallId: 'agent-launch',
          content: const [AcpTextContent('nested response')],
        ),
        AcpToolCallEntry(
          toolCallId: 'nested-tool',
          order: 2,
          title: 'Read',
          parentToolCallId: 'agent-launch',
        ),
      ],
    );

    final entries = mapAcpSessionTimeline(_state(timeline: timeline));

    final launch = entries.first as p.AcpToolCallEntry;
    final nested = entries[1] as p.AcpSubagentTranscriptEntry;
    expect(launch.isSubagent, isTrue);
    expect(nested.launchToolCallId, 'agent-launch');
    expect(nested.entries, hasLength(2));
    expect(nested.entries.first, isA<p.AcpAssistantMessageEntry>());
    expect(nested.entries.last, isA<p.AcpToolCallEntry>());
  });

  test('recovers Pi image blocks retained only in raw tool output', () {
    const imageData = 'aGk=';
    final rawOutput = <String, Object?>{
      'message': 'Rendered image',
      'content': <Object?>[
        <String, Object?>{
          'type': 'image',
          'data': imageData,
          'mimeType': 'image/png',
        },
      ],
    };
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 'pi-image',
          order: 0,
          title: 'read',
          status: AcpToolStatus.completed,
          rawOutput: rawOutput,
          content: [
            AcpToolContentBlock(content: AcpTextContent(jsonEncode(rawOutput))),
          ],
        ),
      ],
    );

    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;

    expect(tool.toolCall.images, hasLength(1));
    expect(
      tool.toolCall.images.single.dataUri,
      'data:image/png;base64,$imageData',
    );
    expect(tool.toolCall.rawOutput, 'Rendered image');
    expect(tool.toolCall.rawOutput, isNot(contains(imageData)));
  });

  test('promotes textual unified diff output to a rich diff model', () {
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 'diff',
          order: 0,
          status: AcpToolStatus.completed,
          content: const [
            AcpToolContentBlock(
              content: AcpTextContent(
                '--- a/lib/a.dart\n'
                '+++ b/lib/a.dart\n'
                '@@ -1 +1 @@\n'
                '-old\n'
                '+new',
              ),
            ),
          ],
        ),
      ],
    );

    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    expect(tool.toolCall.diffs.single.path, 'lib/a.dart');
    expect(tool.toolCall.diffs.single.unifiedDiff, contains('+new'));
    expect(tool.toolCall.rawOutput, isNull);
  });

  test('renders a small unified hunk for a one-line edit', () {
    final oldLines = [
      for (var index = 1; index <= 1000; index++) 'line $index',
    ];
    final newLines = [...oldLines]..[500] = 'line 501 changed';
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 't1',
          order: 0,
          content: [
            AcpToolDiff(
              path: 'lib/large.dart',
              oldText: oldLines.join('\n'),
              newText: newLines.join('\n'),
            ),
          ],
        ),
      ],
    );

    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    final diff = tool.toolCall.diffs.single.unifiedDiff;

    expect(diff, contains('@@ -498,7 +498,7 @@'));
    expect(diff, contains('-line 501'));
    expect(diff, contains('+line 501 changed'));
    expect(diff, contains(' line 498'));
    expect(diff, contains(' line 504'));
    expect(diff, isNot(contains(' line 497')));
    expect(diff, isNot(contains(' line 505')));
    expect(diff.split('\n'), hasLength(11));
  });

  test('separates distant edits into minimal unified hunks', () {
    final oldLines = [for (var index = 1; index <= 30; index++) 'line $index'];
    final newLines = [...oldLines]
      ..[4] = 'line 5 changed'
      ..[24] = 'line 25 changed';
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 't1',
          order: 0,
          content: [
            AcpToolDiff(
              path: 'lib/two_edits.dart',
              oldText: oldLines.join('\n'),
              newText: newLines.join('\n'),
            ),
          ],
        ),
      ],
    );

    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    final diff = tool.toolCall.diffs.single.unifiedDiff;

    expect(RegExp('^@@ ', multiLine: true).allMatches(diff), hasLength(2));
    expect(diff, contains('@@ -2,7 +2,7 @@'));
    expect(diff, contains('@@ -22,7 +22,7 @@'));
    expect(diff, isNot(contains(' line 15')));
  });

  test('assistant message is complete when the turn is idle', () {
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 0,
          content: const [AcpTextContent('done')],
        ),
      ],
    );
    final entries = mapAcpSessionTimeline(_state(timeline: timeline));
    expect(
      (entries.single as p.AcpAssistantMessageEntry).status,
      p.AcpStreamStatus.complete,
    );
  });

  test('retains malformed encoded data and its URI for widget fallback', () {
    final image = _mapUserImage(
      const AcpImageContent(
        data: 'not-base64!!!',
        mimeType: 'image/png',
        uri: 'file:///pic.png',
      ),
    );
    expect(image.dataUri, 'data:image/png;base64,not-base64!!!');
    expect(image.uri, 'file:///pic.png');
    expect(image.bytes, isNull);
  });

  test('prefers streamed tool content over raw Fabric trace envelopes', () {
    final timeline = AcpTimeline(
      entries: [
        AcpToolCallEntry(
          toolCallId: 'fabric',
          order: 0,
          status: AcpToolStatus.inProgress,
          content: const [
            AcpToolContentBlock(content: AcpTextContent('matches: 3')),
          ],
          rawOutput: const {
            'calls': [
              {
                'id': 'internal-call-id',
                'status': 'completed',
                'args': {'pattern': 'needle'},
              },
            ],
            'phases': <Object?>[],
          },
        ),
      ],
    );

    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    expect(tool.toolCall.rawOutput, 'matches: 3');
    expect(tool.toolCall.rawOutput, isNot(contains('internal-call-id')));
    expect(tool.toolCall.rawOutput, isNot(contains('phases')));
  });

  test('reuses unchanged mapped entries during streamed tool updates', () {
    final message = AcpMessageEntry(
      role: AcpMessageRole.user,
      order: 0,
      content: const [AcpTextContent('prompt')],
    );
    final runningTool = AcpToolCallEntry(
      toolCallId: 'tool',
      order: 1,
      status: AcpToolStatus.inProgress,
      rawOutput: const {'matches': 1},
    );
    final completedTool = AcpToolCallEntry(
      toolCallId: 'tool',
      order: 1,
      status: AcpToolStatus.completed,
      rawOutput: const {'matches': 2},
    );
    final cache = AcpTimelineMapperCache();

    final first = cache.map(
      _state(timeline: AcpTimeline(entries: [message, runningTool])),
    );
    final second = cache.map(
      _state(timeline: AcpTimeline(entries: [message, completedTool])),
    );

    expect(identical(first.first, second.first), isTrue);
    expect(identical(first.last, second.last), isFalse);
    final mappedTool = (second.last as p.AcpToolCallEntry).toolCall;
    expect(mappedTool.rawOutput, 'matches: 2');
    expect(mappedTool.rawOutputIsStructured, isTrue);
  });

  test('distills batched Fabric progress instead of dumping trace JSON', () {
    final formatted = formatAcpToolPayload({
      'calls': [
        {
          'id': 'internal-call-id',
          'kind': 'tool',
          'label': 'grep',
          'toolName': 'grep',
          'status': 'completed',
          'args': {'pattern': 'needle', 'path': 'lib'},
          'text': '{"pattern":"needle","path":"lib"}',
          'result': {
            'content': [
              {'type': 'text', 'text': '3 matches'},
            ],
          },
        },
      ],
      'phases': <Object?>[],
    });

    expect(formatted.text, contains('tool: grep'));
    expect(formatted.text, contains('status: completed'));
    expect(formatted.text, contains('pattern: needle'));
    expect(formatted.text, contains('result: 3 matches'));
    expect(formatted.text, isNot(contains('internal-call-id')));
    expect(formatted.text, isNot(contains('text:')));
    expect(formatted.text, isNot(contains('phases')));
  });

  test('formats structured tool payloads as YAML-like progress text', () {
    final formatted = formatAcpToolPayload({
      'path': 'lib/main.dart',
      'options': ['recursive', 3, true],
      'message': 'line one\nline two',
      'nested': {'empty': <Object?>[]},
    });

    expect(
      formatted.text,
      '''
path: lib/main.dart
options:
  - recursive
  - 3
  - true
message: |
  line one
  line two
nested:
  empty: []
'''
          .trim(),
    );
  });

  test('decodes JSON-string tool payloads before formatting', () {
    expect(
      formatAcpToolPayload(
        '{"query":"status: open","limit":5,"hidden":false}',
      ).text,
      '''
query: "status: open"
limit: 5
hidden: false
'''
          .trim(),
    );
  });

  test('reports structure consistently with formatted JSON and plain text', () {
    for (final (input, text, structured) in [
      ('{"answer":42}', 'answer: 42', true),
      ('[1,true]', '- 1\n- true', true),
      ('{invalid}', '{invalid}', false),
      ('plain output', 'plain output', false),
      ('', null, false),
    ]) {
      expect(formatAcpToolPayload(input), (
        text: text,
        isStructured: structured,
      ));
    }
  });

  test('bounds raw traversal and keeps text after the image limit', () {
    var visited = 0;
    Iterable<Object?> output() sync* {
      for (var index = 0; index < 9; index++) {
        yield {'type': 'image', 'uri': 'file:///$index.png', 'text': 'hidden'};
      }
      yield {'text': 'after images'};
      yield {'stdout': 'after images'};
      for (var index = 0; index < 1000; index++) {
        visited++;
        yield null;
      }
      throw StateError('traversal exceeded node budget');
    }

    final tool =
        mapAcpSessionTimeline(
              _state(
                timeline: AcpTimeline(
                  entries: [
                    AcpToolCallEntry(
                      toolCallId: 'bounded',
                      order: 0,
                      rawOutput: output(),
                    ),
                  ],
                ),
              ),
            ).single
            as p.AcpToolCallEntry;
    expect(tool.toolCall.images.map((image) => image.uri), [
      for (var index = 0; index < 8; index++) 'file:///$index.png',
    ]);
    expect(tool.toolCall.rawOutput, 'after images');
    expect(visited, 242);
  });

  test('bounds oversized tool input text', () {
    final huge = 'x' * (kAcpMapperMaxToolTextChars + 100);
    final timeline = AcpTimeline(
      entries: [AcpToolCallEntry(toolCallId: 't', order: 0, rawInput: huge)],
    );
    final tool =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpToolCallEntry;
    expect(tool.toolCall.rawInput!.length, lessThan(huge.length));
    expect(tool.toolCall.rawInput, endsWith('…'));
  });

  test('surfaces a content-free error status entry', () {
    final entries = mapAcpSessionTimeline(
      _state(
        timeline: AcpTimeline(),
        error: const AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message: 'Connection lost',
        ),
      ),
    );
    final status = entries.whereType<p.AcpStatusEntry>().single;
    expect(status.severity, p.AcpStatusSeverity.error);
    expect(status.message, 'Connection lost');
  });

  test('surfaces replay overflow as a non-fatal warning', () {
    final entries = mapAcpSessionTimeline(
      _state(
        timeline: const AcpTimeline.empty(),
        warning: const AcpSessionError(
          kind: AcpSessionErrorKind.replayOverflow,
          message: 'Some detached history could not be replayed.',
        ),
      ),
    );

    final status = entries.whereType<p.AcpStatusEntry>().single;
    expect(status.severity, p.AcpStatusSeverity.warning);
    expect(status.message, contains('history'));
  });

  test('replay overflow does not hide later stop reasons', () {
    final entries = mapAcpSessionTimeline(
      _state(
        timeline: const AcpTimeline.empty(),
        warning: const AcpSessionError(
          kind: AcpSessionErrorKind.replayOverflow,
          message: 'Some detached history could not be replayed.',
        ),
        lastStopReason: AcpStopReason.maxTokens,
      ),
    );

    final statuses = entries.whereType<p.AcpStatusEntry>().toList();
    expect(statuses, hasLength(2));
    expect(statuses.first.message, contains('history'));
    expect(statuses.last.message, contains('token limit'));
  });

  test('reports a stop reason when the turn is idle', () {
    final entries = mapAcpSessionTimeline(
      _state(timeline: AcpTimeline(), lastStopReason: AcpStopReason.maxTokens),
    );
    expect(
      entries.whereType<p.AcpStatusEntry>().single.severity,
      p.AcpStatusSeverity.warning,
    );
  });

  test('embeds a bounded data URI for a URI-less assistant image', () {
    final data = base64.encode(List<int>.filled(16, 2));
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 0,
          content: [
            const AcpTextContent('see: '),
            AcpImageContent(data: data, mimeType: 'image/png'),
          ],
        ),
      ],
    );
    final assistant =
        mapAcpSessionTimeline(_state(timeline: timeline)).single
            as p.AcpAssistantMessageEntry;
    expect(assistant.markdown, startsWith('see: '));
    expect(assistant.markdown, contains('data:image/png;base64,$data'));
  });

  for (final (size, uri) in [
    (16, null),
    (6 * 1024 * 1024, 'attachment://local/large.png'),
    (kAcpAttachmentImageDisplayMaxBytes, 'attachment://local/large.png'),
  ]) {
    test(
      'preserves $size bytes of image data for users, tools, and assistants',
      () {
        final data = base64.encode(List<int>.filled(size, 1));
        final block = AcpImageContent(data: data, mimeType: 'image/png');
        final timeline = AcpTimeline(
          entries: [
            AcpMessageEntry(
              role: AcpMessageRole.user,
              order: 0,
              content: [
                AcpImageContent(data: data, mimeType: 'image/png', uri: uri),
              ],
            ),
            AcpToolCallEntry(
              toolCallId: 'image',
              order: 1,
              content: [AcpToolContentBlock(content: block)],
            ),
            AcpMessageEntry(
              role: AcpMessageRole.agent,
              order: 2,
              content: [block],
            ),
          ],
        );
        final entries = mapAcpSessionTimeline(_state(timeline: timeline));
        final user = entries[0] as p.AcpUserPromptEntry;
        final tool = entries[1] as p.AcpToolCallEntry;
        final assistant = entries[2] as p.AcpAssistantMessageEntry;
        final dataUri = 'data:image/png;base64,$data';
        final image = (user.parts.single as p.AcpImagePart).image;
        expect(image.dataUri, dataUri);
        expect(image.bytes, isNull);
        expect(image.uri, uri);
        expect(tool.toolCall.images.single.dataUri, dataUri);
        expect(assistant.markdown, '\n\n![image]($dataUri)');
      },
    );
  }

  test('drops oversized image data without a URI and never decodes it', () {
    // A base64 string whose *estimated* decoded size exceeds the inline bound;
    // the mapper must skip it via preflight rather than allocating/decoding.
    final oversized = 'A' * (kAcpAttachmentImageDisplayMaxBytes * 4 ~/ 3 + 8);
    final timeline = AcpTimeline(
      entries: [
        AcpMessageEntry(
          role: AcpMessageRole.user,
          order: 0,
          content: [AcpImageContent(data: oversized, mimeType: 'image/png')],
        ),
        AcpMessageEntry(
          role: AcpMessageRole.agent,
          order: 1,
          content: [AcpImageContent(data: oversized, mimeType: 'image/png')],
        ),
      ],
    );
    final entries = mapAcpSessionTimeline(_state(timeline: timeline));
    // The user prompt held only an undisplayable image, so it maps to no
    // renderable parts and is omitted.
    expect(entries.whereType<p.AcpUserPromptEntry>(), isEmpty);
    final assistant = entries.whereType<p.AcpAssistantMessageEntry>().single;
    expect(assistant.markdown, isEmpty);
  });

  test('falls back to the URI for an oversized image that has one', () {
    final oversized = 'A' * (kAcpAttachmentImageDisplayMaxBytes * 4 ~/ 3 + 8);
    final image = _mapUserImage(
      AcpImageContent(
        data: oversized,
        mimeType: 'image/png',
        uri: 'file:///big.png',
      ),
    );
    expect(image.uri, 'file:///big.png');
    expect(image.bytes, isNull);
  });
}
