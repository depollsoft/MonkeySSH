// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_writer_lease.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/services/acp_device_label.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_acp_bridge_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

const _bridgeId = '0123456789abcdef0123456789abcdef';
const _clientId = 'fedcba9876543210fedcba9876543210';
const _token = 'test-process-token-0001';
final _now = DateTime(2026, 10, 9, 12);

class _MockSshClient extends Mock implements SSHClient {}

final class _FakeInstaller extends MonkeyMuxInstallerService {
  _FakeInstaller()
    : super(
        manifestFuture: Future.value(
          const MonkeyMuxManifest(version: 'test', entries: []),
        ),
        remoteFileService: const RemoteFileService(),
      );

  @override
  Future<MonkeyMuxInstallation> ensureInstalled(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
    MonkeyMuxInstallConfirmation? confirmInstall,
    MonkeyMuxInstallation? Function()? reuseInstallation,
  }) async => const MonkeyMuxInstallation(
    executablePath: '/helper',
    platform: 'linux-amd64',
    version: 'test',
  );
}

/// One SSH exec channel running `monkeymux acp connect`.
final class _Channel extends Fake implements SSHSession {
  _Channel(this.onFrame);

  final void Function(_Channel channel, Map<String, Object?> frame) onFrame;
  final _stdout = StreamController<Uint8List>();
  final frames = <Map<String, Object?>>[];
  bool closed = false;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {
    final frame = (jsonDecode(utf8.decode(data).trim()) as Map)
        .cast<String, Object?>();
    frames.add(frame);
    onFrame(this, frame);
  }

  @override
  void close() => closed = true;

  void send(Map<String, Object?> message) => _stdout.add(
    Uint8List.fromList(
      utf8.encode('${jsonEncode({'version': 1, ...message})}\n'),
    ),
  );

  Future<void> remoteClose() => _stdout.close();

  Iterable<String?> get types =>
      frames.map((frame) => frame['type'] as String?);
}

Map<String, Object?> _metadata() => {
  'id': _bridgeId,
  'provider': 'Copilot CLI',
  'commandHash': 'a' * 64,
  'state': 'running',
  'clientCount': 1,
  'pendingRequestCount': 0,
  'inFlightTurnCount': 0,
  'lastActivityUnix': 1700000000,
  'startedAtUnix': 1699999990,
  'nextSequence': 0,
};

Map<String, Object?> _hello({
  required bool canSend,
  bool leaseAware = true,
  Map<String, Object?>? writer,
}) => {
  'type': 'hello',
  'bridgeId': _bridgeId,
  'clientId': _clientId,
  'canSend': canSend,
  'bridge': _metadata(),
  if (leaseAware) 'capabilities': ['writer_lease'],
  'writer': ?writer,
};

/// Opens a transport whose channels answer each hello with [answer].
({MonkeyMuxAcpTransport transport, List<_Channel> channels}) _open({
  required void Function(_Channel channel, Map<String, Object?> hello) answer,
  bool takeOver = false,
  List<Duration> reconnectBackoff = const [Duration.zero],
  Duration heartbeatInterval = const Duration(seconds: 30),
  int lastAcknowledgedSequence = 0,
}) {
  final channels = <_Channel>[];
  final client = _MockSshClient();
  when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
  when(() => client.execute(any(), pty: any(named: 'pty')))
      .thenAnswer((_) async {
        final channel = _Channel((channel, frame) {
          if (frame['type'] == 'hello') answer(channel, frame);
        });
        channels.add(channel);
        return channel;
      });
  final session = SshSession(
    connectionId: 1,
    hostId: 7,
    client: client,
    config: const SshConnectionConfig(
      hostname: 'example.com',
      port: 22,
      username: 'demo',
    ),
  );
  final transport =
      MonkeyMuxAcpBridgeService(
        installer: _FakeInstaller(),
        diagnostics: const NoopDiagnosticsLogger(),
        deviceLabel: 'iPad',
        clientToken: _token,
      ).connect(
        sessionProvider: () async => session,
        bridgeId: _bridgeId,
        providerId: 'copilot',
        reconnectBackoff: reconnectBackoff,
        takeOver: takeOver,
        heartbeatInterval: heartbeatInterval,
        lastAcknowledgedSequence: lastAcknowledgedSequence,
        clock: () => _now,
      );
  addTearDown(transport.close);
  return (transport: transport, channels: channels);
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  tearDown(resetQueuedSshExecsForTesting);

  test('hello offers the lease fields and takes over only once', () async {
    final (:transport, :channels) = _open(
      takeOver: true,
      answer: (channel, _) => channel.send(_hello(canSend: true)),
    );
    await _waitUntil(() => transport.isConnected);

    final hello = channels.single.frames.first;
    expect(hello['capabilities'], ['writer_lease']);
    expect(hello['deviceLabel'], 'iPad');
    expect(hello['clientToken'], _token);
    expect(hello['takeover'], isTrue);

    // A later reconnect must not take back a lease another device took.
    await channels.single.remoteClose();
    await _waitUntil(() => channels.length == 2 && transport.isConnected);
    expect(channels.last.frames.first.containsKey('takeover'), isFalse);
    expect(channels.last.frames.first['clientToken'], _token);
  });

  test('a lease held elsewhere ends the attach without failing', () async {
    final (:transport, :channels) = _open(
      answer: (channel, _) => channel.send(
        _hello(canSend: false, writer: {'label': 'iPhone', 'idleSeconds': 180}),
      ),
    );
    final errors = <MonkeyMuxAcpBridgeException>[];
    transport.errors.listen(errors.add);
    final states = <MonkeyMuxAcpTransportState>[];
    transport.states.listen(states.add);
    // Queued before the hello, like the session's initialize request.
    await transport.write(
      utf8.encode('{"jsonrpc":"2.0","id":1,"method":"x"}\n'),
    );

    await _waitUntil(
      () => states.any(
        (state) => state.status == MonkeyMuxAcpTransportStatus.heldElsewhere,
      ),
    );
    final held = states.last;
    expect(held.status, MonkeyMuxAcpTransportStatus.heldElsewhere);
    expect(held.writer!.label, 'iPhone');
    expect(
      held.writer!.lastActiveAt,
      _now.subtract(const Duration(minutes: 3)),
    );
    expect(held.writer!.leaseLost, isFalse);
    expect(errors, isEmpty);
    await _waitUntil(() => channels.single.closed);
    // The queued input never left this device, and no reconnect follows.
    expect(channels.single.types, ['hello']);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(channels, hasLength(1));
    await expectLater(
      transport.write(utf8.encode('{"jsonrpc":"2.0","id":2,"method":"x"}\n')),
      throwsA(isA<MonkeyMuxAcpBridgeException>()),
    );
  });

  test(
    'a pending request fails at once when the lease is held elsewhere',
    () async {
      final (:transport, channels: _) = _open(
        answer: (channel, _) => channel.send(
          _hello(canSend: false, writer: {'label': 'iPhone', 'idleSeconds': 0}),
        ),
      );
      final connection = AcpJsonRpcConnection(transport: transport);
      addTearDown(connection.close);

      await expectLater(
        connection.request('initialize', params: const <String, Object?>{}),
        throwsA(isA<AcpConnectionClosedException>()),
      );
    },
  );

  test('a lease frame tells the writer it lost the lease', () async {
    final (:transport, :channels) = _open(
      answer: (channel, _) => channel.send(_hello(canSend: true)),
    );
    final states = <MonkeyMuxAcpTransportState>[];
    transport.states.listen(states.add);
    final errors = <MonkeyMuxAcpBridgeException>[];
    transport.errors.listen(errors.add);
    await _waitUntil(() => transport.isConnected);

    channels.single
      ..send({
        'type': 'lease',
        'bridgeId': _bridgeId,
        'writer': {'label': 'iPhone', 'idleSeconds': 0},
      })
      // The bridge rejects input that raced the lease move; that is expected.
      ..send({
        'type': 'error',
        'error': 'ACP bridge is attached by another writer',
      });
    await _waitUntil(() => channels.single.closed);

    expect(states.last.status, MonkeyMuxAcpTransportStatus.heldElsewhere);
    expect(states.last.writer!.label, 'iPhone');
    expect(states.last.writer!.leaseLost, isTrue);
    expect(errors, isEmpty);
    await expectLater(
      transport.write(utf8.encode('{"jsonrpc":"2.0","id":3,"method":"x"}\n')),
      throwsA(isA<MonkeyMuxAcpBridgeException>()),
    );
    expect(channels.single.types, ['hello']);
  });

  test('a reconnect that finds the lease taken reports it lost', () async {
    var attaches = 0;
    final (:transport, :channels) = _open(
      answer: (channel, _) => channel.send(
        ++attaches == 1
            ? _hello(canSend: true)
            : _hello(
                canSend: false,
                writer: {'label': 'iPhone', 'idleSeconds': 5},
              ),
      ),
    );
    final states = <MonkeyMuxAcpTransportState>[];
    transport.states.listen(states.add);
    await _waitUntil(() => transport.isConnected);

    await channels.single.remoteClose();
    await _waitUntil(
      () =>
          states.isNotEmpty &&
          states.last.status == MonkeyMuxAcpTransportStatus.heldElsewhere,
    );
    expect(states.last.writer!.leaseLost, isTrue);
  });

  String prompt(int id, String sessionId) =>
      '{"jsonrpc":"2.0","id":$id,"method":"session/prompt",'
      '"params":{"sessionId":"$sessionId","prompt":[]}}\n';

  test('a lease frame tells which prompts the bridge accepted', () async {
    final (:transport, :channels) = _open(
      answer: (channel, _) => channel.send(_hello(canSend: true)),
    );
    await _waitUntil(() => transport.isConnected);
    await transport.write(utf8.encode(prompt(1, 'kept')));
    await transport.write(utf8.encode(prompt(2, 'dropped')));
    expect(channels.single.types, ['hello', 'input', 'input']);

    // The bridge took the first input, then the lease moved and it dropped
    // the second.
    channels.single.send({
      'type': 'lease',
      'bridgeId': _bridgeId,
      'writer': {'label': 'iPhone', 'idleSeconds': 0},
      'acceptedInputs': 1,
    });
    await _waitUntil(() => channels.single.closed);

    expect(transport.promptDelivery('kept'), AcpInputDelivery.delivered);
    expect(transport.promptDelivery('dropped'), AcpInputDelivery.notSent);
    expect(
      transport.promptDelivery('never-prompted'),
      AcpInputDelivery.notSent,
    );
  });

  test(
    'a prompt queued while reconnecting is not sent when the lease moved',
    () async {
      var attaches = 0;
      final (:transport, :channels) = _open(
        reconnectBackoff: const [Duration(milliseconds: 50)],
        answer: (channel, _) => channel.send(
          ++attaches == 1
              ? _hello(canSend: true)
              : _hello(
                  canSend: false,
                  writer: {'label': 'iPhone', 'idleSeconds': 0},
                ),
        ),
      );
      final states = <MonkeyMuxAcpTransportState>[];
      transport.states.listen(states.add);
      await _waitUntil(() => transport.isConnected);
      await channels.single.remoteClose();
      await _waitUntil(
        () => states.any(
          (state) => state.status == MonkeyMuxAcpTransportStatus.reconnecting,
        ),
      );
      // The phone wakes and the user sends before the reconnect answers.
      await transport.write(utf8.encode(prompt(1, 'session')));
      await _waitUntil(
        () => states.last.status == MonkeyMuxAcpTransportStatus.heldElsewhere,
      );

      expect(transport.promptDelivery('session'), AcpInputDelivery.notSent);
      expect(channels.last.types, ['hello']);
    },
  );

  test(
    'a prompt written to a channel that dropped is of unknown fate',
    () async {
      var attaches = 0;
      final (:transport, :channels) = _open(
        answer: (channel, _) => channel.send(
          ++attaches == 1
              ? _hello(canSend: true)
              : _hello(
                  canSend: false,
                  writer: {'label': 'iPhone', 'idleSeconds': 0},
                ),
        ),
      );
      final states = <MonkeyMuxAcpTransportState>[];
      transport.states.listen(states.add);
      await _waitUntil(() => transport.isConnected);
      await transport.write(utf8.encode(prompt(1, 'session')));
      await channels.single.remoteClose();
      await _waitUntil(
        () =>
            states.isNotEmpty &&
            states.last.status == MonkeyMuxAcpTransportStatus.heldElsewhere,
      );

      expect(transport.promptDelivery('session'), AcpInputDelivery.unknown);
    },
  );

  test(
    'resuming after another device used the chat offers take back',
    () async {
      final (:transport, channels: _) = _open(
        lastAcknowledgedSequence: 5,
        answer: (channel, _) => channel.send(
          _hello(canSend: false, writer: {'label': 'iPhone', 'idleSeconds': 0}),
        ),
      );
      final states = <MonkeyMuxAcpTransportState>[];
      transport.states.listen(states.add);

      await _waitUntil(
        () =>
            states.isNotEmpty &&
            states.last.status == MonkeyMuxAcpTransportStatus.heldElsewhere,
      );
      expect(states.last.writer!.leaseLost, isTrue);
    },
  );

  test('an older bridge without the lease keeps the writer error', () async {
    final (:transport, channels: _) = _open(
      answer: (channel, _) =>
          channel.send(_hello(canSend: false, leaseAware: false)),
    );

    final error = await transport.errors.first;
    expect(error.kind, MonkeyMuxAcpBridgeErrorKind.nonWriter);
  });

  test(
    'a lease-aware writer sends heartbeats; an older bridge gets none',
    () async {
      for (final leaseAware in [true, false]) {
        final (:transport, :channels) = _open(
          heartbeatInterval: const Duration(milliseconds: 10),
          answer: (channel, _) =>
              channel.send(_hello(canSend: true, leaseAware: leaseAware)),
        );
        await _waitUntil(() => transport.isConnected);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final acks = channels.single.types.where((type) => type == 'ack');
        expect(
          acks.length,
          leaseAware ? greaterThan(1) : 0,
          reason: '$leaseAware',
        );
        await transport.close();
      }
    },
  );

  test('device labels name the platform and form factor only', () {
    expect(acpDeviceLabelFor(TargetPlatform.iOS, shortestSide: 390), 'iPhone');
    expect(acpDeviceLabelFor(TargetPlatform.iOS, shortestSide: 820), 'iPad');
    expect(
      acpDeviceLabelFor(TargetPlatform.android, shortestSide: 412),
      'Android phone',
    );
    expect(
      acpDeviceLabelFor(TargetPlatform.android, shortestSide: 800),
      'Android tablet',
    );
    expect(acpDeviceLabelFor(TargetPlatform.macOS, shortestSide: 900), 'Mac');
    expect(
      acpDeviceLabelFor(TargetPlatform.windows, shortestSide: 900),
      'Windows PC',
    );
  });
}
