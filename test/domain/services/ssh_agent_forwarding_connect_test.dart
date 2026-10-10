// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/ssh_agent_forwarding.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/recording_diagnostics_logger.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _CapturingSshService extends SshService {
  _CapturingSshService({
    required super.hostRepository,
    required super.keyRepository,
    super.agentForwardingResolver,
  });

  SshConnectionConfig? capturedConfig;

  @override
  Future<SshConnectionResult> connect(
    SshConnectionConfig config, {
    ConnectionProgressCallback? onProgress,
    bool isJumpHost = false,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    capturedConfig = config;
    return const SshConnectionResult(success: false, error: 'stubbed');
  }
}

class _FakeHostKeySocket implements SSHSocket, HostKeySource {
  _FakeHostKeySocket(this._hostKeyBytes);

  final Uint8List _hostKeyBytes;
  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>();

  @override
  Future<Uint8List> get hostKeyBytes async => _hostKeyBytes;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() async {
    unawaited(_streamController.close());
    unawaited(_sinkController.close());
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}

class _FakeForwardHostKeySocket extends _FakeHostKeySocket
    implements SSHForwardChannel {
  _FakeForwardHostKeySocket(super.hostKeyBytes);
}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final typeBytes = utf8.encode('ssh-ed25519');
  return Uint8List.fromList([
    ..._uint32(typeBytes.length),
    ...typeBytes,
    ..._uint32(keyData.length),
    ...keyData,
  ]);
}

Uint8List _hostKeyCallbackFingerprint(List<int> hostKeyBytes) =>
    Uint8List.fromList(utf8.encode(formatSshHostKeyFingerprint(hostKeyBytes)));

Future<void> _seedTrustedHost(
  KnownHostsRepository repository, {
  required String hostname,
  required Uint8List hostKeyBytes,
}) async {
  final trusted = VerifiedHostKey(
    hostname: hostname,
    port: 22,
    keyType: 'ssh-ed25519',
    hostKeyBytes: hostKeyBytes,
  );
  await repository.upsertTrustedHost(
    hostname: trusted.hostname,
    port: trusted.port,
    keyType: trusted.trustedKeyType,
    fingerprint: trusted.fingerprint,
    encodedHostKey: trusted.encodedHostKey,
    resetFirstSeen: true,
  );
}

SshAgentForwarding _forwarding(int hostId) => SshAgentForwarding(
  hostId: hostId,
  hostLabel: 'destination',
  loadPolicy: () async => SshAgentForwardingPolicy.off,
  diagnostics: RecordingDiagnosticsLogger(),
);

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('connectToHost resolves forwarding for the destination only', () async {
    final encryption = SecretEncryptionService.forTesting();
    final hostRepository = HostRepository(db, encryption);
    final jumpId = await hostRepository.insert(
      HostsCompanion.insert(
        label: 'bastion',
        hostname: 'jump.example.com',
        username: 'dev',
        password: const Value('jump-secret'),
      ),
    );
    final hostId = await hostRepository.insert(
      HostsCompanion.insert(
        label: 'build box',
        hostname: 'build.example.com',
        username: 'dev',
        password: const Value('secret'),
        jumpHostId: Value(jumpId),
      ),
    );
    final resolvedHosts = <int>[];
    final forwarding = _forwarding(hostId);
    final service = _CapturingSshService(
      hostRepository: hostRepository,
      keyRepository: KeyRepository(db, encryption),
      agentForwardingResolver: (host) async {
        resolvedHosts.add(host.id);
        return forwarding;
      },
    );

    await service.connectToHost(hostId);

    expect(resolvedHosts, [hostId]);
    expect(service.capturedConfig?.agentForwarding, same(forwarding));
    expect(service.capturedConfig?.jumpHost, isNotNull);
    expect(service.capturedConfig?.jumpHost?.agentForwarding, isNull);
  });

  test(
    'connectToHost leaves forwarding off when the resolver says so',
    () async {
      final encryption = SecretEncryptionService.forTesting();
      final hostRepository = HostRepository(db, encryption);
      final hostId = await hostRepository.insert(
        HostsCompanion.insert(
          label: 'build box',
          hostname: 'build.example.com',
          username: 'dev',
          password: const Value('secret'),
        ),
      );
      final service = _CapturingSshService(
        hostRepository: hostRepository,
        keyRepository: KeyRepository(db, encryption),
        agentForwardingResolver: (_) async => null,
      );

      await service.connectToHost(hostId);

      expect(service.capturedConfig, isNotNull);
      expect(service.capturedConfig?.agentForwarding, isNull);
    },
  );

  test('a cancel lands while forwarding waits on the Pro check', () async {
    final encryption = SecretEncryptionService.forTesting();
    final hostRepository = HostRepository(db, encryption);
    final hostId = await hostRepository.insert(
      HostsCompanion.insert(
        label: 'build box',
        hostname: 'build.example.com',
        username: 'dev',
        password: const Value('secret'),
      ),
    );
    final service = _CapturingSshService(
      hostRepository: hostRepository,
      keyRepository: KeyRepository(db, encryption),
      agentForwardingResolver: (_) => Completer<SshAgentForwarding?>().future,
    );
    final token = SshConnectionCancellationToken();

    final result = service.connectToHost(hostId, cancellationToken: token);
    await pumpEventQueue();
    token.cancel();

    expect((await result).cancelled, isTrue);
    expect(service.capturedConfig, isNull);
  });

  test(
    'connect builds the destination client with the agent handler',
    () async {
      final knownHosts = KnownHostsRepository(db);
      final hostKey = _ed25519HostKeyBlob([1, 2, 3]);
      for (final hostname in ['destination', 'jump']) {
        await _seedTrustedHost(
          knownHosts,
          hostname: hostname,
          hostKeyBytes: hostKey,
        );
      }
      final endpoint = _FakeForwardHostKeySocket(hostKey);
      final plainClients = <String>[];
      SSHAgentHandler? servedHandler;
      _MockSshClient? destinationClient;

      _MockSshClient fakeClient(
        SSHSocket socket,
        SSHHostkeyVerifyHandler? onVerifyHostKey,
      ) {
        final client = _MockSshClient();
        when(client.close).thenAnswer((_) async {});
        when(() => client.done).thenAnswer((_) => Completer<void>().future);
        when(() => client.forwardLocal('destination', 22))
            .thenAnswer((_) async => endpoint);
        when(() => client.authenticated).thenAnswer((_) async {
          final bytes = await (socket as HostKeySource).hostKeyBytes;
          await onVerifyHostKey!(
            'ssh-ed25519',
            _hostKeyCallbackFingerprint(bytes),
          );
        });
        return client;
      }

      final service = SshService(
        knownHostsRepository: knownHosts,
        socketConnector: (host, port, {timeout}) async =>
            _FakeHostKeySocket(hostKey),
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              plainClients.add(username);
              return fakeClient(socket, onVerifyHostKey);
            },
        agentForwardingClientFactory:
            (
              socket, {
              required username,
              required agentHandler,
              onVerifyHostKey,
              onPasswordRequest,
              onUserInfoRequest,
              identities,
              keepAliveInterval,
            }) {
              servedHandler = agentHandler;
              return destinationClient = fakeClient(socket, onVerifyHostKey);
            },
      );
      final forwarding = _forwarding(1);

      final result = await service.connect(
        SshConnectionConfig(
          hostname: 'destination',
          port: 22,
          username: 'dest-user',
          password: 'secret',
          agentForwarding: forwarding,
          jumpHost: const SshConnectionConfig(
            hostname: 'jump',
            port: 22,
            username: 'jump-user',
            password: 'secret',
          ),
        ),
      );

      expect(result.success, isTrue);
      expect(plainClients, ['jump-user']);
      expect(servedHandler, same(forwarding));
      expect(result.client, same(destinationClient));
      // Attached, so pending prompts end when this client closes.
      verify(() => destinationClient!.done).called(1);
      await result.closeAll();
    },
  );
}
