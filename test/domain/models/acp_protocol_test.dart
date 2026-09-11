import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';

class _UnreadableMap extends MapBase<String, Object?> {
  @override
  Iterable<String> get keys => throw StateError('Discarded entry traversed');
  @override
  Object? operator [](Object? key) => throw StateError('Discarded entry read');
  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

void main() {
  test('parses capabilities and preserves unknown extensions', () {
    final result = AcpInitializeResult.fromJson({
      'protocolVersion': 1,
      'agentCapabilities': {
        'loadSession': true,
        'promptCapabilities': {
          'image': true,
          'audio': true,
          'embeddedContext': true,
          'futurePrompt': 1,
        },
        'mcpCapabilities': {'http': true, 'sse': false},
        'sessionCapabilities': {
          'list': true,
          'fork': <String, Object?>{},
          'resume': <String, Object?>{},
          '_future': true,
        },
        '_meta': {'vendor': 'example'},
      },
      'authMethods': [
        {
          'id': 'browser',
          'name': 'Browser login',
          'type': 'agent',
          'futureAuth': true,
        },
      ],
      'futureInitialize': {'enabled': true},
    });

    expect(result.agentCapabilities.loadSession, isTrue);
    expect(result.agentCapabilities.prompt.image, isTrue);
    expect(result.agentCapabilities.prompt.audio, isTrue);
    expect(result.agentCapabilities.prompt.embeddedContext, isTrue);
    expect(result.agentCapabilities.mcp.http, isTrue);
    expect(result.agentCapabilities.session.list, isTrue);
    expect(result.agentCapabilities.session.fork, isTrue);
    expect(result.agentCapabilities.session.resume, isTrue);
    expect(result.agentCapabilities.meta['vendor'], 'example');
    expect(result.agentCapabilities.prompt.extensions['futurePrompt'], 1);
    expect(result.authMethods.single.extensions['futureAuth'], isTrue);
    expect(result.extensions, contains('futureInitialize'));
  });

  test('parses every ACP content shape and unknown content', () {
    final blocks = <AcpContentBlock>[
      AcpContentBlock.fromJson({'type': 'text', 'text': 'hello'}),
      AcpContentBlock.fromJson({
        'type': 'image',
        'data': 'aW1hZ2U=',
        'mimeType': 'image/png',
        'uri': 'file:///image.png',
      }),
      AcpContentBlock.fromJson({
        'type': 'audio',
        'data': 'YXVkaW8=',
        'mimeType': 'audio/wav',
      }),
      AcpContentBlock.fromJson({
        'type': 'resource',
        'resource': {
          'uri': 'file:///notes.txt',
          'text': 'notes',
          'mimeType': 'text/plain',
        },
      }),
      AcpContentBlock.fromJson({
        'type': 'resource_link',
        'name': 'notes.txt',
        'uri': 'file:///notes.txt',
        'size': 5,
      }),
      AcpContentBlock.fromJson({
        'type': 'future_content',
        'payload': {'value': 1},
        '_meta': {'vendor': true},
      }),
    ];

    expect(blocks[0], isA<AcpTextContent>());
    expect(blocks[1], isA<AcpImageContent>());
    expect(blocks[2], isA<AcpAudioContent>());
    expect(blocks[3], isA<AcpResourceContent>());
    expect(blocks[4], isA<AcpResourceLinkContent>());
    final unknown = blocks[5] as AcpUnknownContent;
    expect(unknown.raw['payload'], {'value': 1});
    expect(unknown.meta['vendor'], isTrue);
  });

  test('parses major session update shapes', () {
    final updates = <AcpSessionUpdate>[
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'message-1',
        'content': {'type': 'text', 'text': 'Hello'},
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'agent_thought_chunk',
        'content': {'type': 'text', 'text': 'Thinking'},
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'plan',
        'entries': [
          {'content': 'Implement', 'priority': 'high', 'status': 'in_progress'},
        ],
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'tool-1',
        'title': 'Edit file',
        'kind': 'edit',
        'status': 'pending',
        'content': [
          {'type': 'text', 'text': 'Preparing'},
          {
            'type': 'diff',
            'path': '/repo/a.dart',
            'oldText': 'a',
            'newText': 'b',
          },
          {'type': 'terminal', 'terminalId': 'terminal-1'},
        ],
        'locations': [
          {'path': '/repo/a.dart', 'line': 3},
        ],
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'tool-1',
        'status': 'completed',
        'rawOutput': {'count': 1},
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'available_commands_update',
        'availableCommands': [
          {
            'name': 'review',
            'description': 'Review changes',
            'input': {'hint': 'scope'},
          },
        ],
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'current_mode_update',
        'currentModeId': 'code',
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'config_option_update',
        'configOptions': [
          {
            'id': 'model',
            'name': 'Model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'fast',
            'options': [
              {'value': 'fast', 'name': 'Fast'},
            ],
          },
          {
            'id': 'brave',
            'name': 'Brave',
            'type': 'boolean',
            'currentValue': true,
          },
        ],
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'session_info_update',
        'title': null,
        'updatedAt': '2026-07-11T20:00:00Z',
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': 'usage_update',
        'used': 123,
        'size': 1000,
        'cost': {'amount': 0.2, 'currency': 'USD'},
      }),
      AcpSessionUpdate.fromJson({
        'sessionUpdate': '_vendor_update',
        'newField': 42,
        '_meta': {'vendor': 'example'},
      }),
    ];

    expect(updates[0], isA<AcpContentChunkUpdate>());
    expect(updates[1], isA<AcpContentChunkUpdate>());
    expect(updates[2], isA<AcpPlanUpdate>());
    final toolCall = updates[3] as AcpToolCallUpdate;
    expect(toolCall.isInitial, isTrue);
    expect(toolCall.content, hasLength(3));
    expect(toolCall.content!.first, isA<AcpToolContentBlock>());
    expect(toolCall.content![1], isA<AcpToolDiff>());
    expect(toolCall.content![2], isA<AcpToolTerminal>());
    expect(updates[4], isA<AcpToolCallUpdate>());
    expect(updates[5], isA<AcpAvailableCommandsUpdate>());
    expect(updates[6], isA<AcpCurrentModeUpdate>());
    final config = updates[7] as AcpConfigOptionsUpdate;
    expect(config.options.first, isA<AcpSelectConfigOption>());
    expect(config.options.last, isA<AcpBooleanConfigOption>());
    final info = updates[8] as AcpSessionInfoUpdate;
    expect(info.hasTitle, isTrue);
    expect(info.title, isNull);
    expect(updates[9], isA<AcpUsageUpdate>());
    final unknown = updates[10] as AcpUnknownSessionUpdate;
    expect(unknown.extensions['newField'], 42);
    expect(unknown.meta['vendor'], 'example');
  });

  test('tool update lists skip malformed entries and remain immutable', () {
    final update = AcpToolCallUpdate.fromJson({
      'toolCallId': 'tool-1',
      'content': [
        null,
        1,
        {'type': 'terminal', 'terminalId': 'terminal-1'},
      ],
      'locations': [
        false,
        'bad',
        {'path': '/repo/a.dart', 'line': 3},
      ],
    });
    expect(
      (update.content!.single as AcpToolTerminal).terminalId,
      'terminal-1',
    );
    expect(update.locations!.single.path, '/repo/a.dart');
    expect(() => update.content!.clear(), throwsUnsupportedError);
    expect(() => update.locations!.clear(), throwsUnsupportedError);
    for (final raw in [null, 'bad', 1, <String, Object?>{}]) {
      final partial = AcpToolCallUpdate.fromJson({
        'content': raw,
        'locations': raw,
      });
      expect(partial.content, isNull);
      expect(partial.locations, isNull);
    }
    final omitted = AcpToolCallUpdate.fromJson({});
    expect(omitted.content, isNull);
    expect(omitted.locations, isNull);
    for (final raw in [
      <Object?>[],
      [null, 1],
    ]) {
      final empty = AcpToolCallUpdate.fromJson({
        'content': raw,
        'locations': raw,
      });
      expect(empty.content, isEmpty);
      expect(empty.locations, isEmpty);
    }
  });

  test('permission and configuration lists tolerate malformed entries', () {
    for (final raw in [
      null,
      'bad',
      <Object?>[],
      [null, 1],
    ]) {
      expect(AcpPermissionRequest.fromJson({'options': raw}).options, isEmpty);
      expect(AcpConfigValueGroup.fromJson({'options': raw}).options, isEmpty);
    }
    final permission = AcpPermissionRequest.fromJson({
      'options': [
        null,
        1,
        {'optionId': 'allow', 'kind': 'allow_once'},
      ],
    });
    final group = AcpConfigValueGroup.fromJson({
      'options': [
        false,
        'bad',
        {'value': 'fast', 'name': 'Fast'},
      ],
    });
    expect(permission.options.single.id, 'allow');
    expect(group.options.single.value, 'fast');
    expect(permission.options.clear, throwsUnsupportedError);
    expect(group.options.clear, throwsUnsupportedError);
  });

  test('normalizes Grok metadata-only reasoning modes', () {
    final result = AcpSessionSetupResult.fromJson({
      'sessionId': 'grok-session',
      '_meta': {
        'x.ai/sessionConfig': {
          'options': [
            {
              'id': 'grok-4.6',
              'category': 'model',
              'label': 'Grok 4.6',
              'selected': true,
            },
            {
              'id': 'high',
              'category': 'mode',
              'label': 'High Effort',
              'description': 'Higher implementation quality',
              'selected': true,
            },
            {
              'id': 'low',
              'category': 'mode',
              'label': 'Low Effort',
              'selected': false,
            },
          ],
        },
      },
    });

    expect(result.modes?.currentModeId, 'high');
    expect(result.modes?.availableModes.map((mode) => mode.id), [
      'high',
      'low',
    ]);
    expect(result.modes?.availableModes.first.name, 'High Effort');
    expect(result.modes?.availableModes.first.description, contains('quality'));
  });

  test('bounds provider plan entry count and content', () {
    final update =
        AcpSessionUpdate.fromJson({
              'sessionUpdate': 'plan',
              'entries': [
                for (var index = 0; index < acpMaxPlanEntries; index++)
                  {
                    'content': 'x' * (acpMaxPlanEntryCharacters + 10),
                    'priority': 'medium',
                    'status': 'pending',
                  },
                _UnreadableMap(),
              ],
            })
            as AcpPlanUpdate;

    expect(update.entries, hasLength(acpMaxPlanEntries));
    expect(update.entries.first.content, hasLength(acpMaxPlanEntryCharacters));
  });

  test('parses permissions and forward-compatible stop reasons', () {
    final permission = AcpPermissionRequest.fromJson({
      'sessionId': 'session-1',
      'toolCall': {
        'toolCallId': 'tool-1',
        'title': 'Run tests',
        'kind': 'execute',
      },
      'options': [
        {'optionId': 'yes', 'name': 'Allow', 'kind': 'allow_once'},
      ],
    });
    final prompt = AcpPromptResult.fromJson({
      'stopReason': 'future_stop_reason',
    });

    expect(permission.toolCall.toolCallId, 'tool-1');
    expect(permission.options.single.kind.value, 'allow_once');
    expect(prompt.stopReason.value, 'future_stop_reason');
  });
}
