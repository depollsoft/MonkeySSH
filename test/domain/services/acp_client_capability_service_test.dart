import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/mock_ssh_exec_session.dart';

void main() {
  group('AcpClientCapabilityService', () {
    late _ServerTransport transport;
    late AcpClient client;
    late _FakeFileSystem files;
    late _FakeTerminalExecutor terminals;
    late AcpPendingRequestRegistry registry;
    late AcpClientCapabilityService service;

    setUp(() {
      transport = _ServerTransport();
      client = AcpClient(AcpJsonRpcConnection(transport: transport));
      files = _FakeFileSystem();
      terminals = _FakeTerminalExecutor();
      registry = AcpPendingRequestRegistry();
      service = AcpClientCapabilityService(
        fileSystem: files,
        terminalExecutor: terminals,
        allowedRoots: const ['/workspace', '/C:/workspace'],
        registry: registry,
        limits: const AcpClientCapabilityLimits(
          maxFileBytes: 16,
          maxWriteBytes: 16,
          maxTerminalOutputBytes: 2048,
          maxTerminals: 2,
        ),
      )..attach(client);
    });

    tearDown(() async {
      await service.close();
      await client.close();
    });

    group('SSH terminal opening', () {
      const limits = AcpClientCapabilityLimits(
        maxTerminals: 1,
        maxTerminalLifetime: Duration(seconds: 30),
      );
      late _MockSshSession session;
      late Completer<SSHSession> opening;
      late _MockTerminalSession channel;

      Future<void> configureSshTerminal() async {
        // Closing inside the fake-async test body would wait on timers that
        // never elapse; let the tearDown (real time) close the setUp instances.
        final setUpService = service;
        final setUpClient = client;
        addTearDown(() async {
          await setUpService.close();
          await setUpClient.close();
        });
        transport = _ServerTransport();
        client = AcpClient(AcpJsonRpcConnection(transport: transport));
        session = _MockSshSession();
        opening = Completer<SSHSession>();
        channel = _MockTerminalSession();
        final exit = Completer<int?>();
        when(() => session.execute(any())).thenAnswer((_) => opening.future);
        when(() => channel.stdout).thenAnswer((_) => const Stream.empty());
        when(() => channel.stderr).thenAnswer((_) => const Stream.empty());
        when(channel.waitForExit).thenAnswer((_) => exit.future);
        when(channel.close).thenAnswer((_) {
          if (!exit.isCompleted) exit.complete(-1);
        });
        service = AcpClientCapabilityService(
          fileSystem: files,
          terminalExecutor: AcpSshTerminalExecutor(
            () async => session,
            remoteIsWindows: false,
            openTimeout: limits.terminalOpenTimeout,
          ),
          allowedRoots: const ['/workspace'],
          registry: registry,
          limits: limits,
        )..attach(client);
      }

      void createTerminal(String id) => transport.sendRequest(
        id,
        'terminal/create',
        {'sessionId': 'session-1', 'command': 'long-task'},
      );

      for (final arrivesLate in [false, true]) {
        testWidgets(
          'releases the reservation at the open deadline when the channel '
          '${arrivesLate ? 'arrives late and closes it' : 'never opens'}',
          (tester) async {
            await configureSshTerminal();
            createTerminal('stalled');
            await tester.pump();
            await tester.pump(const Duration(seconds: 9));
            expect(transport.responseForOrNull('stalled'), isNull);

            createTerminal('at-capacity');
            await tester.pump();
            expect(transport.responseFor('at-capacity')['error'], {
              'code': -32000,
              'message': 'Too many active terminals',
            });

            await tester.pump(const Duration(seconds: 1));
            expect(transport.responseFor('stalled')['error'], {
              'code': -32000,
              'message': 'Terminal channel opening timed out',
            });

            when(() => session.execute(any())).thenAnswer((_) async => channel);
            createTerminal('retry');
            await tester.pump();
            expect(transport.responseFor('retry')['result'], isNotNull);
            verify(() => session.execute(any())).called(2);

            if (arrivesLate) {
              final lateChannel = _MockTerminalSession();
              opening.complete(lateChannel);
              await tester.pump();
              verify(lateChannel.channel.destroy).called(1);
            }
            verifyNever(channel.close);
            await tester.pump(limits.maxTerminalLifetime);
            verify(channel.close).called(1);
          },
        );
      }

      testWidgets('installs the lifetime timer after a normal open', (
        tester,
      ) async {
        await configureSshTerminal();
        createTerminal('normal');
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        opening.complete(channel);
        await tester.pump();
        expect(transport.responseFor('normal')['result'], isNotNull);

        await tester.pump(
          limits.maxTerminalLifetime - const Duration(seconds: 1),
        );
        verifyNever(channel.close);
        await tester.pump(const Duration(seconds: 1));
        verify(channel.close).called(1);
      });
    });

    test('advertises only configured capabilities', () {
      expect(service.capabilities.fileSystem?.readTextFile, isTrue);
      expect(service.capabilities.fileSystem?.writeTextFile, isTrue);
      expect(service.capabilities.terminal, isTrue);
      expect(
        AcpClientCapabilityService(
          fileSystem: null,
          terminalExecutor: null,
          allowedRoots: const [],
          registry: AcpPendingRequestRegistry(),
        ).capabilities.toJson(),
        {
          '_meta': {'subagent-transcript': true, 'terminal-auth': true},
          'terminal': false,
          'session': {
            'configOptions': {'boolean': {}},
          },
        },
      );
    });

    test('retains permissions and answers with exact option IDs', () async {
      transport.sendRequest('permission-1', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-1'},
        'options': [
          {'optionId': 'agent-option', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      await _settle();

      expect(registry.requests, hasLength(1));
      await service.selectPermission('s:permission-1', 'agent-option');

      expect(transport.responseFor('permission-1')['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'agent-option'},
      });
      expect(registry.requests, isEmpty);
    });

    test('invalid permission selections leave the request retryable', () async {
      transport.sendRequest('permission-1', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-1'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      await _settle();
      final pending = registry.requests.single;

      await expectLater(
        service.selectPermission('s:permission-1', 'unknown'),
        throwsArgumentError,
      );
      expect(registry.requests.single, same(pending));
      expect(transport.responseForOrNull('permission-1'), isNull);
      await service.selectPermission('s:permission-1', 'allow');
      expect(transport.responseFor('permission-1')['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      expect(registry.requests, isEmpty);
    });

    for (final change in ['session', 'tool', 'option', 'method']) {
      test(
        'rejects a replay that changes the $change without rebinding',
        () async {
          final params = <String, Object?>{
            'sessionId': 'session-1',
            'toolCall': {'toolCallId': 'call-1'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            ],
          };
          transport.sendRequest(
            'replayed',
            'session/request_permission',
            params,
          );
          await _settle();
          final original = registry.requests.single;
          final originalResponder = original.request;
          await service.detach();
          final replayTransport = _ServerTransport();
          final replayClient = AcpClient(
            AcpJsonRpcConnection(transport: replayTransport),
          );
          addTearDown(replayClient.close);
          service.attach(replayClient);
          final changed = <String, Object?>{
            ...params,
            if (change == 'session') 'sessionId': 'session-2',
            if (change == 'tool') 'toolCall': {'toolCallId': 'different-call'},
            if (change == 'option')
              'options': [
                {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_always'},
              ],
          };
          replayTransport.sendRequest(
            'replayed',
            change == 'method'
                ? 'fs/write_text_file'
                : 'session/request_permission',
            change == 'method'
                ? {
                    'sessionId': 'session-1',
                    'path': '/workspace/a',
                    'content': 'x',
                  }
                : changed,
          );
          await _settle();

          expect(replayTransport.responseFor('replayed')['error'], {
            'code': -32000,
            'message':
                'Pending request ID was reused with different parameters',
          });
          expect(registry.requests.single, same(original));
          expect(original.request, same(originalResponder));
          await service.selectPermission('s:replayed', 'allow');
          expect(transport.responseFor('replayed')['result'], isNotNull);
          expect(files.writePaths, isEmpty);
        },
      );
    }

    for (final change in ['sessionId', 'path', 'content']) {
      test('rejects a write replay that changes $change', () async {
        final params = <String, Object?>{
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        };
        transport.sendRequest('write-1', 'fs/write_text_file', params);
        await _settle();
        final original = registry.requests.single;
        final originalResponder = original.request;
        await service.detach();
        final replayTransport = _ServerTransport();
        final replayClient = AcpClient(
          AcpJsonRpcConnection(transport: replayTransport),
        );
        addTearDown(replayClient.close);
        service.attach(replayClient);
        replayTransport.sendRequest('write-1', 'fs/write_text_file', {
          ...params,
          change: change == 'path' ? '/workspace/b.txt' : 'different',
        });
        await _settle();

        expect(replayTransport.responseFor('write-1')['error'], isNotNull);
        expect(registry.requests.single, same(original));
        expect(original.request, same(originalResponder));
        expect(service.pendingWriteContent('s:write-1'), 'edited');
        await service.approveWrite('s:write-1');
        expect(files.writePaths, ['/workspace/a.txt']);
        expect(utf8.decode(files.files['/workspace/a.txt']!), 'edited');
        expect(transport.responseFor('write-1')['result'], isNull);
      });
    }

    test(
      'exact write replay at capacity preserves identity and byte budget',
      () async {
        final params = <String, Object?>{
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        };
        await service.close();
        registry = AcpPendingRequestRegistry(
          maxPendingRequests: 1,
          maxPendingContentBytes: utf8.encode(jsonEncode(params)).length,
        );
        service = AcpClientCapabilityService(
          fileSystem: files,
          terminalExecutor: null,
          allowedRoots: const ['/workspace'],
          registry: registry,
        )..attach(client);
        transport.sendRequest('write-1', 'fs/write_text_file', params);
        await _settle();
        final original = registry.requests.single;
        await service.detach();
        final replayTransport = _ServerTransport();
        final replayClient = AcpClient(
          AcpJsonRpcConnection(transport: replayTransport),
        );
        addTearDown(replayClient.close);
        service.attach(replayClient);
        replayTransport.sendRequest('write-1', 'fs/write_text_file', params);
        await _settle();
        expect(registry.requests.single, same(original));
        expect(replayTransport.responseForOrNull('write-1'), isNull);
        await service.approveWrite('s:write-1');
        expect(replayTransport.responseFor('write-1')['result'], isNull);
        expect(transport.responseForOrNull('write-1'), isNull);
        expect(registry.requests, isEmpty);

        replayTransport.sendRequest('write-2', 'fs/write_text_file', params);
        await _settle();
        expect(registry.requests.single.id, 's:write-2');
        await service.rejectWrite('s:write-2');
      },
    );

    test('keeps numeric and string JSON-RPC request IDs distinct', () async {
      Map<String, Object?> permission(String toolCallId) => {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': toolCallId},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      };

      transport
        ..sendRequest(1, 'session/request_permission', permission('numeric'))
        ..sendRequest('1', 'session/request_permission', permission('string'));
      await _settle();

      expect(registry.requests.map((request) => request.id).toSet(), {
        'n:1',
        's:1',
      });
      await service.selectPermission('n:1', 'allow');
      await service.selectPermission('s:1', 'allow');

      expect(transport.responseFor(1)['result'], isNotNull);
      expect(transport.responseFor('1')['result'], isNotNull);
      expect(registry.requests, isEmpty);
    });

    test(
      'native YOLO auto-approves allow-once permissions and validated writes',
      () async {
        await service.close();
        registry = AcpPendingRequestRegistry();
        service = AcpClientCapabilityService(
          fileSystem: files,
          terminalExecutor: terminals,
          allowedRoots: const ['/workspace'],
          registry: registry,
          autoApprovePermissions: true,
          limits: const AcpClientCapabilityLimits(maxWriteBytes: 16),
        )..attach(client);

        transport
          ..sendRequest('permission-yolo', 'session/request_permission', {
            'sessionId': 'session-1',
            'toolCall': {'toolCallId': 'call-1'},
            'options': [
              {
                'optionId': 'persist',
                'name': 'Always allow',
                'kind': 'allow_always',
              },
              {'optionId': 'once', 'name': 'Allow once', 'kind': 'allow_once'},
            ],
          })
          ..sendRequest('write-yolo', 'fs/write_text_file', {
            'sessionId': 'session-1',
            'path': '/workspace/a.txt',
            'content': 'edited',
          });
        await _settle();

        expect(transport.responseFor('permission-yolo')['result'], {
          'outcome': {'outcome': 'selected', 'optionId': 'once'},
        });
        expect(transport.responseFor('write-yolo')['result'], isNull);
        expect(utf8.decode(files.files['/workspace/a.txt']!), 'edited');
        expect(registry.requests, isEmpty);
      },
    );

    test('runtime YOLO overrides stay scoped to one shared session', () async {
      service.setSessionAutoApprovePermissions('session-1', enabled: true);
      transport
        ..sendRequest('permission-yolo-1', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'once-1', 'name': 'Allow once', 'kind': 'allow_once'},
          ],
        })
        ..sendRequest('permission-ask-2', 'session/request_permission', {
          'sessionId': 'session-2',
          'toolCall': {'toolCallId': 'call-2'},
          'options': [
            {'optionId': 'once-2', 'name': 'Allow once', 'kind': 'allow_once'},
          ],
        });
      await _settle();

      expect(transport.responseFor('permission-yolo-1')['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'once-1'},
      });
      expect(registry.requests.map((request) => request.sessionId), [
        'session-2',
      ]);

      service.setSessionAutoApprovePermissions('session-1', enabled: false);
      transport.sendRequest('permission-ask-1', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-3'},
        'options': [
          {'optionId': 'once-3', 'name': 'Allow once', 'kind': 'allow_once'},
        ],
      });
      await _settle();
      expect(registry.requests.map((request) => request.sessionId).toSet(), {
        'session-1',
        'session-2',
      });
    });

    test(
      'preserves a pending permission over detach and reconnect replay',
      () async {
        transport.sendRequest('permission-1', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        });
        await _settle();
        final pending = registry.requests.single;
        final requestedAt = pending.requestedAt;
        await service.detach();
        expect(registry.requests, hasLength(1));

        final reconnectTransport = _ServerTransport();
        final reconnectClient = AcpClient(
          AcpJsonRpcConnection(transport: reconnectTransport),
        );
        service.attach(reconnectClient);
        reconnectTransport.sendRequest(
          'permission-1',
          'session/request_permission',
          {
            // Object key order is not part of replay identity.
            'options': [
              {'kind': 'allow_once', 'name': 'Allow', 'optionId': 'allow'},
            ],
            'toolCall': {'toolCallId': 'call-1'},
            'sessionId': 'session-1',
          },
        );
        await _settle();
        expect(registry.requests.single, same(pending));
        expect(pending.requestedAt, requestedAt);

        await service.selectPermission('s:permission-1', 'allow');
        expect(
          reconnectTransport.responseFor('permission-1')['result'],
          isNotNull,
        );
        await reconnectClient.close();
      },
    );

    test(
      'closeSession cancels only the pending requests for that session, '
      'leaving another session sharing the same registry untouched',
      () async {
        transport
          ..sendRequest('permission-1', 'session/request_permission', {
            'sessionId': 'session-1',
            'toolCall': {'toolCallId': 'call-1'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            ],
          })
          ..sendRequest('permission-2', 'session/request_permission', {
            'sessionId': 'session-2',
            'toolCall': {'toolCallId': 'call-2'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            ],
          });
        await _settle();
        expect(registry.requests, hasLength(2));

        await service.closeSession('session-1');

        // session-1's request was cancelled and removed...
        expect(transport.responseFor('permission-1')['result'], {
          'outcome': {'outcome': 'cancelled'},
        });
        // ...but session-2's is untouched: no response yet, still pending.
        expect(transport.responseForOrNull('permission-2'), isNull);
        expect(registry.requests, hasLength(1));
        expect(registry.requests.single.sessionId, 'session-2');
      },
    );

    test('returns method not found for unknown server methods', () async {
      transport.sendRequest('unknown-1', 'terminal/not_a_method', {});
      await _settle();

      expect(transport.responseFor('unknown-1')['error'], {
        'code': -32601,
        'message': 'Method not found',
      });
    });

    test('reads UTF-8 text and obeys line selections', () async {
      files.files['/workspace/a.txt'] = Uint8List.fromList(
        utf8.encode('one\ntwo\nthree\n'),
      );
      transport.sendRequest('read-1', 'fs/read_text_file', {
        'sessionId': 'session-1',
        'path': '/workspace/a.txt',
        'line': 2,
        'limit': 1,
      });
      await _settle();

      expect(transport.responseFor('read-1')['result'], {'content': 'two\n'});
    });

    test('rejects a read that resolves through an escaping symlink', () async {
      files.canonicalPaths['/workspace/link/private.txt'] = '/private.txt';
      transport.sendRequest('read-link', 'fs/read_text_file', {
        'sessionId': 'session-1',
        'path': '/workspace/link/private.txt',
      });
      await _settle();

      expect(
        (transport.responseFor('read-link')['error']! as Map)['code'],
        -32000,
      );
      expect(files.readPaths, isEmpty);
    });

    test(
      'rejects relative, traversal, oversize, and non-text file reads',
      () async {
        files.files['/workspace/large.txt'] = Uint8List(17);
        files.files['/workspace/binary.txt'] = Uint8List.fromList([0xff]);
        for (final entry in <(String, String)>[
          ('relative', 'file.txt'),
          ('traversal', '/workspace/../secret.txt'),
          ('large', '/workspace/large.txt'),
          ('binary', '/workspace/binary.txt'),
        ]) {
          transport.sendRequest(entry.$1, 'fs/read_text_file', {
            'sessionId': 'session-1',
            'path': entry.$2,
          });
        }
        await _settle();

        for (final id in ['relative', 'traversal', 'large', 'binary']) {
          expect((transport.responseFor(id)['error']! as Map)['code'], -32000);
        }
      },
    );

    test(
      'queues writes until explicit approval and enforces byte limits',
      () async {
        transport.sendRequest('write-1', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        });
        await _settle();
        expect(transport.responseForOrNull('write-1'), isNull);
        expect(files.files['/workspace/a.txt'], isNull);

        await service.approveWrite('s:write-1');
        expect(utf8.decode(files.files['/workspace/a.txt']!), 'edited');
        expect(transport.responseFor('write-1')['result'], isNull);

        transport.sendRequest('write-too-big', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/b.txt',
          'content': '01234567890123456',
        });
        await _settle();
        expect(
          (transport.responseFor('write-too-big')['error']! as Map)['code'],
          -32000,
        );
      },
    );

    for (final autoApprove in [false, true]) {
      test(
        'creates and truncates empty files with autoApprove=$autoApprove',
        () async {
          service.setSessionAutoApprovePermissions(
            'session-1',
            enabled: autoApprove,
          );
          files.files['/workspace/existing.txt'] = Uint8List.fromList([1]);
          for (final name in ['new', 'existing']) {
            final path = '/workspace/$name.txt';
            transport.sendRequest(name, 'fs/write_text_file', {
              'sessionId': 'session-1',
              'path': path,
              'content': '',
            });
            await _settle();
            if (!autoApprove) {
              expect(transport.responseForOrNull(name), isNull);
              expect(files.writePaths, isNot(contains(path)));
              await service.approveWrite('s:$name');
            }
            expect(transport.responseFor(name), containsPair('result', null));
            expect(files.files[path], isEmpty);
          }
          expect(registry.requests, isEmpty);
        },
      );
    }

    test(
      'rejects a write whose parent resolves through an escaping symlink',
      () async {
        files.canonicalWritePaths['/workspace/link/new.txt'] =
            '/private/new.txt';
        transport.sendRequest('write-link', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/link/new.txt',
          'content': 'edited',
        });
        await _settle();

        expect(
          (transport.responseFor('write-link')['error']! as Map)['code'],
          -32000,
        );
        expect(registry.requests, isEmpty);
      },
    );

    test(
      'write approval reports failures before removing the request',
      () async {
        transport.sendRequest('write-failure', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        });
        await _settle();
        files.writeFailure = const FileSystemException('SFTP failed');

        await expectLater(
          () => service.approveWrite('s:write-failure'),
          throwsA(isA<FileSystemException>()),
        );
        expect(transport.responseFor('write-failure')['error'], {
          'code': -32000,
          'message': 'Remote operation failed',
        });
        expect(registry.requests, isEmpty);
      },
    );

    test(
      'write approval reports timeout before removing the request',
      () async {
        transport.sendRequest('write-timeout', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        });
        await _settle();
        files.writeFailure = TimeoutException('timed out');

        await expectLater(
          () => service.approveWrite('s:write-timeout'),
          throwsA(isA<TimeoutException>()),
        );
        expect(transport.responseFor('write-timeout')['error'], {
          'code': -32000,
          'message': 'Remote operation timed out',
        });
        expect(registry.requests, isEmpty);
      },
    );

    test(
      'bounds aggregate pending write content and releases the budget',
      () async {
        await service.close();
        registry = AcpPendingRequestRegistry(
          maxPendingContentBytes: utf8
              .encode(
                jsonEncode({
                  'sessionId': 'session-2',
                  'path': '/workspace/three.txt',
                  'content': 'abcdefghijkl',
                }),
              )
              .length,
        );
        service = AcpClientCapabilityService(
          fileSystem: files,
          terminalExecutor: terminals,
          allowedRoots: const ['/workspace'],
          registry: registry,
          limits: const AcpClientCapabilityLimits(maxWriteBytes: 16),
        )..attach(client);

        transport.sendRequest('write-budget-1', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/one.txt',
          'content': '123456789012',
        });
        await _settle();
        expect(registry.requests, hasLength(1));

        transport.sendRequest('write-budget-2', 'fs/write_text_file', {
          'sessionId': 'session-2',
          'path': '/workspace/two.txt',
          'content': 'abcdefghijkl',
        });
        await _settle();
        expect(
          (transport.responseFor('write-budget-2')['error']! as Map)['code'],
          -32000,
        );
        expect(registry.requests, hasLength(1));

        await service.closeSession('session-1');
        transport.sendRequest('write-budget-3', 'fs/write_text_file', {
          'sessionId': 'session-2',
          'path': '/workspace/three.txt',
          'content': 'abcdefghijkl',
        });
        await _settle();
        expect(registry.requests, hasLength(1));
        expect(registry.requests.single.id, 's:write-budget-3');
      },
    );

    test(
      'permissions share the retained-content budget and release it',
      () async {
        final params = <String, Object?>{
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1', 'title': 'Inspect 🔒'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        };
        await service.close();
        registry = AcpPendingRequestRegistry(
          maxPendingContentBytes: utf8.encode(jsonEncode(params)).length,
        );
        service = AcpClientCapabilityService(
          fileSystem: null,
          terminalExecutor: null,
          allowedRoots: const [],
          registry: registry,
        )..attach(client);

        transport.sendRequest('first', 'session/request_permission', params);
        await _settle();
        expect(registry.requests.single.id, 's:first');
        transport.sendRequest('second', 'session/request_permission', params);
        await _settle();
        expect(registry.requests.single.id, 's:first');
        expect(transport.responseFor('second')['result'], {
          'outcome': {'outcome': 'cancelled'},
        });

        await service.selectPermission('s:first', 'allow');
        transport.sendRequest('third', 'session/request_permission', params);
        await _settle();
        expect(registry.requests.single.id, 's:third');
        expect(transport.responseForOrNull('third'), isNull);
      },
    );

    test('bounds terminal environment, cwd, and final shell command', () async {
      final oversized = List.filled(8192, 'x').join();
      final expansionHeavy = List.filled(3000, "'").join();

      transport.sendRequest('create-env-limit', 'terminal/create', {
        'sessionId': 'session-1',
        'command': 'echo',
        'env': [
          {'name': 'VALUE', 'value': oversized},
        ],
      });
      await _settle();
      expect(
        (transport.responseFor('create-env-limit')['error']! as Map)['code'],
        -32000,
      );

      transport.sendRequest('create-cwd-limit', 'terminal/create', {
        'sessionId': 'session-1',
        'command': 'echo',
        'cwd': '/workspace/$oversized',
      });
      await _settle();
      expect(
        (transport.responseFor('create-cwd-limit')['error']! as Map)['code'],
        -32000,
      );

      transport.sendRequest('create-encoded-limit', 'terminal/create', {
        'sessionId': 'session-1',
        'command': 'echo',
        'args': [expansionHeavy],
      });
      await _settle();
      expect(
        (transport.responseFor('create-encoded-limit')['error']!
            as Map)['code'],
        -32000,
      );
      expect(terminals.commands, isEmpty);
    });

    test(
      'scopes terminals to their owner and releases them on session close',
      () async {
        transport.sendRequest('create-owned', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'long-task',
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-owned')['result']!
                    as Map)['terminalId']
                as String;

        transport.sendRequest('cross-session-output', 'terminal/output', {
          'sessionId': 'session-2',
          'terminalId': terminalId,
        });
        await _settle();
        expect(
          (transport.responseFor('cross-session-output')['error']!
              as Map)['code'],
          -32000,
        );

        await service.closeSession('session-1');
        expect(terminals.processes.single.killed, isTrue);
      },
    );

    group('session teardown admission', () {
      void sendRequests(String prefix, String sessionId) {
        transport
          ..sendRequest('$prefix-terminal', 'terminal/create', {
            'sessionId': sessionId,
            'command': 'long-task',
          })
          ..sendRequest('$prefix-write', 'fs/write_text_file', {
            'sessionId': sessionId,
            'path': '/workspace/$prefix.txt',
            'content': 'updated',
          })
          ..sendRequest('$prefix-permission', 'session/request_permission', {
            'sessionId': sessionId,
            'toolCall': {'toolCallId': '$prefix-call'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            ],
          })
          ..sendRequest('$prefix-read', 'fs/read_text_file', {
            'sessionId': sessionId,
            'path': '/workspace/read.txt',
          });
      }

      void expectRejected(String prefix) {
        for (final kind in ['terminal', 'write', 'permission', 'read']) {
          final response = transport.responseFor('$prefix-$kind');
          expect(response['error'], {
            'code': -32000,
            'message': 'Request was cancelled',
          });
          expect(response.containsKey('result'), isFalse);
        }
        expect(files.files.containsKey('/workspace/$prefix.txt'), isFalse);
        expect(
          registry.requests.where(
            (request) => request.id.startsWith('s:$prefix-'),
          ),
          isEmpty,
        );
      }

      Future<void> expectAllowed(String prefix, String sessionId) async {
        expect(transport.responseFor('$prefix-terminal')['result'], isNotNull);
        expect(transport.responseFor('$prefix-read')['result'], {
          'content': 'read',
        });
        expect(
          registry.requests
              .where((request) => request.sessionId == sessionId)
              .map((request) => request.id),
          unorderedEquals(['s:$prefix-write', 's:$prefix-permission']),
        );
        await service.approveWrite('s:$prefix-write');
        await service.selectPermission('s:$prefix-permission', 'allow');
        expect(utf8.decode(files.files['/workspace/$prefix.txt']!), 'updated');
        expect(transport.responseFor('$prefix-write')['error'], isNull);
        expect(transport.responseFor('$prefix-permission')['result'], {
          'outcome': {'outcome': 'selected', 'optionId': 'allow'},
        });
      }

      // Pending decisions retain their original response channel after reattach.
      // Gate that channel so cancellation cannot block the live bridge's replies.
      Future<void> gateCancellation(Completer<void> gate) async {
        transport.sendRequest('cancel-gated', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'cancel-call'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        });
        await _settle();
        expect(registry.requests.single.id, 's:cancel-gated');
        transport
          ..gatedResponseId = 'cancel-gated'
          ..responseGate = gate.future;
        await service.detach();
        final oldClient = client;
        addTearDown(oldClient.close);
        transport = _ServerTransport();
        client = AcpClient(AcpJsonRpcConnection(transport: transport));
        service.attach(client);
      }

      setUp(() {
        files.files['/workspace/read.txt'] = Uint8List.fromList(
          utf8.encode('read'),
        );
      });

      for (final duringCancellation in [false, true]) {
        final stage = duringCancellation
            ? 'registry cancellation'
            : 'terminal release';
        for (final failCleanup in [false, true]) {
          test('rejects new requests during $stage with failure=$failCleanup, '
              'allows siblings and later resume', () async {
            final gate = Completer<void>();
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
            late Future<void> cleanupStarted;
            if (duringCancellation) {
              final oldTransport = transport;
              await gateCancellation(gate);
              cleanupStarted = oldTransport.gatedResponseStarted.future;
            } else {
              terminals.stdoutCancelGate = gate.future;
              transport.sendRequest('owned-terminal', 'terminal/create', {
                'sessionId': 'session-1',
                'command': 'long-task',
              });
              await _settle();
              cleanupStarted =
                  terminals.processes.single.stdoutCancellationStarted.future;
              terminals.stdoutCancelGate = null;
            }

            final failure = StateError('cleanup failed');
            var finished = false;
            final closing = service.closeSession('session-1');
            final checkedClose = expectLater(
              closing.whenComplete(() => finished = true),
              failCleanup && !duringCancellation
                  ? throwsA(same(failure))
                  : completes,
            );
            await cleanupStarted;
            expect(finished, isFalse);

            sendRequests('blocked', 'session-1');
            await _settle();
            expectRejected('blocked');
            expect(files.readPaths, isEmpty);
            expect(terminals.commands, hasLength(duringCancellation ? 0 : 1));

            sendRequests('sibling', 'session-2');
            await _settle();
            await expectAllowed('sibling', 'session-2');
            expect(finished, isFalse);
            expect(terminals.processes.last.killed, isFalse);

            if (failCleanup) {
              gate.completeError(failure);
            } else {
              gate.complete();
            }
            await checkedClose;
            expect(finished, isTrue);
            expect(registry.requests, isEmpty);

            sendRequests('resumed', 'session-1');
            await _settle();
            await expectAllowed('resumed', 'session-1');
            expect(terminals.processes.last.killed, isFalse);
            expect(files.readPaths, hasLength(2));
            expect(terminals.commands, hasLength(duringCancellation ? 2 : 3));
          });
        }
      }

      for (final releaseFirst in [false, true]) {
        test(
          'overlapping closes keep admission blocked when '
          '${releaseFirst ? 'first' : 'second'} close finishes first',
          () async {
            final releaseGate = Completer<void>();
            final cancellationGate = Completer<void>();
            addTearDown(() {
              if (!releaseGate.isCompleted) releaseGate.complete();
              if (!cancellationGate.isCompleted) cancellationGate.complete();
            });
            terminals.stdoutCancelGate = releaseGate.future;
            transport.sendRequest('owned-terminal', 'terminal/create', {
              'sessionId': 'session-1',
              'command': 'long-task',
            });
            await _settle();
            final process = terminals.processes.single;
            terminals.stdoutCancelGate = null;
            final oldTransport = transport;
            await gateCancellation(cancellationGate);

            final firstClose = service.closeSession('session-1');
            await process.stdoutCancellationStarted.future;
            final secondClose = service.closeSession('session-1');
            await oldTransport.gatedResponseStarted.future;
            if (releaseFirst) {
              releaseGate.complete();
              await firstClose;
            } else {
              cancellationGate.complete();
              await secondClose;
            }

            sendRequests('overlap-blocked', 'session-1');
            sendRequests('sibling', 'session-2');
            await _settle();
            expectRejected('overlap-blocked');
            await expectAllowed('sibling', 'session-2');
            expect(terminals.commands, hasLength(2));
            expect(files.readPaths, hasLength(1));

            if (releaseFirst) {
              cancellationGate.complete();
            } else {
              releaseGate.complete();
            }
            await Future.wait([firstClose, secondClose]);
            sendRequests('resumed', 'session-1');
            await _settle();
            await expectAllowed('resumed', 'session-1');
            expect(terminals.commands, hasLength(3));
          },
        );
      }
    });

    for (final closeAll in [false, true]) {
      final boundary = closeAll ? 'service close' : 'session close';
      test('kills terminal starts that finish after $boundary', () async {
        final gate = Completer<void>();
        terminals.startGate = gate.future;
        transport.sendRequest('late-create', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'long-task',
        });
        await _settle();
        expect(terminals.commands, hasLength(1));

        if (closeAll) {
          await service.close();
        } else {
          await service.closeSession('session-1');
        }
        gate.complete();
        await _settle();

        expect(terminals.processes.single.killed, isTrue);
        expect(transport.responseFor('late-create')['error'], isNotNull);
      });

      for (final duringRead in [false, true]) {
        test('does not return file content after $boundary during '
            '${duringRead ? 'read' : 'path validation'}', () async {
          final gate = Completer<void>();
          files.files['/workspace/read.txt'] = Uint8List.fromList(
            utf8.encode('content'),
          );
          if (duringRead) {
            files.readGate = gate.future;
          } else {
            files.canonicalizeGate = gate.future;
          }
          transport.sendRequest('late-read', 'fs/read_text_file', {
            'sessionId': 'session-1',
            'path': '/workspace/read.txt',
          });
          await _settle();
          expect(files.readPaths, hasLength(duringRead ? 1 : 0));
          if (closeAll) {
            await service.close();
          } else {
            await service.closeSession('session-1');
          }
          gate.complete();
          await _settle();

          expect(files.readPaths, hasLength(duringRead ? 1 : 0));
          final response = transport.responseFor('late-read');
          expect(response['error'], isNotNull);
          expect(response.containsKey('result'), isFalse);
        });
      }

      for (final autoApprove in [false, true]) {
        test(
          'does not revive writes after $boundary with YOLO=$autoApprove',
          () async {
            await service.close();
            registry = AcpPendingRequestRegistry();
            service = AcpClientCapabilityService(
              fileSystem: files,
              terminalExecutor: terminals,
              allowedRoots: const ['/workspace'],
              registry: registry,
              autoApprovePermissions: autoApprove,
            )..attach(client);
            final gate = Completer<void>();
            files.canonicalizeGate = gate.future;
            transport.sendRequest('late-write', 'fs/write_text_file', {
              'sessionId': 'session-1',
              'path': '/workspace/late.txt',
              'content': 'late',
            });
            await _settle();

            if (closeAll) {
              await service.close();
            } else {
              await service.closeSession('session-1');
            }
            gate.complete();
            await _settle();

            expect(files.files, isEmpty);
            expect(registry.requests, isEmpty);
            expect(transport.responseFor('late-write')['error'], isNotNull);
          },
        );
      }
    }

    for (final boundary in ['service', 'session', 'detach', 'sibling']) {
      test(
        'auto-approved write completion respects $boundary teardown',
        () async {
          final gate = Completer<void>();
          files.writeGate = gate.future;
          service.setSessionAutoApprovePermissions('session-1', enabled: true);
          transport.sendRequest('gated-write', 'fs/write_text_file', {
            'sessionId': 'session-1',
            'path': '/workspace/a.txt',
            'content': 'written',
          });
          await _settle();
          expect(files.writePaths, ['/workspace/a.txt']);
          expect(files.files, isEmpty);

          switch (boundary) {
            case 'service':
              await service.close();
            case 'session':
              await service.closeSession('session-1');
            case 'detach':
              await service.detach();
            case 'sibling':
              await service.closeSession('session-2');
          }
          gate.complete();
          await _settle();

          // Teardown cannot undo an already issued remote write, but a canceled
          // request must not send a success reply after the write finishes.
          expect(utf8.decode(files.files['/workspace/a.txt']!), 'written');
          final response = transport.responseFor('gated-write');
          if (boundary == 'service' || boundary == 'session') {
            expect(response['error'], isNotNull);
            expect(response.containsKey('result'), isFalse);
          } else {
            expect(response['error'], isNull);
            expect(response.containsKey('result'), isTrue);
          }
        },
      );
    }

    test(
      'does not start a terminal after its cwd validation is closed',
      () async {
        final gate = Completer<void>();
        files.canonicalizeGate = gate.future;
        transport.sendRequest('late-cwd', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'long-task',
          'cwd': '/workspace',
        });
        await _settle();
        await service.closeSession('session-1');
        gate.complete();
        await _settle();

        expect(terminals.commands, isEmpty);
        expect(transport.responseFor('late-cwd')['error'], isNotNull);
      },
    );

    test('closing one session preserves sibling terminal starts', () async {
      final gate = Completer<void>();
      terminals.startGate = gate.future;
      for (var index = 1; index <= 2; index++) {
        transport.sendRequest('pending-$index', 'terminal/create', {
          'sessionId': 'session-$index',
          'command': 'long-task',
        });
      }
      await _settle();
      await service.closeSession('session-1');
      gate.complete();
      await _settle();

      expect(terminals.processes[0].killed, isTrue);
      expect(terminals.processes[1].killed, isFalse);
      expect(transport.responseFor('pending-2')['result'], isNotNull);
    });

    test('soft detach preserves pending terminal starts', () async {
      final gate = Completer<void>();
      terminals.startGate = gate.future;
      transport.sendRequest('detached-create', 'terminal/create', {
        'sessionId': 'session-1',
        'command': 'long-task',
      });
      await _settle();
      await service.detach();
      gate.complete();
      await _settle();

      expect(terminals.processes.single.killed, isFalse);
      expect(transport.responseFor('detached-create')['result'], isNotNull);
    });

    test('permanently closed services cannot attach again', () async {
      await service.close();
      expect(() => service.attach(client), throwsStateError);
    });

    test('late request failures tolerate a closed response channel', () async {
      final gate = Completer<void>();
      terminals.startGate = gate.future;
      transport.sendRequest('closed-create', 'terminal/create', {
        'sessionId': 'session-1',
        'command': 'long-task',
      });
      await _settle();
      await service.close();
      await client.close();
      gate.completeError(StateError('SSH session closed'));
      await _settle();

      expect(terminals.processes, isEmpty);
    });

    test('reserves terminal capacity across concurrent creates', () async {
      final gate = Completer<void>();
      terminals.startGate = gate.future;
      for (var index = 1; index <= 3; index++) {
        transport.sendRequest('create-$index', 'terminal/create', {
          'sessionId': 'session-$index',
          'command': 'task-$index',
        });
      }
      await _settle();

      expect(
        (transport.responseFor('create-3')['error']! as Map)['code'],
        -32000,
      );
      gate.complete();
      await _settle();
      await _settle();
      expect(terminals.processes, hasLength(2));
      expect(transport.responseFor('create-1')['result'], isNotNull);
      expect(transport.responseFor('create-2')['result'], isNotNull);
    });

    test(
      'creates concurrent terminals, truncates output, waits, kills, and releases',
      () async {
        transport.sendRequest('create-1', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'args': ['hello'],
          'cwd': '/workspace',
          'outputByteLimit': 8,
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-1')['result']! as Map)['terminalId']
                as String;
        final process = terminals.processes.single
          ..addOutput(utf8.encode('1234'), utf8.encode('56789'));
        await _settle();

        transport.sendRequest('output-1', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        final output = transport.responseFor('output-1')['result']! as Map;
        expect(output['output'], '23456789');
        expect(output['truncated'], isTrue);

        process.exit(const AcpTerminalExitStatus(exitCode: 7));
        transport.sendRequest('wait-1', 'terminal/wait_for_exit', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(transport.responseFor('wait-1')['result'], {
          'exitCode': 7,
          'signal': null,
        });

        transport.sendRequest('release-1', 'terminal/release', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(transport.responseFor('release-1')['result'], isNull);
        transport.sendRequest('output-released', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(
          (transport.responseFor('output-released')['error']! as Map)['code'],
          -32000,
        );
      },
    );

    test(
      'retains a valid UTF-8 suffix across truncation and split chunks',
      () async {
        transport.sendRequest('create-utf8', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'outputByteLimit': 4,
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-utf8')['result']!
                    as Map)['terminalId']
                as String;
        terminals.processes.single
          ..addStdout(utf8.encode('x€'))
          ..addStdout(utf8.encode('yz'));
        await _settle();

        transport.sendRequest('output-utf8', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(
          (transport.responseFor('output-utf8')['result']! as Map)['output'],
          'yz',
        );

        transport.sendRequest('create-split', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'outputByteLimit': 4,
        });
        await _settle();
        final splitTerminalId =
            (transport.responseFor('create-split')['result']!
                    as Map)['terminalId']
                as String;
        terminals.processes.last
          ..addStdout(<int>[0x61, 0x62, 0x63, 0xe2])
          ..addStdout(<int>[0x82])
          ..addStdout(<int>[0xac]);
        await _settle();

        transport.sendRequest('output-split', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': splitTerminalId,
        });
        await _settle();
        expect(
          (transport.responseFor('output-split')['result']! as Map)['output'],
          'c€',
        );
      },
    );

    test(
      'buffers many small chunks without retaining more than its cap',
      () async {
        const outputByteLimit = 1024;
        const chunkCount = 50000;
        transport.sendRequest('create-stress', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'outputByteLimit': outputByteLimit,
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-stress')['result']!
                    as Map)['terminalId']
                as String;
        final expected = StringBuffer();
        final process = terminals.processes.single;
        for (var index = 0; index < chunkCount; index += 1) {
          final codeUnit = 65 + index % 26;
          process.addStdout(<int>[codeUnit]);
          expected.writeCharCode(codeUnit);
        }
        await _settle();

        transport.sendRequest('output-stress', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        final result = transport.responseFor('output-stress')['result']! as Map;
        expect(result['truncated'], isTrue);
        expect(
          result['output'],
          expected.toString().substring(chunkCount - outputByteLimit),
        );
      },
    );

    test(
      'kills a live terminal and explicit cleanup cancels unresolved requests',
      () async {
        transport.sendRequest('create-1', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'long-task',
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-1')['result']! as Map)['terminalId']
                as String;
        transport.sendRequest('kill-1', 'terminal/kill', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(terminals.processes.single.killed, isTrue);

        transport.sendRequest('permission-1', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        });
        await _settle();
        await service.close();
        expect(transport.responseFor('permission-1')['result'], {
          'outcome': {'outcome': 'cancelled'},
        });
      },
    );
  });

  test(
    'quotes Windows terminal commands without leaking raw values to diagnostics',
    () {
      final command = buildAcpRemoteTerminalCommand(
        command: r'C:\tool with spaces.exe',
        arguments: const ['a b'],
        environment: const {'TOKEN': 'secret'},
        cwd: '/C:/workspace',
        windows: true,
      );
      expect(command, startsWith('powershell -NoProfile'));
      expect(command, isNot(contains('secret')));
    },
  );

  test('diagnostics retain only safe ACP request metadata', () async {
    final transport = _ServerTransport();
    final client = AcpClient(AcpJsonRpcConnection(transport: transport));
    final logger = _RecordingLogger();
    final service = AcpClientCapabilityService(
      fileSystem: const _ThrowingFileSystem(),
      terminalExecutor: null,
      allowedRoots: const ['/workspace'],
      registry: AcpPendingRequestRegistry(),
      diagnostics: logger,
    )..attach(client);
    transport.sendRequest('read-1', 'fs/read_text_file', {
      'sessionId': 'session-1',
      'path': '/workspace/private.txt',
    });
    await _settle();

    expect(logger.warningFields.single, containsPair('methodCategory', 'fs'));
    expect(logger.warningFields.single.keys, isNot(contains('path')));
    expect(logger.warningFields.single.keys, isNot(contains('content')));
    expect(logger.warningFields.single.keys, isNot(contains('command')));
    await service.close();
    await client.close();
  });

  test('SFTP writes preserve executable and shared existing modes', () async {
    final executableSharedMode = SftpFileMode(
      groupWrite: false,
      otherWrite: false,
    );
    final sftp = _ModePreservingSftp(executableSharedMode);
    final fileSystem = AcpSftpRemoteFileSystem(() async => sftp);

    await fileSystem.write('/workspace/script', Uint8List.fromList([1]));

    expect(
      sftp.appliedModes.whereType<SftpFileMode>(),
      contains(executableSharedMode),
    );
    expect(sftp.appliedModes.last, executableSharedMode);
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

final class _ServerTransport implements AcpTransport {
  final _incoming = StreamController<List<int>>();
  final messages = <Map<String, Object?>>[];
  String? gatedResponseId;
  Future<void>? responseGate;
  final gatedResponseStarted = Completer<void>();

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  /// Closing a single-subscription controller nobody listened to never
  /// completes, so only await delivery when a listener exists.
  @override
  Future<void> close() {
    final done = _incoming.close();
    return _incoming.hasListener ? done : Future<void>.value();
  }

  void sendRequest(Object id, String method, Object? params) {
    _incoming.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n',
      ),
    );
  }

  @override
  Future<void> write(List<int> bytes) async {
    final message = (jsonDecode(utf8.decode(bytes).trim()) as Map)
        .cast<String, Object?>();
    if (message['id'] == gatedResponseId && responseGate != null) {
      gatedResponseStarted.complete();
      await responseGate;
    }
    messages.add(message);
  }

  Map<String, Object?> responseFor(Object id) =>
      messages.lastWhere((message) => message['id'] == id);

  Map<String, Object?>? responseForOrNull(Object id) {
    for (final message in messages.reversed) {
      if (message['id'] == id) return message;
    }
    return null;
  }
}

final class _FakeFileSystem implements AcpRemoteFileSystem {
  final files = <String, Uint8List>{};
  final canonicalPaths = <String, String>{};
  final canonicalWritePaths = <String, String>{};
  final readPaths = <String>[];
  Exception? writeFailure;
  Future<void>? canonicalizeGate;
  Future<void>? readGate;
  Future<void>? writeGate;
  final writePaths = <String>[];

  @override
  Future<String> canonicalizeExistingPath(String path) async {
    if (canonicalizeGate case final gate?) await gate;
    return canonicalPaths[path] ?? path;
  }

  @override
  Future<String> canonicalizeWritePath(String path) async {
    if (canonicalizeGate case final gate?) await gate;
    return canonicalWritePaths[path] ?? canonicalPaths[path] ?? path;
  }

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async {
    readPaths.add(path);
    if (readGate case final gate?) await gate;
    final bytes =
        files[path] ??
        (throw const AcpClientCapabilityException('Missing file'));
    if (bytes.length > maxBytes) {
      throw const AcpLimitExceededException(
        'File exceeds the configured limit',
      );
    }

    return bytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    writePaths.add(path);
    if (writeGate case final gate?) await gate;
    final failure = writeFailure;
    if (failure != null) throw failure;
    files[path] = bytes;
  }
}

class _MockSshSession extends Mock implements SshSession {}

class _MockTerminalSession extends MockSessionWithChannel {}

final class _FakeTerminalExecutor implements AcpTerminalExecutor {
  final processes = <_FakeTerminalProcess>[];
  final commands = <String>[];
  Future<void>? startGate;
  Future<void>? stdoutCancelGate;

  @override
  Future<AcpTerminalProcess> start(String command) async {
    commands.add(command);
    if (startGate case final gate?) await gate;
    final process = _FakeTerminalProcess(stdoutCancelGate: stdoutCancelGate);
    processes.add(process);
    return process;
  }
}

final class _FakeTerminalProcess implements AcpTerminalProcess {
  _FakeTerminalProcess({this.stdoutCancelGate});

  final Future<void>? stdoutCancelGate;
  final stdoutCancellationStarted = Completer<void>();
  late final StreamController<List<int>> _stdout = stdoutCancelGate == null
      ? StreamController<List<int>>.broadcast(sync: true)
      : StreamController<List<int>>(
          sync: true,
          onCancel: () {
            stdoutCancellationStarted.complete();
            return stdoutCancelGate!.whenComplete(() {
              unawaited(_stdout.close());
            });
          },
        );
  final _stderr = StreamController<List<int>>.broadcast(sync: true);
  final _exit = Completer<AcpTerminalExitStatus>();
  bool killed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<void> get done => _exit.future.then((_) {});

  @override
  void kill() {
    killed = true;
    exit(const AcpTerminalExitStatus(signal: 'KILL'));
  }

  void exit(AcpTerminalExitStatus status) {
    if (_exit.isCompleted) return;
    _exit.complete(status);
    // Keep gated stdout open so release() explicitly cancels the subscription,
    // rather than stream completion triggering an automatic cancellation.
    if (stdoutCancelGate == null) unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  void addStdout(List<int> bytes) => _stdout.add(bytes);

  void addStderr(List<int> bytes) => _stderr.add(bytes);

  void addOutput(List<int> stdout, List<int> stderr) {
    addStdout(stdout);
    addStderr(stderr);
  }

  @override
  Future<AcpTerminalExitStatus> waitForExit() => _exit.future;
}

final class _ThrowingFileSystem implements AcpRemoteFileSystem {
  const _ThrowingFileSystem();

  @override
  Future<String> canonicalizeExistingPath(String path) async => path;

  @override
  Future<String> canonicalizeWritePath(String path) async => path;

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) =>
      throw StateError('unexpected remote failure');

  @override
  Future<void> write(String path, Uint8List bytes) =>
      throw StateError('unexpected remote failure');
}

final class _ModePreservingSftp implements SftpClient {
  _ModePreservingSftp(this._existingMode);

  final SftpFileMode _existingMode;
  final appliedModes = <SftpFileMode?>[];

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(mode: _existingMode);

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async => _ModePreservingFile();

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    appliedModes.add(attrs.mode);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> remove(String filename) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ModePreservingFile implements SftpFile {
  var _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {}

  @override
  SftpFileWriter write(
    Stream<Uint8List> data, {
    int offset = 0,
    void Function(int bytesWritten)? onProgress,
  }) => SftpFileWriter(this, data, offset, onProgress);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RecordingLogger implements DiagnosticsLogger {
  final warningFields = <Map<String, Object?>>[];

  @override
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => warningFields.add(Map<String, Object?>.from(fields));
}
