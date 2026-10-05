import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_client_capabilities.dart';
import 'package:monkeyssh/domain/models/acp_elicitation.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';

final class _Transport implements AcpTransport {
  final _incoming = StreamController<List<int>>();
  final messages = <Map<String, Object?>>[];

  /// Runs for each message written, as the agent receiving it.
  void Function(Map<String, Object?> message)? onWrite;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  void send(Map<String, Object?> message) =>
      _incoming.add(utf8.encode('${jsonEncode(message)}\n'));

  void sendRequest(Object id, String method, Object? params) =>
      send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});

  void sendCancel(Object requestId) => send({
    'jsonrpc': '2.0',
    'method': acpCancelRequestMethod,
    'params': {'requestId': requestId},
  });

  void sendComplete(String elicitationId) => send({
    'jsonrpc': '2.0',
    'method': 'elicitation/complete',
    'params': {'elicitationId': elicitationId},
  });

  List<Map<String, Object?>> responsesFor(Object id) => [
    for (final message in messages)
      if (message['id'] == id && !message.containsKey('method')) message,
  ];

  Map<String, Object?>? responseFor(Object id) {
    final responses = responsesFor(id);
    return responses.isEmpty ? null : responses.single;
  }

  @override
  Future<void> write(List<int> bytes) async {
    final message = (jsonDecode(utf8.decode(bytes).trim()) as Map)
        .cast<String, Object?>();
    messages.add(message);
    onWrite?.call(message);
  }

  @override
  Future<void> close() {
    final done = _incoming.close();
    return _incoming.hasListener ? done : Future<void>.value();
  }
}

final class _FileSystem implements AcpRemoteFileSystem {
  final writes = <String, String>{};

  @override
  Future<String> canonicalizeExistingPath(String path) async => path;

  @override
  Future<String> canonicalizeWritePath(String path) async => path;

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async =>
      Uint8List(0);

  @override
  Future<void> write(String path, Uint8List bytes) async {
    writes[path] = utf8.decode(bytes);
  }
}

final class _Process implements AcpTerminalProcess {
  final exit = Completer<AcpTerminalExitStatus>();

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<AcpTerminalExitStatus> waitForExit() => exit.future;

  @override
  Future<void> kill() async {
    if (!exit.isCompleted) {
      exit.complete(const AcpTerminalExitStatus(signal: 'KILL'));
    }
  }
}

final class _Terminals implements AcpTerminalExecutor {
  final processes = <_Process>[];

  @override
  Future<AcpTerminalProcess> start(String command) async {
    final process = _Process();
    processes.add(process);
    return process;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _formParams = <String, Object?>{
  'sessionId': 'session-1',
  'mode': 'form',
  'message': 'Pick a strategy',
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'strategy': {
        'type': 'string',
        'enum': ['safe', 'fast'],
      },
      'retries': {'type': 'integer', 'minimum': 0},
    },
    'required': ['strategy'],
  },
};

const _urlParams = <String, Object?>{
  'sessionId': 'session-1',
  'mode': 'url',
  'elicitationId': 'oauth-1',
  'url': 'https://auth.example.com/connect',
  'message': 'Connect your account',
};

void main() {
  late _Transport transport;
  late AcpClient client;
  late _FileSystem files;
  late _Terminals terminals;
  late AcpPendingRequestRegistry registry;
  late AcpClientCapabilityService service;

  AcpClientCapabilityService buildService({
    Duration unpresentedTimeout = const Duration(seconds: 10),
  }) => AcpClientCapabilityService(
    fileSystem: files,
    terminalExecutor: terminals,
    allowedRoots: const ['/workspace'],
    registry: registry,
    diagnostics: const NoopDiagnosticsLogger(),
    unpresentedElicitationTimeout: unpresentedTimeout,
  );

  setUp(() {
    transport = _Transport();
    client = AcpClient(AcpJsonRpcConnection(transport: transport));
    files = _FileSystem();
    terminals = _Terminals();
    registry = AcpPendingRequestRegistry();
    service = buildService()..attach(client);
  });

  tearDown(() async {
    await service.close();
    await client.close();
  });

  test('advertises both elicitation modes explicitly', () {
    final json = service.capabilities.toJson();
    expect(json['elicitation'], {'form': {}, 'url': {}});
  });

  group(r'agent $/cancel_request', () {
    test('drops a pending permission and answers -32800', () async {
      transport.sendRequest('perm-1', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-1'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      await _settle();
      expect(registry.requests, hasLength(1));

      transport.sendCancel('perm-1');
      await _settle();
      expect(registry.requests, isEmpty);
      expect(transport.responseFor('perm-1')!['error'], {
        'code': -32800,
        'message': 'Request cancelled',
      });
      await expectLater(
        service.selectPermission('s:perm-1', 'allow'),
        throwsStateError,
      );
      expect(transport.responsesFor('perm-1'), hasLength(1));
    });

    test('drops a pending write without writing', () async {
      transport.sendRequest('write-1', 'fs/write_text_file', {
        'sessionId': 'session-1',
        'path': '/workspace/a.txt',
        'content': 'hi',
      });
      await _settle();
      await _settle();
      expect(registry.requests.single, isA<AcpPendingFileWrite>());
      transport.sendCancel('write-1');
      await _settle();
      expect(registry.requests, isEmpty);
      expect(files.writes, isEmpty);
      expect(transport.responsesFor('write-1'), hasLength(1));
    });

    test('drops a pending elicitation', () async {
      transport.sendRequest(5, 'elicitation/create', _formParams);
      await _settle();
      expect(registry.requests.single, isA<AcpPendingElicitation>());
      transport.sendCancel(5);
      await _settle();
      expect(registry.requests, isEmpty);
      expect(transport.responseFor(5)!['error'], isNotNull);
    });

    test('answers a long wait_for_exit promptly and only once', () async {
      transport.sendRequest('create', 'terminal/create', {
        'sessionId': 'session-1',
        'command': 'sleep',
      });
      await _settle();
      await _settle();
      final terminalId =
          (transport.responseFor('create')!['result']! as Map)['terminalId'];
      transport.sendRequest('wait', 'terminal/wait_for_exit', {
        'sessionId': 'session-1',
        'terminalId': terminalId,
      });
      await _settle();
      expect(transport.responseFor('wait'), isNull);

      transport.sendCancel('wait');
      await _settle();
      expect(transport.responseFor('wait')!['error'], {
        'code': -32800,
        'message': 'Request cancelled',
      });

      terminals.processes.single.exit.complete(
        const AcpTerminalExitStatus(exitCode: 0),
      );
      await _settle();
      await _settle();
      expect(transport.responsesFor('wait'), hasLength(1));
    });

    test('drops a retained request bound to an earlier attachment', () async {
      transport.sendRequest('perm-old', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-1'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      await _settle();
      // Soft detach and reattach to a new connection, keeping the registry.
      await service.detach();
      final nextTransport = _Transport();
      final nextClient = AcpClient(
        AcpJsonRpcConnection(transport: nextTransport),
      );
      addTearDown(nextClient.close);
      service.attach(nextClient);

      nextTransport.sendCancel('perm-old');
      await _settle();
      expect(registry.requests, isEmpty);
    });

    test('a cancel replayed before the router reattaches still drops the '
        'retained request', () async {
      transport.sendRequest('perm-old', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-1'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      await _settle();
      await service.detach();
      final nextTransport = _Transport();
      final nextClient = AcpClient(
        AcpJsonRpcConnection(transport: nextTransport),
      );
      addTearDown(nextClient.close);
      // The bridge replays the withdrawn request and its cancel while the
      // new capability service is still being created.
      nextTransport
        ..sendRequest('perm-old', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        })
        ..sendCancel('perm-old')
        ..sendComplete('elicitation-1');
      await _settle();
      expect(registry.requests, hasLength(1));

      service.attach(nextClient);
      await _settle();
      expect(registry.requests, isEmpty);
      expect(nextTransport.responsesFor('perm-old'), hasLength(1));
    });

    test('a numeric cancel never drops a string-keyed request', () async {
      transport.sendRequest('1', 'elicitation/create', _formParams);
      await _settle();
      transport.sendCancel(1);
      await _settle();
      expect(registry.requests, hasLength(1));
    });
  });

  group('elicitation/create', () {
    test('accepts validated form content', () async {
      transport.sendRequest('form', 'elicitation/create', _formParams);
      await _settle();
      final pending = registry.requests.single as AcpPendingElicitation;
      expect(pending.sessionId, 'session-1');
      expect(pending.elicitation, isA<AcpFormElicitation>());

      await expectLater(
        service.acceptElicitation('s:form', content: {'strategy': 'reckless'}),
        throwsArgumentError,
      );
      expect(registry.requests, hasLength(1));

      await service.acceptElicitation(
        's:form',
        content: {'strategy': 'safe', 'retries': 2, 'unset': null},
      );
      expect(registry.requests, isEmpty);
      expect(transport.responseFor('form')!['result'], {
        'action': 'accept',
        'content': {'strategy': 'safe', 'retries': 2},
      });
    });

    test('declines and cancels', () async {
      transport
        ..sendRequest('a', 'elicitation/create', _formParams)
        ..sendRequest('b', 'elicitation/create', _formParams);
      await _settle();
      await service.declineElicitation('s:a');
      await service.cancelElicitation('s:b');
      expect(transport.responseFor('a')!['result'], {'action': 'decline'});
      expect(transport.responseFor('b')!['result'], {'action': 'cancel'});
      expect(registry.requests, isEmpty);
    });

    test('rejects unknown modes and invalid params with -32602', () async {
      transport
        ..sendRequest('mode', 'elicitation/create', {
          ..._formParams,
          'mode': 'telepathy',
        })
        ..sendRequest(
          'noscope',
          'elicitation/create',
          {..._formParams}..remove('sessionId'),
        )
        ..sendRequest('huge', 'elicitation/create', {
          ..._formParams,
          'message': 'x',
          '_meta': {'pad': 'x' * acpElicitationMaxRequestBytes},
        });
      await _settle();
      for (final id in ['mode', 'noscope', 'huge']) {
        expect((transport.responseFor(id)!['error']! as Map)['code'], -32602);
      }
      expect(registry.requests, isEmpty);
    });

    test('tracks an accepted URL until elicitation/complete', () async {
      transport.sendRequest('url', 'elicitation/create', _urlParams);
      await _settle();
      await service.acceptElicitation('s:url');
      expect(transport.responseFor('url')!['result'], {'action': 'accept'});
      final awaiting = registry.awaitingElicitations.single;
      expect(awaiting.elicitationId, 'oauth-1');
      expect(awaiting.sessionId, 'session-1');
      expect(awaiting.host, 'auth.example.com');

      transport.sendComplete('unknown');
      await _settle();
      expect(registry.awaitingElicitations, hasLength(1));
      transport.sendComplete('oauth-1');
      await _settle();
      expect(registry.awaitingElicitations, isEmpty);
      // Already-completed ids are ignored.
      transport.sendComplete('oauth-1');
      await _settle();
    });

    test(
      'a completion sent as soon as the agent reads the answer is kept',
      () async {
        transport.sendRequest('url', 'elicitation/create', _urlParams);
        await _settle();
        // The agent finishes the out-of-band step before the answer's write
        // even returns.
        transport.onWrite = (message) {
          if (message['id'] == 'url') transport.sendComplete('oauth-1');
        };
        await service.acceptElicitation('s:url');
        await _settle();
        expect(registry.awaitingElicitations, isEmpty);
      },
    );

    test('closing a session forgets its awaiting URL', () async {
      transport.sendRequest('url', 'elicitation/create', _urlParams);
      await _settle();
      await service.acceptElicitation('s:url');
      await service.closeSession('session-1');
      expect(registry.awaitingElicitations, isEmpty);
    });

    test('session close cancels its pending elicitation', () async {
      transport.sendRequest('form', 'elicitation/create', _formParams);
      await _settle();
      await service.closeSession('session-1');
      expect(transport.responseFor('form')!['result'], {'action': 'cancel'});
    });

    test('a replayed request rebinds without a second prompt', () async {
      transport.sendRequest('form', 'elicitation/create', _formParams);
      await _settle();
      final first = registry.requests.single;
      await service.detach();
      final nextTransport = _Transport();
      final nextClient = AcpClient(
        AcpJsonRpcConnection(transport: nextTransport),
      );
      addTearDown(nextClient.close);
      service.attach(nextClient);
      nextTransport.sendRequest('form', 'elicitation/create', _formParams);
      await _settle();
      expect(registry.requests.single, same(first));
      await service.declineElicitation('s:form');
      expect(nextTransport.responseFor('form')!['result'], {
        'action': 'decline',
      });
      expect(transport.responseFor('form'), isNull);
    });
  });

  group('request-scoped elicitation', () {
    test('cancels when no session view ever shows it', () {
      fakeAsync((async) {
        final transport = _Transport();
        final client = AcpClient(AcpJsonRpcConnection(transport: transport));
        final service = buildService()..attach(client);
        transport.sendRequest(
          'scoped',
          'elicitation/create',
          {..._urlParams, 'requestId': 3}..remove('sessionId'),
        );
        async.flushMicrotasks();
        expect(registry.requests, hasLength(1));
        async
          ..elapse(const Duration(seconds: 11))
          ..flushMicrotasks();
        expect(registry.requests, isEmpty);
        expect(transport.responseFor('scoped')!['result'], {
          'action': 'cancel',
        });
        unawaited(service.close());
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });

    test('stays pending while a session view mirrors the registry', () {
      fakeAsync((async) {
        final transport = _Transport();
        final client = AcpClient(AcpJsonRpcConnection(transport: transport));
        final service = buildService()..attach(client);
        final observer = registry.changes.listen((_) {});
        transport.sendRequest(
          'scoped',
          'elicitation/create',
          {..._formParams, 'requestId': 'session-new-1'}..remove('sessionId'),
        );
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 30))
          ..flushMicrotasks();
        final pending = registry.requests.single as AcpPendingElicitation;
        expect(pending.isRequestScoped, isTrue);
        expect(pending.sessionId, isEmpty);
        expect(transport.responseFor('scoped'), isNull);
        unawaited(observer.cancel());
        unawaited(service.close());
        unawaited(client.close());
        async.flushMicrotasks();
      });
    });
  });
}
