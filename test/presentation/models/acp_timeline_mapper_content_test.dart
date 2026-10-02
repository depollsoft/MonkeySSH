import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart' as p;
import 'package:monkeyssh/presentation/models/acp_timeline_mapper.dart';

List<p.AcpTimelineEntry> _map(List<AcpTimelineEntry> entries) {
  final now = DateTime(2026);
  return mapAcpSessionTimeline(
    AcpSessionState(
      key: AcpSessionKey.of(
        hostId: 1,
        providerId: 'copilot',
        bridgeId: 'bridge',
        acpSessionId: 'session',
      ),
      providerLabel: 'Copilot',
      cwd: '/home',
      status: AcpConnectionStatus.ready,
      createdAt: now,
      lastActivityAt: now,
      timeline: AcpTimeline(entries: entries),
    ),
  );
}

p.AcpToolCall _mapTool(Map<String, Object?> update) {
  final entry = AcpToolCallEntry(toolCallId: 't', order: 0).merge(
    AcpToolCallUpdate.fromJson(<String, Object?>{'toolCallId': 't', ...update}),
  );
  return (_map([entry]).single as p.AcpToolCallEntry).toolCall;
}

AcpMessageEntry _message(
  AcpMessageRole role,
  List<Map<String, Object?>> json,
) => AcpMessageEntry(
  role: role,
  order: 0,
  content: [for (final block in json) AcpContentBlock.fromJson(block)],
);

void main() {
  test('collects embedded terminals, resources, name, and switch_mode', () {
    final tool = _mapTool({
      'title': 'Run tests',
      'name': 'Bash',
      'kind': 'switch_mode',
      'content': [
        {'type': 'terminal', 'terminalId': 'term-1'},
        {'type': 'terminal', 'terminalId': 'term-1'},
        {
          'type': 'content',
          'content': {
            'type': 'resource_link',
            'uri': 'file:///work/report.txt',
            'name': 'report.txt',
            'size': 12,
          },
        },
        {
          'type': 'content',
          'content': {
            'type': 'resource',
            'resource': {
              'uri': 'mem://notes',
              'text': 'embedded notes',
              'mimeType': 'text/plain',
            },
          },
        },
      ],
    });

    expect(tool.kind, p.AcpToolKind.switchMode);
    expect(tool.name, 'Bash');
    expect(tool.terminalIds, ['term-1']);
    expect(tool.resources, hasLength(2));
    expect(tool.resources.first.displayName, 'report.txt');
    expect(tool.resources.first.sizeBytes, 12);
    expect(tool.resources.last.text, 'embedded notes');
  });

  test('hides content whose audience excludes the user', () {
    final tool = _mapTool({
      'content': [
        {
          'type': 'content',
          'content': {
            'type': 'text',
            'text': 'model-only context',
            'annotations': {
              'audience': ['assistant'],
            },
          },
        },
        {
          'type': 'content',
          'content': {
            'type': 'text',
            'text': 'shown to everyone',
            'annotations': {
              'audience': ['user', 'assistant'],
            },
          },
        },
      ],
    });
    expect(tool.rawOutput, 'shown to everyone');

    final message =
        _map([
              _message(AcpMessageRole.agent, [
                {
                  'type': 'text',
                  'text': 'secret plan',
                  'annotations': {
                    'audience': ['assistant'],
                  },
                },
                {'type': 'text', 'text': 'Visible answer'},
              ]),
            ]).single
            as p.AcpAssistantMessageEntry;
    expect(message.markdown, 'Visible answer');
  });

  test('renders an embedded text resource in a reply as a code block', () {
    final message =
        _map([
              _message(AcpMessageRole.agent, [
                {'type': 'text', 'text': 'Here it is:'},
                {
                  'type': 'resource',
                  'resource': {
                    'uri': 'file:///work/lib/main.dart',
                    'text': 'void main() {}\n// ``` fence inside',
                  },
                },
                {
                  'type': 'resource',
                  'resource': {
                    'uri': 'file:///work/logo.png',
                    'blob': 'AAAA',
                    'mimeType': 'image/png',
                  },
                },
              ]),
            ]).single
            as p.AcpAssistantMessageEntry;

    expect(message.markdown, contains('`main.dart`'));
    // The fence is longer than the backtick run inside the contents.
    expect(
      message.markdown,
      contains('````dart\nvoid main() {}\n// ``` fence inside\n````'),
    );
    expect(message.markdown, contains('[logo.png](<file:///work/logo.png>)'));
  });

  test('keeps embedded resource text viewable in user prompts', () {
    final prompt =
        _map([
              _message(AcpMessageRole.user, [
                {
                  'type': 'resource',
                  'resource': {
                    'uri': 'file:///work/notes.md',
                    'text': '# Notes',
                    'mimeType': 'text/markdown',
                  },
                },
              ]),
            ]).single
            as p.AcpUserPromptEntry;
    final resource = (prompt.parts.single as p.AcpResourcePart).resource;
    expect(resource.text, '# Notes');
    expect(resource.mimeType, 'text/markdown');
  });
}
