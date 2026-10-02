import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';

final class _Transport implements AcpTransport {
  final _incoming = StreamController<List<int>>();
  final messages = <Map<String, Object?>>[];

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  void send(Map<String, Object?> message) =>
      _incoming.add(utf8.encode('${jsonEncode(message)}\n'));

  void sendRequest(Object id, String method, [Object? params]) =>
      send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});

  void sendCancel(Object? requestId) => send({
    'jsonrpc': '2.0',
    'method': acpCancelRequestMethod,
    'params': {'requestId': requestId},
  });

  List<Map<String, Object?>> responsesFor(Object id) => [
    for (final message in messages)
      if (message['id'] == id &&
          message['id'].runtimeType == id.runtimeType &&
          !message.containsKey('method'))
        message,
  ];

  List<Map<String, Object?>> notifications(String method) => [
    for (final message in messages)
      if (message['method'] == method && !message.containsKey('id')) message,
  ];

  @override
  Future<void> write(List<int> bytes) async {
    messages.add(
      (jsonDecode(utf8.decode(bytes).trim()) as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<void> close() {
    final done = _incoming.close();
    return _incoming.hasListener ? done : Future<void>.value();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group(r'inbound $/cancel_request', () {
    late _Transport transport;
    late AcpJsonRpcConnection connection;
    final requests = <AcpJsonRpcServerRequest>[];

    setUp(() {
      requests.clear();
      transport = _Transport();
      connection = AcpJsonRpcConnection(transport: transport)
        ..serverRequests.listen(requests.add);
    });

    tearDown(() => connection.close());

    test('answers an open request once with -32800', () async {
      transport.sendRequest('req-1', 'terminal/wait_for_exit');
      await _settle();
      final request = requests.single;
      final cancelled = request.cancelled;
      transport.sendCancel('req-1');
      await _settle();
      await cancelled;

      expect(request.isCancelled, isTrue);
      expect(request.isAnswered, isTrue);
      expect(transport.responsesFor('req-1'), [
        {
          'jsonrpc': '2.0',
          'id': 'req-1',
          'error': {'code': -32800, 'message': 'Request cancelled'},
        },
      ]);

      // Work that finishes after cancellation never double-answers.
      await request.respond({'exitCode': 0});
      await request.respondError(-32000, 'late failure');
      expect(transport.responsesFor('req-1'), hasLength(1));
    });

    test('ignores an already answered request', () async {
      transport.sendRequest(7, 'session/request_permission');
      await _settle();
      await requests.single.respond({'outcome': 'selected'});
      transport.sendCancel(7);
      await _settle();
      expect(requests.single.isCancelled, isFalse);
      expect(transport.responsesFor(7), hasLength(1));
    });

    test('matches JSON-RPC ids by exact type', () async {
      transport
        ..sendRequest(1, 'numeric')
        ..sendRequest('1', 'string');
      await _settle();
      transport.sendCancel('1');
      await _settle();
      final numeric = requests.firstWhere((r) => r.method == 'numeric');
      final string = requests.firstWhere((r) => r.method == 'string');
      expect(string.isCancelled, isTrue);
      expect(numeric.isCancelled, isFalse);
      expect(transport.responsesFor(1), isEmpty);
      expect(transport.responsesFor('1'), hasLength(1));
    });

    test('ignores unknown, malformed, and fractional ids', () async {
      transport.sendRequest(2, 'open');
      await _settle();
      transport
        ..sendCancel('missing')
        ..sendCancel(2.5)
        ..sendCancel(null)
        ..send({'jsonrpc': '2.0', 'method': acpCancelRequestMethod});
      await _settle();
      expect(requests.single.isAnswered, isFalse);
      expect(connection.isClosed, isFalse);
    });

    test('still forwards the notification to listeners', () async {
      final notifications = <String>[];
      connection.notifications.listen((n) => notifications.add(n.method));
      transport.sendCancel('unknown');
      await _settle();
      expect(notifications, [acpCancelRequestMethod]);
    });

    test('a non-cancelled double answer is still a programming error', () {
      transport.sendRequest('x', 'm');
      return _settle().then((_) async {
        await requests.single.respond();
        expect(() => requests.single.respond(), throwsStateError);
      });
    });
  });

  group('AcpClient cancellation routing', () {
    test(
      'never surfaces a queued request the agent already withdrew',
      () async {
        final transport = _Transport();
        final client = AcpClient(AcpJsonRpcConnection(transport: transport));
        addTearDown(client.close);
        final cancelledIds = <Object>[];
        client.serverRequestCancellations.listen(cancelledIds.add);
        transport
          ..sendRequest('queued', 'session/request_permission')
          ..sendRequest('kept', 'session/request_permission');
        await _settle();
        transport.sendCancel('queued');
        await _settle();

        final routed = <String>[];
        client.serverRequests.listen((request) => routed.add('${request.id}'));
        await _settle();
        expect(routed, ['kept']);
        expect(cancelledIds, ['queued']);
        expect(transport.responsesFor('queued').single['error'], {
          'code': -32800,
          'message': 'Request cancelled',
        });
      },
    );

    test('forwards elicitation completions by id', () async {
      final transport = _Transport();
      final client = AcpClient(AcpJsonRpcConnection(transport: transport));
      addTearDown(client.close);
      final completed = <String>[];
      client.elicitationCompletions.listen(completed.add);
      transport
        ..send({
          'jsonrpc': '2.0',
          'method': 'elicitation/complete',
          'params': {'elicitationId': 'oauth-1'},
        })
        ..send({
          'jsonrpc': '2.0',
          'method': 'elicitation/complete',
          'params': {'elicitationId': 42},
        });
      await _settle();
      expect(completed, ['oauth-1']);
    });
  });

  group(r'outbound $/cancel_request', () {
    test('a timed-out request asks the agent to stop', () async {
      final transport = _Transport();
      final connection = AcpJsonRpcConnection(
        transport: transport,
        requestIdFactory: () => 'slow-1',
      );
      addTearDown(connection.close);
      await expectLater(
        connection.request('authenticate', timeout: Duration.zero),
        throwsA(isA<AcpRequestTimeoutException>()),
      );
      await _settle();
      expect(transport.notifications(acpCancelRequestMethod), [
        {
          'jsonrpc': '2.0',
          'method': acpCancelRequestMethod,
          'params': {'requestId': 'slow-1'},
        },
      ]);
    });

    test('cancelRequest fails locally and ignores a late response', () async {
      final transport = _Transport();
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);
      final pending = connection.request('authenticate', id: 9);
      final failure = expectLater(
        pending,
        throwsA(
          isA<AcpRequestCancelledException>()
              .having((e) => e.cancelledLocally, 'cancelledLocally', isTrue)
              .having((e) => e.code, 'code', -32800),
        ),
      );
      await _settle();
      expect(connection.cancelRequest(9), isTrue);
      expect(connection.cancelRequest(9), isFalse);
      expect(connection.cancelRequest('9'), isFalse);
      await failure;
      await _settle();
      expect(transport.notifications(acpCancelRequestMethod).single['params'], {
        'requestId': 9,
      });
      transport.send({
        'jsonrpc': '2.0',
        'id': 9,
        'result': <String, Object?>{},
      });
      await _settle();
      expect(connection.isClosed, isFalse);
    });

    test('a cancellation handle cancels exactly its request', () async {
      final transport = _Transport();
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);
      final cancellation = AcpRequestCancellation();
      final pending = connection.request(
        'authenticate',
        id: 'auth',
        noTimeout: true,
        cancellation: cancellation,
      );
      final other = connection.request('other', id: 'other');
      final failure = expectLater(
        pending,
        throwsA(isA<AcpRequestCancelledException>()),
      );
      await _settle();
      cancellation
        ..cancel()
        ..cancel();
      await failure;
      await _settle();
      expect(transport.notifications(acpCancelRequestMethod).single['params'], {
        'requestId': 'auth',
      });
      transport.send({'jsonrpc': '2.0', 'id': 'other', 'result': 'ok'});
      expect(await other, 'ok');

      // An already cancelled handle never sends its request.
      await expectLater(
        connection.request('late', id: 'late', cancellation: cancellation),
        throwsA(isA<AcpRequestCancelledException>()),
      );
      await _settle();
      expect(transport.messages.where((m) => m['id'] == 'late'), isEmpty);
    });

    test('a request cancelled while queued is dropped unsent', () async {
      final transport = _Transport();
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);
      final pending = connection.request('authenticate', id: 'queued');
      final failure = expectLater(
        pending,
        throwsA(isA<AcpRequestCancelledException>()),
      );
      // The frame's write has not started, so the agent never sees the
      // request and needs no cancel for it.
      expect(connection.cancelRequest('queued'), isTrue);
      await failure;
      await _settle();
      expect(transport.messages.where((m) => m['id'] == 'queued'), isEmpty);
      expect(transport.notifications(acpCancelRequestMethod), isEmpty);
    });

    test('a settled request unbinds its cancellation handle', () async {
      final transport = _Transport();
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);
      final cancellation = AcpRequestCancellation();
      final pending = connection.request(
        'authenticate',
        id: 'done',
        cancellation: cancellation,
      );
      transport.send({'jsonrpc': '2.0', 'id': 'done', 'result': 'ok'});
      expect(await pending, 'ok');
      cancellation.cancel();
      await _settle();
      expect(transport.notifications(acpCancelRequestMethod), isEmpty);
    });

    test(
      'a remote -32800 maps to a cancellation, not a protocol error',
      () async {
        final transport = _Transport();
        final connection = AcpJsonRpcConnection(transport: transport);
        addTearDown(connection.close);
        final pending = connection.request('session/load', id: 'load');
        transport.send({
          'jsonrpc': '2.0',
          'id': 'load',
          'error': {'code': -32800, 'message': 'Cancelled by agent'},
        });
        await expectLater(
          pending,
          throwsA(
            isA<AcpRequestCancelledException>()
                .having((e) => e.cancelledLocally, 'cancelledLocally', isFalse)
                .having((e) => e.message, 'message', 'Cancelled by agent'),
          ),
        );
      },
    );
  });
}
