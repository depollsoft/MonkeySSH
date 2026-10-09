// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/hardware_key.dart';
import 'package:monkeyssh/domain/services/hardware_key_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

import '../../helpers/fake_hardware_key_platform.dart';
import '../../helpers/ssh_key_fixtures.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockHostRepository extends Mock implements HostRepository {}

const _hostname = 'hw.example';

class _HostKeySocket implements SSHSocket, HostKeySource {
  _HostKeySocket(this._hostKeyBytes);

  final Uint8List _hostKeyBytes;
  final _stream = StreamController<Uint8List>();
  final _sink = StreamController<List<int>>();

  @override
  Future<Uint8List> get hostKeyBytes async => _hostKeyBytes;

  @override
  Stream<Uint8List> get stream => _stream.stream;

  @override
  StreamSink<List<int>> get sink => _sink.sink;

  @override
  Future<void> close() async {
    unawaited(_stream.close());
    unawaited(_sink.close());
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}

Uint8List _hostKeyBlob() {
  final type = utf8.encode('ssh-ed25519');
  final data = List<int>.generate(32, (i) => i);
  final builder = BytesBuilder(copy: false);
  void writeString(List<int> value) {
    final length = ByteData(4)..setUint32(0, value.length);
    builder
      ..add(length.buffer.asUint8List())
      ..add(value);
  }

  writeString(type);
  writeString(data);
  return builder.toBytes();
}

/// Wires an [SshService] to a fake server that, like OpenSSH, verifies the
/// identity's ECDSA signature over a fresh session challenge.
class _Fixture {
  _Fixture._(this.db, this.platform, this.keyService);

  final AppDatabase db;
  final FakeHardwareKeyPlatform platform;
  final KeyService keyService;
  final hostRepository = _MockHostRepository();
  late final KeyRepository keyRepository;
  late final KnownHostsRepository knownHostsRepository;
  late final SshService service;
  final clients = <_MockSshClient>[];
  final capturedIdentities = <List<SSHIdentity>?>[];
  final challenges = <Uint8List>[];
  final _random = Random(7);

  static Future<_Fixture> create() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final platform = FakeHardwareKeyPlatform();
    final hardwareKeyService = HardwareKeyService(
      platform: platform,
      isPlatformSupported: true,
    );
    final keyRepository = KeyRepository(
      db,
      SecretEncryptionService.forTesting(),
    );
    final fixture =
        _Fixture._(
            db,
            platform,
            KeyService(keyRepository, hardwareKeyService: hardwareKeyService),
          )
          ..keyRepository = keyRepository
          ..knownHostsRepository = KnownHostsRepository(db);
    final hostKey = VerifiedHostKey(
      hostname: _hostname,
      port: 22,
      keyType: 'ssh-ed25519',
      hostKeyBytes: _hostKeyBlob(),
    );
    await fixture.knownHostsRepository.upsertTrustedHost(
      hostname: hostKey.hostname,
      port: hostKey.port,
      keyType: hostKey.trustedKeyType,
      fingerprint: hostKey.fingerprint,
      encodedHostKey: hostKey.encodedHostKey,
      resetFirstSeen: true,
    );
    when(() => fixture.hostRepository.updateLastConnected(any()))
        .thenAnswer((_) async => true);
    fixture.service = SshService(
      hostRepository: fixture.hostRepository,
      keyRepository: keyRepository,
      knownHostsRepository: fixture.knownHostsRepository,
      hardwareKeyService: hardwareKeyService,
      socketConnector: (host, port, {timeout}) async =>
          _HostKeySocket(_hostKeyBlob()),
      clientFactory: fixture._createClient,
    );
    addTearDown(fixture.service.disconnectAll);
    return fixture;
  }

  SSHClient _createClient(
    SSHSocket socket, {
    required String username,
    SSHHostkeyVerifyHandler? onVerifyHostKey,
    SSHPasswordRequestHandler? onPasswordRequest,
    SSHUserInfoRequestHandler? onUserInfoRequest,
    List<SSHIdentity>? identities,
    Duration? keepAliveInterval,
  }) {
    capturedIdentities.add(identities);
    final client = _MockSshClient();
    clients.add(client);
    when(client.close).thenAnswer((_) async {});
    when(() => client.authenticated).thenAnswer((_) async {
      final hostKey = await (socket as HostKeySource).hostKeyBytes;
      await onVerifyHostKey!(
        'ssh-ed25519',
        Uint8List.fromList(utf8.encode(formatSshHostKeyFingerprint(hostKey))),
      );
      for (final identity in identities ?? const <SSHIdentity>[]) {
        if (identity is! HardwareKeyIdentity) {
          continue;
        }
        expect(identity.shouldProbe, isTrue);
        final challenge = Uint8List.fromList(
          List.generate(48, (_) => _random.nextInt(256)),
        );
        challenges.add(challenge);
        final SSHSignature signature;
        try {
          signature = await identity.sign(challenge);
        } on Object catch (error) {
          // dartssh2 closes the transport when a signer throws.
          // ignore: only_throw_errors, dartssh2 models auth errors this way.
          throw SSHAuthAbortError(
            'Connection closed before authentication',
            SSHInternalError(error),
          );
        }
        if (verifySshSignature(
          publicKeyBlob: identity.toPublicKey().encode(),
          data: challenge,
          signature: signature.encode(),
        )) {
          return;
        }
      }
      // ignore: only_throw_errors, dartssh2 models auth errors this way.
      throw SSHAuthFailError('All authentication methods failed');
    });
    return client;
  }

  Future<SshKey> hardwareKey({bool requireUserPresence = false}) async =>
      (await keyService.generateHardwareKey(
        name: 'Phone key',
        requireUserPresence: requireUserPresence,
      ))!;

  Host stubHost({int? keyId, int id = 1}) {
    final host = Host(
      id: id,
      label: 'Hardware host',
      hostname: _hostname,
      port: 22,
      username: 'tester',
      keyId: keyId,
      isFavorite: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      autoConnectRequiresConfirmation: false,
      autoForwardPorts: false,
      sortOrder: 0,
    );
    when(() => hostRepository.getById(id)).thenAnswer((_) async => host);
    return host;
  }
}

Matcher _hardwareFailure(HardwareKeyErrorCode code) =>
    isA<SshConnectionResult>()
        .having((result) => result.success, 'success', isFalse)
        .having((result) => result.cancelled, 'cancelled', isFalse)
        .having(
          (result) => result.error,
          'error',
          HardwareKeyException(code).message,
        );

void main() {
  setUpAll(() {
    registerFallbackValue(0);
  });

  test('authenticates with a key held in secure hardware', () async {
    final fixture = await _Fixture.create();
    final key = await fixture.hardwareKey();
    final host = fixture.stubHost(keyId: key.id);

    final result = await fixture.service.connectToHost(host.id);

    expect(result.success, isTrue, reason: result.error);
    final identity = fixture.capturedIdentities.single!.single;
    expect(identity, isA<HardwareKeyIdentity>());
    expect(identity.type, 'ecdsa-sha2-nistp256');
    expect(
      openSshPublicKeyLine(identity.toPublicKey().encode()),
      key.publicKey,
    );
    expect(fixture.platform.signRequests, hasLength(1));
    expect(fixture.service.sessions, hasLength(1));
  });

  test('every reconnect signs a fresh challenge in hardware', () async {
    final fixture = await _Fixture.create();
    final key = await fixture.hardwareKey();
    final host = fixture.stubHost(keyId: key.id);

    final first = await fixture.service.connectToHost(host.id);
    expect(first.success, isTrue, reason: first.error);
    await fixture.service.disconnect(first.connectionId!);

    // A background reconnect cannot show a prompt and must fail clearly.
    fixture.platform.signError = const HardwareKeyException(
      HardwareKeyErrorCode.interactionRequired,
    );
    final background = await fixture.service.connectToHost(host.id);
    expect(
      background,
      _hardwareFailure(HardwareKeyErrorCode.interactionRequired),
    );
    expect(background.error, contains('background'));

    fixture.platform.signError = null;
    final foreground = await fixture.service.connectToHost(host.id);
    expect(foreground.success, isTrue, reason: foreground.error);

    expect(fixture.platform.signRequests, hasLength(3));
    expect(fixture.challenges, hasLength(3));
    expect(fixture.challenges.toSet(), hasLength(3));
    expect(fixture.service.sessions.keys, [foreground.connectionId]);
  });

  test('cancelling the connection dismisses the confirmation prompt', () async {
    final fixture = await _Fixture.create();
    final key = await fixture.hardwareKey(requireUserPresence: true);
    final host = fixture.stubHost(keyId: key.id);
    fixture.platform.holdSigns = true;
    final token = SshConnectionCancellationToken();

    final connecting = fixture.service.connectToHost(
      host.id,
      cancellationToken: token,
    );
    final requestId = await fixture.platform.waitForPrompt();
    token.cancel();
    final result = await connecting;

    expect(result.cancelled, isTrue);
    expect(result.success, isFalse);
    expect(fixture.platform.cancelledRequests, contains(requestId));
    expect(fixture.platform.heldRequestIds, isEmpty);
    expect(fixture.service.sessions, isEmpty);
    verify(fixture.clients.single.close).called(greaterThanOrEqualTo(1));
    await pumpEventQueue();
  });

  test('a dismissed prompt fails the attempt with a clear message', () async {
    final fixture = await _Fixture.create();
    final key = await fixture.hardwareKey(requireUserPresence: true);
    final host = fixture.stubHost(keyId: key.id);
    fixture.platform.holdSigns = true;

    final connecting = fixture.service.connectToHost(host.id);
    final requestId = await fixture.platform.waitForPrompt();
    await fixture.platform.cancelSign(requestId);

    expect(await connecting, _hardwareFailure(HardwareKeyErrorCode.cancelled));
    expect(fixture.service.sessions, isEmpty);
  });

  test(
    'the authentication timeout waits for the confirmation prompt',
    () async {
      final fixture = await _Fixture.create();
      final key = await fixture.hardwareKey(requireUserPresence: true);
      fixture.platform.holdSigns = true;

      final connecting = fixture.service.connect(
        SshConnectionConfig(
          hostname: _hostname,
          port: 22,
          username: 'tester',
          privateKey: key.privateKey,
          connectionTimeout: const Duration(milliseconds: 40),
        ),
      );
      final requestId = await fixture.platform.waitForPrompt();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      fixture.platform.approve(requestId);
      final result = await connecting;

      expect(result.success, isTrue, reason: result.error);
      await result.closeAll();
    },
  );

  test(
    'auto mode offers hardware keys alongside PEM keys in key order',
    () async {
      final fixture = await _Fixture.create();
      final pemKey = await fixture.keyService.importKey(
        name: 'Laptop key',
        privateKeyPem: sshEd25519PrivateKey,
      );
      final hardwareKey = await fixture.hardwareKey();
      final host = fixture.stubHost();

      final result = await fixture.service.connectToHost(host.id);

      expect(result.success, isTrue, reason: result.error);
      final identities = fixture.capturedIdentities.single!;
      expect(pemKey!.id, lessThan(hardwareKey.id));
      expect(identities, hasLength(2));
      expect(identities.first, isA<SSHKeyPair>());
      expect(identities.last, isA<HardwareKeyIdentity>());
    },
  );

  test('a damaged explicit hardware key reports a clear error', () async {
    final fixture = await _Fixture.create();

    final result = await fixture.service.connect(
      const SshConnectionConfig(
        hostname: _hostname,
        port: 22,
        username: 'tester',
        privateKey: '${HardwareKeyReference.prefix}{}',
      ),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('damaged'));
    expect(fixture.platform.signRequests, isEmpty);
    expect(fixture.capturedIdentities, isEmpty);
  });

  test('deleting a hardware key removes it from secure hardware', () async {
    final fixture = await _Fixture.create();
    final key = await fixture.hardwareKey();
    final alias = key.hardwareKeyReference!.alias;
    expect(fixture.platform.keys, contains(alias));

    await fixture.keyService.deleteKey(key);

    expect(await fixture.keyRepository.getById(key.id), isNull);
    expect(fixture.platform.deletedAliases, [alias]);
    expect(fixture.platform.keys, isEmpty);
  });

  test('stores only the alias and public key for a hardware key', () async {
    final fixture = await _Fixture.create();
    final key = await fixture.hardwareKey(requireUserPresence: true);
    final reference = key.hardwareKeyReference!;

    expect(key.keyType, 'ecdsa-sha2-nistp256');
    expect(key.passphrase, isNull);
    expect(key.fingerprint, startsWith('SHA256:'));
    expect(key.publicKey, openSshPublicKeyLine(reference.publicKeyBlob));
    expect(reference.requiresUserPresence, isTrue);
    final decoded = jsonDecode(
      key.privateKey.substring(HardwareKeyReference.prefix.length),
    ) as Map<String, dynamic>;
    expect(decoded.keys.toSet(), {
      'alias',
      'backing',
      'publicKey',
      'userPresence',
    });
  });

  test('a failed generation leaves no key behind', () async {
    final fixture = await _Fixture.create();
    fixture.platform.generateError = const HardwareKeyException(
      HardwareKeyErrorCode.notHardwareBacked,
    );

    await expectLater(
      fixture.keyService.generateHardwareKey(
        name: 'Phone key',
        requireUserPresence: false,
      ),
      throwsA(isA<HardwareKeyException>()),
    );
    expect(await fixture.keyRepository.getAll(), isEmpty);
  });
}
