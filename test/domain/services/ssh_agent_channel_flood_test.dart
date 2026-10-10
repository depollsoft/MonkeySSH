// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// The agent channel, its controller and channel messages are not exported;
// these tests drive the vendored copy in third_party/dartssh2 directly.
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_channel.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/ssh_agent_forwarding.dart';

import '../../helpers/recording_diagnostics_logger.dart';
import '../../helpers/ssh_key_fixtures.dart';

const _packetSize = 32 * 1024;
const _window = 2 * 1024 * 1024;

class _CountingHandler implements SSHAgentHandler {
  _CountingHandler(this.inner);

  final SSHAgentHandler inner;
  int calls = 0;

  @override
  Future<Uint8List> handleRequest(Uint8List request) {
    calls++;
    return inner.handleRequest(request);
  }
}

/// One forwarded agent channel as a host sees it: requests go in as channel
/// data, replies come out as sent messages.
class _AgentChannelHarness {
  _AgentChannelHarness(this.handler, {required int remoteWindow}) {
    controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: _packetSize,
      localInitialWindowSize: _window,
      remoteId: 1,
      remoteInitialWindowSize: remoteWindow,
      remoteMaximumPacketSize: _packetSize,
      sendMessage: sent.add,
    );
    SSHAgentChannel(controller.channel, handler);
    unawaited(controller.channel.done.then((_) => closed = true));
  }

  final SSHAgentHandler handler;
  late final SSHChannelController controller;
  final sent = <SSHMessage>[];
  bool closed = false;

  void send(Uint8List data) => controller.handleMessage(
    SSH_Message_Channel_Data(recipientChannel: 1, data: data),
  );

  Iterable<Uint8List> get replies =>
      sent.whereType<SSH_Message_Channel_Data>().map((message) => message.data);
}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

Uint8List _string(List<int> bytes) =>
    Uint8List.fromList([..._uint32(bytes.length), ...bytes]);

/// One SIGN_REQUEST frame for a publickey user-auth request with [keyBlob].
Uint8List _signFrame(Uint8List keyBlob) {
  final data = Uint8List.fromList([
    ..._string(List<int>.filled(32, 7)),
    50,
    ..._string(utf8.encode('git')),
    ..._string(utf8.encode('ssh-connection')),
    ..._string(utf8.encode('publickey')),
    1,
    ..._string(utf8.encode('ssh-ed25519')),
    ..._string(keyBlob),
  ]);
  final payload = Uint8List.fromList([
    SSHAgentProtocol.signRequest,
    ..._string(keyBlob),
    ..._string(data),
    ..._uint32(0),
  ]);
  return Uint8List.fromList([..._uint32(payload.length), ...payload]);
}

Uint8List _frames(int count, int messageType) {
  final bytes = Uint8List(count * 5);
  for (var index = 0; index < count; index++) {
    bytes[index * 5 + 3] = 1;
    bytes[index * 5 + 4] = messageType;
  }
  return bytes;
}

/// Runs [body] while measuring the longest gap between timer ticks, which is
/// how long the event loop (and with it input and rendering) was blocked.
Future<Duration> _longestStall(Future<void> Function() body) async {
  var longest = Duration.zero;
  final stopwatch = Stopwatch()..start();
  var last = stopwatch.elapsed;
  final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = stopwatch.elapsed;
    if (now - last > longest) {
      longest = now - last;
    }
    last = now;
  });
  try {
    await body();
  } finally {
    ticker.cancel();
  }
  return longest;
}

Future<void> _until(bool Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late List<SshAgentKey> keys;

  setUpAll(() {
    keys = [
      SshAgentKey(
        label: 'ed25519',
        identity: SSHKeyPair.fromPem(sshEd25519PrivateKey).single,
      ),
      SshAgentKey(
        label: 'rsa',
        identity: SSHKeyPair.fromPem(sshRsaPrivateKey).single,
      ),
    ];
  });

  _CountingHandler handler() => _CountingHandler(
    SshAgentForwarding(
      hostId: 1,
      hostLabel: 'host',
      loadPolicy: () async =>
          SshAgentForwardingPolicy(enabled: true, keys: keys),
      diagnostics: RecordingDiagnosticsLogger(),
    ),
  );

  test('answers a client that waits for each reply', () async {
    final harness = _AgentChannelHarness(handler(), remoteWindow: _window)
      ..send(_frames(1, SSHAgentProtocol.requestIdentities));
    await _until(() => harness.replies.isNotEmpty, const Duration(seconds: 5));
    harness.send(_frames(1, SSHAgentProtocol.requestIdentities));
    await _until(() => harness.replies.length >= 2, const Duration(seconds: 5));

    expect(harness.replies, hasLength(2));
    for (final reply in harness.replies) {
      expect(reply[4], SSHAgentProtocol.identitiesAnswer);
    }
    expect(harness.closed, isFalse);
  });

  test('a flood of tiny requests neither blocks the event loop nor queues '
      'without limit', () async {
    final counting = handler();
    final harness = _AgentChannelHarness(counting, remoteWindow: 0);
    final packet = _frames(
      _packetSize ~/ 5,
      SSHAgentProtocol.requestIdentities,
    );

    final stall = await _longestStall(() async {
      // A full receive window of 5-byte requests, from a host that never
      // reads the replies.
      for (var index = 0; index < _window ~/ _packetSize; index++) {
        harness.send(packet);
        await Future<void>.delayed(Duration.zero);
      }
      await _until(() => harness.closed, const Duration(seconds: 20));
    });

    expect(harness.closed, isTrue);
    expect(stall, lessThan(const Duration(milliseconds: 250)));
    expect(
      harness.controller.channel.pendingOutputBytes,
      lessThanOrEqualTo(SSHAgentChannel.maxPendingReplyBytes),
    );
    // Upstream answered every one of the ~419,000 frames.
    expect(counting.calls, lessThan(5000));
  });

  test('closes a channel whose replies the host never reads', () async {
    final counting = handler();
    final harness = _AgentChannelHarness(counting, remoteWindow: 0);

    // Requests sent one at a time, each answered with a few hundred bytes.
    for (var index = 0; index < 2000 && !harness.closed; index++) {
      harness.send(_frames(1, SSHAgentProtocol.requestIdentities));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
    await _until(() => harness.closed, const Duration(seconds: 5));

    expect(harness.closed, isTrue);
    expect(
      harness.controller.channel.pendingOutputBytes,
      lessThanOrEqualTo(SSHAgentChannel.maxPendingReplyBytes),
    );
  });

  test('answers requests sent before the client half-closes', () async {
    final slow = SshAgentForwarding(
      hostId: 1,
      hostLabel: 'host',
      loadPolicy: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return SshAgentForwardingPolicy(enabled: true, keys: keys);
      },
      diagnostics: RecordingDiagnosticsLogger(),
    );
    final harness = _AgentChannelHarness(slow, remoteWindow: _window)
      ..send(_frames(1, SSHAgentProtocol.requestIdentities));
    harness.controller.handleMessage(
      SSH_Message_Channel_EOF(recipientChannel: 1),
    );

    await _until(() => harness.replies.isNotEmpty, const Duration(seconds: 5));

    expect(harness.replies, hasLength(1));
    expect(harness.replies.single[4], SSHAgentProtocol.identitiesAnswer);
  });

  test('a frame split into one-byte writes is reassembled', () async {
    final harness = _AgentChannelHarness(handler(), remoteWindow: _window);
    // The largest request allowed, of an unsupported type, delivered a byte
    // at a time.
    const length = SSHAgentChannel.maxFrameSize;
    final frame = Uint8List(4 + length)
      ..setRange(0, 4, _uint32(length))
      ..[4] = 99;
    for (var offset = 0; offset < frame.length; offset++) {
      harness.send(Uint8List.sublistView(frame, offset, offset + 1));
      if (offset % 4096 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    await _until(() => harness.replies.isNotEmpty, const Duration(seconds: 30));

    expect(harness.replies, hasLength(1));
    expect(harness.replies.single[4], SSHAgentProtocol.failure);
    expect(harness.closed, isFalse);
  });

  test('a host signing on many channels at once is rate limited', () async {
    final counting = handler();
    final frame = _signFrame(keys.first.publicKeyBlob);
    final harnesses = [
      for (var index = 0; index < 16; index++)
        _AgentChannelHarness(counting, remoteWindow: 1 << 30),
    ];
    var signatures = 0;
    final stopwatch = Stopwatch()..start();

    // Each channel behaves like a well-mannered client: one request, wait for
    // the reply, repeat.
    await Future.wait([
      for (final harness in harnesses)
        () async {
          while (stopwatch.elapsed < const Duration(milliseconds: 1500)) {
            final before = harness.replies.length;
            harness.send(frame);
            await _until(
              () => harness.replies.length > before || harness.closed,
              const Duration(seconds: 5),
            );
            if (harness.closed) return;
            if (harness.replies.last[4] == SSHAgentProtocol.signResponse) {
              signatures++;
            }
          }
        }(),
    ]);
    final seconds = stopwatch.elapsed.inMilliseconds / 1000;

    // A burst of 20, then 10 a second.
    expect(signatures, lessThanOrEqualTo(20 + (10 * seconds).ceil() + 1));
    expect(signatures, greaterThanOrEqualTo(20));
    expect(counting.calls, greaterThan(signatures));
  });

  test('serves a bounded number of agent channels at once', () async {
    final shared = handler();
    final harnesses = [
      for (
        var index = 0;
        index < SSHAgentChannel.maxChannelsPerHandler;
        index++
      )
        _AgentChannelHarness(shared, remoteWindow: _window),
    ];
    await pumpEventQueue();

    // The client refuses the next open before allocating anything for it.
    expect(SSHAgentChannel.hasRoomFor(shared), isFalse);
    // One that gets constructed anyway is closed.
    final extra = _AgentChannelHarness(shared, remoteWindow: _window);
    await pumpEventQueue();
    expect(extra.closed, isTrue);
    expect(harnesses.where((harness) => harness.closed), isEmpty);

    // A slot frees once a channel closes.
    harnesses.first.controller.handleMessage(
      SSH_Message_Channel_Close(recipientChannel: 1),
    );
    await pumpEventQueue();
    expect(SSHAgentChannel.hasRoomFor(shared), isTrue);
  });
}
