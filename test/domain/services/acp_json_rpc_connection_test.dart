import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_json.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';

final class _MemoryTransport implements AcpTransport {
  final _incoming = StreamController<List<int>>();
  final writes = <List<int>>[];
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  void add(List<int> bytes) => _incoming.add(bytes);

  @override
  Future<void> write(List<int> bytes) async {
    writes.add(List<int>.of(bytes));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

final class _DecodedMemoryTransport extends _MemoryTransport
    implements AcpDecodedTransport {
  final frames = StreamController<AcpDecodedFrame>();

  @override
  Stream<List<int>> get incoming => throw StateError('Do not decode twice');

  @override
  Stream<AcpDecodedFrame> get incomingFrames => frames.stream;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await frames.close();
  }
}

Map<String, Object?> _decodeWrite(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes).trim());
  return (decoded as Map).map((key, value) => MapEntry(key as String, value));
}

List<int> _encodeMessage(Map<String, Object?> message) =>
    utf8.encode('${jsonEncode(message)}\n');

final class _GatedTransport extends _MemoryTransport {
  final writeStarted = Completer<void>();
  final finishWrite = Completer<void>();
  final closeStarted = Completer<void>();
  final finishClose = Completer<void>();

  @override
  Future<void> write(List<int> bytes) async {
    await super.write(bytes);
    if (!writeStarted.isCompleted) writeStarted.complete();
    await finishWrite.future;
  }

  @override
  Future<void> close() async {
    if (!closeStarted.isCompleted) closeStarted.complete();
    await finishClose.future;
    await super.close();
  }
}

void main() {
  test('queued writes do not reach the transport after close', () async {
    final transport = _GatedTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    final first = connection.notify('first');
    await transport.writeStarted.future;
    final second = connection.notify('second');
    final rejected = expectLater(
      second,
      throwsA(isA<AcpConnectionClosedException>()),
    );
    final closing = connection.close();
    transport.finishClose.complete();
    await closing;
    transport.finishWrite.complete();
    await first;
    await rejected;
    expect(transport.writes, hasLength(1));
  });

  test('close awaits cleanup already started by a protocol failure', () async {
    final transport = _GatedTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    transport.add(utf8.encode('not json\n'));
    await transport.closeStarted.future;
    var finished = false;
    final closing = connection.close().then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    final finishedBeforeCleanup = finished;
    transport.finishClose.complete();
    await closing;
    expect(finishedBeforeCleanup, isFalse);
    expect(transport.closed, isTrue);
  });

  test('encoding failures settle and remove the pending request', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    addTearDown(connection.close);
    final cyclic = <Object?>[];
    cyclic.add(cyclic);
    await expectLater(
      Future<Object?>.sync(
        () => connection.request('invalid', id: 'reusable', params: cyclic),
      ),
      throwsA(isA<JsonCyclicError>()),
    );
    final next = connection.request('valid', id: 'reusable');
    transport.add(
      _encodeMessage({'jsonrpc': '2.0', 'id': 'reusable', 'result': 'ok'}),
    );
    expect(await next, 'ok');
  });

  for (final outcome in ['response', 'timeout', 'encoding']) {
    test('request ID can be reused after $outcome', () async {
      final transport = _MemoryTransport();
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      final original = connection.request(
        'original',
        id: 7,
        params: outcome == 'encoding' ? cyclic : null,
        timeout: outcome == 'timeout' ? Duration.zero : null,
      );
      switch (outcome) {
        case 'response':
          transport.add(
            _encodeMessage({'jsonrpc': '2.0', 'id': 7, 'result': 'original'}),
          );
          expect(await original, 'original');
        case 'timeout':
          await expectLater(
            original,
            throwsA(isA<AcpRequestTimeoutException>()),
          );
        case 'encoding':
          await expectLater(original, throwsA(isA<JsonCyclicError>()));
      }
      final replacement = connection.request('replacement', id: 7);
      final response = expectLater(replacement, completion('replacement'));
      transport.add(
        _encodeMessage({'jsonrpc': '2.0', 'id': 7, 'result': 'replacement'}),
      );
      await response;
      expect(connection.isClosed, isFalse);
    });
  }

  test('completed request timer does not expire a reused ID', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    addTearDown(connection.close);
    final original = connection.request(
      'original',
      id: 'same',
      timeout: Duration.zero,
    );
    transport.add(
      _encodeMessage({'jsonrpc': '2.0', 'id': 'same', 'result': 'original'}),
    );
    expect(await original, 'original');
    final replacement = connection.request(
      'replacement',
      id: 'same',
      noTimeout: true,
    );
    final response = expectLater(replacement, completion('ok'));
    await Future<void>.delayed(Duration.zero);
    transport.add(
      _encodeMessage({'jsonrpc': '2.0', 'id': 'same', 'result': 'ok'}),
    );
    await response;
  });

  test(
    'duplicate active ID rejection preserves the original request',
    () async {
      final transport = _MemoryTransport();
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);
      final original = connection.request('original', id: 'same');
      expect(
        () => connection.request('duplicate', id: 'same'),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(_decodeWrite(transport.writes.single)['method'], 'original');
      transport.add(
        _encodeMessage({'jsonrpc': '2.0', 'id': 'same', 'result': 'ok'}),
      );
      expect(await original, 'ok');
    },
  );

  test('old transport write failure still terminates a reused ID', () async {
    final transport = _GatedTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    addTearDown(connection.close);
    final original = connection.request('original', id: 'same');
    await transport.writeStarted.future;
    transport.add(
      _encodeMessage({'jsonrpc': '2.0', 'id': 'same', 'result': 'original'}),
    );
    expect(await original, 'original');
    final replacement = connection.request('replacement', id: 'same');
    final rejected = expectLater(
      replacement,
      throwsA(isA<AcpConnectionClosedException>()),
    );
    final error = expectLater(
      connection.errors.first,
      completion(isA<AcpConnectionClosedException>()),
    );
    transport.finishClose.complete();
    transport.finishWrite.completeError(StateError('write failed'));
    await Future.wait([rejected, error]);
    await connection.close();
    expect(connection.isClosed, isTrue);
    expect(transport.closed, isTrue);
    expect(
      () => connection.request('after failure'),
      throwsA(isA<AcpConnectionClosedException>()),
    );
  });

  test(
    'decoded input skips byte parsing and preserves immutable identity',
    () async {
      final transport = _DecodedMemoryTransport();
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);
      final message = AcpJson.immutableObject({
        'jsonrpc': '2.0',
        'method': 'history',
        'params': {'text': 'hello'},
      });
      final received = connection.notifications.first;
      transport.frames.add(AcpDecodedFrame(message: message, byteLength: 80));
      expect(identical((await received).raw, message), isTrue);
    },
  );

  test('decoded input still validates size, version and request IDs', () async {
    for (final frame in [
      const AcpDecodedFrame(
        message: {'jsonrpc': '2.0', 'method': 'history'},
        byteLength: 129,
      ),
      const AcpDecodedFrame(
        message: {'jsonrpc': '1.0', 'method': 'history'},
        byteLength: 64,
      ),
      const AcpDecodedFrame(
        message: {'jsonrpc': '2.0', 'method': 'permission', 'id': true},
        byteLength: 64,
      ),
    ]) {
      final transport = _DecodedMemoryTransport();
      final connection = AcpJsonRpcConnection(
        transport: transport,
        maxFrameSize: 128,
      );
      final error = connection.errors.first;
      transport.frames.add(frame);
      expect(await error, isA<AcpProtocolException>());
      expect(connection.isClosed, isTrue);
      await connection.close();
    }
  });

  test('generates UUID string request IDs by default', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    final pending = connection.request('example');
    final expectation = expectLater(
      pending,
      throwsA(isA<AcpConnectionClosedException>()),
    );
    await Future<void>.delayed(Duration.zero);

    final request = _decodeWrite(transport.writes.single);
    expect(
      request['id'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    await connection.close();
    await expectation;
  });

  test('decodes split UTF-8 and NDJSON response frames', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      requestIdFactory: () => 'request-id',
    );
    final resultFuture = connection.request('example');
    await Future<void>.delayed(Duration.zero);

    final response = _encodeMessage({
      'jsonrpc': '2.0',
      'id': 'request-id',
      'result': {'text': 'café 🚀'},
    });
    final split = response.indexOf(0xf0) + 2;
    transport
      ..add(response.sublist(0, split))
      ..add(response.sublist(split));

    expect(await resultFuture, {'text': 'café 🚀'});
    await connection.close();
  });

  test('routes mixed responses, notifications, and server requests', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      requestIdFactory: () => 'client-request',
    );
    final notificationFuture = connection.notifications.first;
    final serverRequestFuture = connection.serverRequests.first;
    final resultFuture = connection.request('client/method');
    await Future<void>.delayed(Duration.zero);

    transport.add(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {'sessionId': 'session-1'},
        })}\n'
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': 7,
          'method': 'session/request_permission',
          'params': {'sessionId': 'session-1'},
        })}\n'
        '${jsonEncode({
          'jsonrpc': '2.0',
          'id': 'client-request',
          'result': {'ok': true},
        })}\n',
      ),
    );

    expect((await notificationFuture).method, 'session/update');
    final serverRequest = await serverRequestFuture;
    expect(serverRequest.id, 7);
    expect(await resultFuture, {'ok': true});

    await serverRequest.respond({'accepted': true});
    final response = _decodeWrite(transport.writes.last);
    expect(response['id'], 7);
    expect(response['result'], {'accepted': true});
    await connection.close();
  });

  test(
    'rejects an error response without an integer code as protocol data',
    () async {
      final transport = _MemoryTransport();
      final connection = AcpJsonRpcConnection(
        transport: transport,
        requestIdFactory: () => 'request-id',
      );
      final result = connection.request('example');
      await Future<void>.delayed(Duration.zero);

      transport.add(
        _encodeMessage({
          'jsonrpc': '2.0',
          'id': 'request-id',
          'error': {'message': 'Missing code'},
        }),
      );

      await expectLater(result, throwsA(isA<AcpProtocolException>()));
      expect(connection.isClosed, isTrue);
    },
  );

  test('times out and closes pending requests deterministically', () async {
    final transport = _MemoryTransport();
    var nextId = 0;
    final connection = AcpJsonRpcConnection(
      transport: transport,
      defaultRequestTimeout: const Duration(milliseconds: 10),
      requestIdFactory: () => 'request-${nextId++}',
    );

    await expectLater(
      connection.request('slow'),
      throwsA(isA<AcpRequestTimeoutException>()),
    );

    final pending = connection.request(
      'pending',
      timeout: const Duration(seconds: 1),
    );
    final closeExpectation = expectLater(
      pending,
      throwsA(isA<AcpConnectionClosedException>()),
    );
    await connection.close();
    await closeExpectation;
    expect(transport.closed, isTrue);
  });

  test('no-timeout request can finish after the default deadline', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      defaultRequestTimeout: const Duration(milliseconds: 10),
      requestIdFactory: () => 'streaming-prompt',
    );

    final result = connection.request('session/prompt', noTimeout: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    transport.add(
      _encodeMessage({
        'jsonrpc': '2.0',
        'id': 'streaming-prompt',
        'result': {'stopReason': 'end_turn'},
      }),
    );

    expect(await result, {'stopReason': 'end_turn'});
    await connection.close();
  });

  test('rejects oversized frames with an explicit protocol error', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      maxFrameSize: 8,
    );
    final errorFuture = connection.errors.first;

    transport.add(utf8.encode('123456789'));

    expect(await errorFuture, isA<AcpProtocolException>());
    expect(connection.isClosed, isTrue);
  });

  test('rejects oversized outbound frames before writing', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(
      transport: transport,
      maxFrameSize: 128,
    );

    await expectLater(
      connection.notify('large', params: {'image': 'x' * 256}),
      throwsA(isA<AcpProtocolException>()),
    );

    expect(transport.writes, isEmpty);
    expect(connection.isClosed, isFalse);
    await connection.close();
  });

  test('default frame budget covers base64-expanded display images', () {
    expect(
      acpJsonRpcDefaultMaxFrameBytes,
      greaterThan(10 * 1024 * 1024 * 4 ~/ 3),
    );
  });

  test('redacts malformed frame content from protocol errors', () async {
    final transport = _MemoryTransport();
    final connection = AcpJsonRpcConnection(transport: transport);
    final errorFuture = connection.errors.first;
    const secrets = <String>[
      'secret-token-value',
      '/Users/private/project',
      'private prompt contents',
    ];

    transport.add(
      utf8.encode(
        '{"jsonrpc":"2.0","token":"${secrets[0]}",'
        '"path":"${secrets[1]}","prompt":"${secrets[2]}"\n',
      ),
    );

    final error = await errorFuture;
    expect(error, isA<AcpProtocolException>());
    expect(error.message, 'Invalid ACP JSON frame');
    for (final secret in secrets) {
      expect(error.message, isNot(contains(secret)));
      expect(error.toString(), isNot(contains(secret)));
    }
    expect(connection.isClosed, isTrue);
  });
}
