// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/ssh_agent_forwarding.dart';
import 'package:monkeyssh/domain/services/ssh_wire.dart';
import 'package:pointycastle/export.dart' as pc;

import '../../helpers/recording_diagnostics_logger.dart';
import '../../helpers/ssh_key_fixtures.dart';

const _failure = 5;
const _identitiesAnswer = 12;
const _signResponse = 14;

class _MockSshClient extends Mock implements SSHClient {}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

Uint8List _string(List<int> bytes) =>
    Uint8List.fromList([..._uint32(bytes.length), ...bytes]);

Uint8List _text(String value) => _string(utf8.encode(value));

/// The data `ssh(1)` asks an agent to sign for publickey user auth.
Uint8List _userauthData({
  required Uint8List keyBlob,
  String user = 'git',
  String method = 'publickey',
  String algorithm = 'ssh-ed25519',
  int hasSignature = 1,
  List<int>? serverHostKey,
}) => Uint8List.fromList([
  ..._string(List<int>.filled(32, 7)),
  50,
  ..._text(user),
  ..._text('ssh-connection'),
  ..._text(method),
  hasSignature,
  ..._text(algorithm),
  ..._string(keyBlob),
  if (serverHostKey != null) ..._string(serverHostKey),
]);

Uint8List _signRequest(Uint8List keyBlob, Uint8List data, {int flags = 0}) =>
    Uint8List.fromList([
      13,
      ..._string(keyBlob),
      ..._string(data),
      ..._uint32(flags),
    ]);

final _requestIdentities = Uint8List.fromList([11]);

({String algorithm, Uint8List signature}) _readSignResponse(
  Uint8List response,
) {
  expect(response.first, _signResponse);
  final blob = readSshString(response, 1)!;
  final algorithm = utf8.decode(readSshString(blob, 0)!);
  final signature = readSshString(blob, 4 + utf8.encode(algorithm).length)!;
  return (algorithm: algorithm, signature: Uint8List.fromList(signature));
}

List<({Uint8List blob, String comment})> _readIdentities(Uint8List response) {
  expect(response.first, _identitiesAnswer);
  final count = readSshUint32(response, 1);
  var offset = 5;
  final identities = <({Uint8List blob, String comment})>[];
  for (var index = 0; index < count; index++) {
    final blob = readSshString(response, offset)!;
    offset += 4 + blob.length;
    final comment = readSshString(response, offset)!;
    offset += 4 + comment.length;
    identities.add((
      blob: Uint8List.fromList(blob),
      comment: utf8.decode(comment),
    ));
  }
  expect(offset, response.length);
  return identities;
}

Future<bool> _verifyEd25519(
  OpenSSHEd25519KeyPair key,
  Uint8List data,
  Uint8List signature,
) => crypto.Ed25519().verify(
  data,
  signature: crypto.Signature(
    signature,
    publicKey: crypto.SimplePublicKey(
      key.publicKey,
      type: crypto.KeyPairType.ed25519,
    ),
  ),
);

bool _verifyRsa(
  OpenSSHRsaKeyPair key,
  String algorithm,
  Uint8List data,
  Uint8List signature,
) {
  final signer =
      switch (algorithm) {
        'rsa-sha2-512' => pc.RSASigner(
          pc.SHA512Digest(),
          '0609608648016503040203',
        ),
        'rsa-sha2-256' => pc.RSASigner(
          pc.SHA256Digest(),
          '0609608648016503040201',
        ),
        _ => pc.RSASigner(pc.SHA1Digest(), '06052b0e03021a'),
      }..init(
        false,
        pc.PublicKeyParameter<pc.RSAPublicKey>(pc.RSAPublicKey(key.n, key.e)),
      );
  return signer.verifySignature(data, pc.RSASignature(signature));
}

void main() {
  late OpenSSHEd25519KeyPair ed25519;
  late OpenSSHRsaKeyPair rsa;

  setUpAll(() {
    ed25519 =
        SSHKeyPair.fromPem(sshEd25519PrivateKey).single
            as OpenSSHEd25519KeyPair;
    rsa = SSHKeyPair.fromPem(sshRsaPrivateKey).single as OpenSSHRsaKeyPair;
  });

  SshAgentForwarding forwarding({
    List<SshAgentKey>? keys,
    Future<List<SshAgentKey>> Function()? loadKeys,
    bool confirmEachSignature = false,
    SshAgentSignatureConfirmer? confirm,
    RecordingDiagnosticsLogger? diagnostics,
  }) => SshAgentForwarding(
    hostId: 7,
    hostLabel: 'build box',
    loadPolicy: () async => SshAgentForwardingPolicy(
      enabled: true,
      confirmEachSignature: confirmEachSignature,
      keys:
          await (loadKeys ??
              () async =>
                  keys ??
                  [SshAgentKey(label: 'GitHub work', identity: ed25519)])(),
    ),
    initiallyConfirmEachSignature: confirmEachSignature,
    confirm: confirm,
    diagnostics: diagnostics ?? RecordingDiagnosticsLogger(),
  );

  group('identities', () {
    test('lists each key once with its label, loading keys once', () async {
      var loads = 0;
      final agent = forwarding(
        loadKeys: () async {
          loads++;
          return [
            SshAgentKey(label: 'GitHub work', identity: ed25519),
            SshAgentKey(label: 'old copy', identity: ed25519),
            SshAgentKey(label: 'deploy', identity: rsa),
          ];
        },
      );

      final first = _readIdentities(
        await agent.handleRequest(_requestIdentities),
      );
      final second = _readIdentities(
        await agent.handleRequest(_requestIdentities),
      );

      expect(loads, 1);
      expect(first.map((identity) => identity.comment), [
        'GitHub work',
        'deploy',
      ]);
      expect(first[0].blob, ed25519.toPublicKey().encode());
      expect(first[1].blob, rsa.toPublicKey().encode());
      expect(second.length, 2);
    });

    test('refuses while keys cannot load and retries next time', () async {
      var loads = 0;
      final agent = forwarding(
        loadKeys: () async {
          loads++;
          if (loads == 1) {
            throw const FormatException('unreadable');
          }
          return [SshAgentKey(label: 'GitHub work', identity: ed25519)];
        },
      );

      expect(await agent.handleRequest(_requestIdentities), [_failure]);
      expect(
        _readIdentities(await agent.handleRequest(_requestIdentities)),
        hasLength(1),
      );
    });
  });

  group('signing', () {
    test('signs a user-auth request with an Ed25519 key', () async {
      final agent = forwarding();
      final blob = ed25519.toPublicKey().encode();
      final data = _userauthData(keyBlob: blob);

      final response = _readSignResponse(
        await agent.handleRequest(_signRequest(blob, data)),
      );

      expect(response.algorithm, 'ssh-ed25519');
      expect(await _verifyEd25519(ed25519, data, response.signature), isTrue);
      expect(agent.status.value.signatureCount, 1);
    });

    test('signs RSA requests with the hash the flags ask for', () async {
      final agent = forwarding(
        keys: [SshAgentKey(label: 'deploy', identity: rsa)],
      );
      final blob = rsa.toPublicKey().encode();
      final cases = {0: 'ssh-rsa', 2: 'rsa-sha2-256', 4: 'rsa-sha2-512'};

      for (final MapEntry(key: flags, value: algorithm) in cases.entries) {
        final data = _userauthData(keyBlob: blob, algorithm: algorithm);
        final response = _readSignResponse(
          await agent.handleRequest(_signRequest(blob, data, flags: flags)),
        );
        expect(response.algorithm, algorithm, reason: 'flags $flags');
        expect(
          _verifyRsa(rsa, algorithm, data, response.signature),
          isTrue,
          reason: 'flags $flags',
        );
      }
      expect(agent.status.value.signatureCount, 3);
    });

    test('signs through an asynchronous signer', () async {
      var signs = 0;
      final identity = SSHIdentity.custom(
        type: 'ssh-ed25519',
        publicKey: ed25519.toPublicKey(),
        signer: (data) async {
          await Future<void>.delayed(Duration.zero);
          signs++;
          return ed25519.sign(data);
        },
      );
      final agent = forwarding(
        keys: [SshAgentKey(label: 'enclave', identity: identity)],
      );
      final blob = ed25519.toPublicKey().encode();
      final data = _userauthData(keyBlob: blob);

      final response = _readSignResponse(
        await agent.handleRequest(_signRequest(blob, data)),
      );

      expect(signs, 1);
      expect(await _verifyEd25519(ed25519, data, response.signature), isTrue);
    });

    test('refuses an RSA hash an asynchronous signer cannot produce', () async {
      // dartssh2's RSA key pairs sign with rsa-sha2-256 by default.
      final identity = SSHIdentity.custom(
        type: 'rsa-sha2-256',
        publicKey: rsa.toPublicKey(),
        signer: (data) async => rsa.sign(data),
      );
      final agent = forwarding(
        keys: [SshAgentKey(label: 'token', identity: identity)],
      );
      final blob = rsa.toPublicKey().encode();

      final sha512 = await agent.handleRequest(
        _signRequest(
          blob,
          _userauthData(keyBlob: blob, algorithm: 'rsa-sha2-512'),
          flags: 4,
        ),
      );
      final sha256 = await agent.handleRequest(
        _signRequest(
          blob,
          _userauthData(keyBlob: blob, algorithm: 'rsa-sha2-256'),
          flags: 2,
        ),
      );

      expect(sha512, [_failure]);
      expect(_readSignResponse(sha256).algorithm, 'rsa-sha2-256');
    });

    test('accepts the OpenSSH host-bound user-auth method', () async {
      final agent = forwarding();
      final blob = ed25519.toPublicKey().encode();
      final data = _userauthData(
        keyBlob: blob,
        method: 'publickey-hostbound-v00@openssh.com',
        serverHostKey: [1, 2, 3],
      );

      final response = await agent.handleRequest(_signRequest(blob, data));

      expect(response.first, _signResponse);
    });

    test('refuses to sign anything but a user-auth request', () async {
      final agent = forwarding(
        keys: [
          SshAgentKey(label: 'GitHub work', identity: ed25519),
          SshAgentKey(label: 'deploy', identity: rsa),
        ],
      );
      final blob = ed25519.toPublicKey().encode();
      final rsaBlob = rsa.toPublicKey().encode();
      final valid = _userauthData(keyBlob: blob);
      final notUserauth = <String, Uint8List>{
        'an SSHSIG commit signature': Uint8List.fromList([
          ...utf8.encode('SSHSIG'),
          ..._text('git'),
          ..._text(''),
          ..._text('sha512'),
          ..._string(List<int>.filled(64, 1)),
        ]),
        'a request naming another key': _userauthData(keyBlob: rsaBlob),
        'a password request': _userauthData(keyBlob: blob, method: 'password'),
        'a query without a signature': _userauthData(
          keyBlob: blob,
          hasSignature: 0,
        ),
        'a host-bound request without a host key': _userauthData(
          keyBlob: blob,
          method: 'publickey-hostbound-v00@openssh.com',
        ),
        'trailing bytes': Uint8List.fromList([...valid, 0]),
        'a truncated request': Uint8List.sublistView(
          valid,
          0,
          valid.length - 1,
        ),
        'an empty session ID': Uint8List.fromList([
          ..._string(const []),
          ...Uint8List.sublistView(valid, 36),
        ]),
      };

      for (final MapEntry(key: description, value: data)
          in notUserauth.entries) {
        expect(await agent.handleRequest(_signRequest(blob, data)), [
          _failure,
        ], reason: description);
      }
      expect(agent.status.value.signatureCount, 0);
    });

    test('refuses unknown keys and malformed sign requests', () async {
      final agent = forwarding();
      final blob = ed25519.toPublicKey().encode();
      final rsaBlob = rsa.toPublicKey().encode();
      final valid = _signRequest(blob, _userauthData(keyBlob: blob));

      expect(
        await agent.handleRequest(
          _signRequest(rsaBlob, _userauthData(keyBlob: rsaBlob)),
        ),
        [_failure],
      );
      expect(
        await agent.handleRequest(
          Uint8List.sublistView(valid, 0, valid.length - 1),
        ),
        [_failure],
      );
      expect(await agent.handleRequest(Uint8List.fromList([...valid, 0])), [
        _failure,
      ]);
      expect(agent.status.value.signatureCount, 0);
    });

    test('refuses every other agent message', () async {
      final agent = forwarding();
      // add identity, remove identity, remove all, add smartcard key,
      // lock, unlock, add constrained identity, extension, and nothing.
      for (final request in [
        [17],
        [18],
        [19],
        [20],
        [22],
        [23],
        [25],
        [27, ..._text('session-bind@openssh.com')],
        <int>[],
      ]) {
        expect(await agent.handleRequest(Uint8List.fromList(request)), [
          _failure,
        ], reason: 'message $request');
      }
    });
  });

  group('confirm each signature', () {
    test('asks with the host, key and user before signing', () async {
      final requests = <SshAgentSignatureRequest>[];
      final agent = forwarding(
        confirmEachSignature: true,
        confirm: (request) async {
          requests.add(request);
          return SshAgentSignatureDecision.approved;
        },
      );
      final blob = ed25519.toPublicKey().encode();

      final response = await agent.handleRequest(
        _signRequest(blob, _userauthData(keyBlob: blob, user: 'deploy-bot')),
      );

      expect(response.first, _signResponse);
      expect(requests, hasLength(1));
      expect(requests.single.hostLabel, 'build box');
      expect(requests.single.keyLabel, 'GitHub work');
      expect(requests.single.username, 'deploy-bot');
      expect(requests.single.isConnectionClosed(), isFalse);
    });

    test('refuses when declined or no prompt can be shown', () async {
      for (final decision in [
        SshAgentSignatureDecision.declined,
        SshAgentSignatureDecision.unavailable,
      ]) {
        final agent = forwarding(
          confirmEachSignature: true,
          confirm: (_) async => decision,
        );
        final blob = ed25519.toPublicKey().encode();

        expect(
          await agent.handleRequest(
            _signRequest(blob, _userauthData(keyBlob: blob)),
          ),
          [_failure],
          reason: decision.name,
        );
        expect(agent.status.value.signatureCount, 0);
      }
    });

    test('refuses without a confirmer', () async {
      final agent = forwarding(confirmEachSignature: true);
      final blob = ed25519.toPublicKey().encode();

      expect(
        await agent.handleRequest(
          _signRequest(blob, _userauthData(keyBlob: blob)),
        ),
        [_failure],
      );
    });

    test('does not ask before listing keys', () async {
      var asked = 0;
      final agent = forwarding(
        confirmEachSignature: true,
        confirm: (_) async {
          asked++;
          return SshAgentSignatureDecision.approved;
        },
      );

      await agent.handleRequest(_requestIdentities);

      expect(asked, 0);
    });

    test('ties prompts to the attached client', () async {
      final done = Completer<void>();
      final client = _MockSshClient();
      when(() => client.done).thenAnswer((_) => done.future);
      final requests = <SshAgentSignatureRequest>[];
      final agent = forwarding(
        confirmEachSignature: true,
        confirm: (request) async {
          requests.add(request);
          return SshAgentSignatureDecision.approved;
        },
      )..attachClient(client);
      final blob = ed25519.toPublicKey().encode();
      final request = _signRequest(blob, _userauthData(keyBlob: blob));

      await agent.handleRequest(request);
      var closed = false;
      unawaited(requests.single.connectionClosed.then((_) => closed = true));
      done.complete();
      await pumpEventQueue();

      expect(closed, isTrue);
      expect(requests.single.isConnectionClosed(), isTrue);
      expect(await agent.handleRequest(request), [_failure]);
      expect(requests, hasLength(1));
    });
  });

  group('live settings', () {
    test('turning forwarding off refuses an open connection at once', () async {
      var policy = SshAgentForwardingPolicy(
        enabled: true,
        keys: [SshAgentKey(label: 'GitHub work', identity: ed25519)],
      );
      final changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      final client = _MockSshClient();
      when(() => client.done).thenAnswer((_) => Completer<void>().future);
      final agent = SshAgentForwarding(
        hostId: 7,
        hostLabel: 'build box',
        loadPolicy: () async => policy,
        policyChanges: changes.stream,
        diagnostics: RecordingDiagnosticsLogger(),
      )..attachClient(client);
      final blob = ed25519.toPublicKey().encode();

      expect(
        _readIdentities(await agent.handleRequest(_requestIdentities)),
        hasLength(1),
      );

      policy = SshAgentForwardingPolicy.off;
      changes.add(null);
      await pumpEventQueue();

      expect(agent.status.value.serving, isFalse);
      expect(await agent.handleRequest(_requestIdentities), [_failure]);
      expect(
        await agent.handleRequest(
          _signRequest(blob, _userauthData(keyBlob: blob)),
        ),
        [_failure],
      );
    });

    test('turning confirmation on asks before the next signature', () async {
      var confirm = false;
      var asked = 0;
      final agent = SshAgentForwarding(
        hostId: 7,
        hostLabel: 'build box',
        loadPolicy: () async => SshAgentForwardingPolicy(
          enabled: true,
          confirmEachSignature: confirm,
          keys: [SshAgentKey(label: 'GitHub work', identity: ed25519)],
        ),
        confirm: (_) async {
          asked++;
          return SshAgentSignatureDecision.declined;
        },
        diagnostics: RecordingDiagnosticsLogger(),
      );
      final blob = ed25519.toPublicKey().encode();
      final request = _signRequest(blob, _userauthData(keyBlob: blob));

      expect((await agent.handleRequest(request)).first, _signResponse);
      expect(asked, 0);

      confirm = true;
      agent.refreshPolicy();

      expect(await agent.handleRequest(request), [_failure]);
      expect(asked, 1);
      expect(agent.status.value.confirmEachSignature, isTrue);
    });

    test('reads the settings again once they are a few seconds old', () async {
      var now = DateTime(2026, 10, 9, 12);
      var keys = [SshAgentKey(label: 'GitHub work', identity: ed25519)];
      var loads = 0;
      final agent = SshAgentForwarding(
        hostId: 7,
        hostLabel: 'build box',
        loadPolicy: () async {
          loads++;
          return SshAgentForwardingPolicy(enabled: true, keys: keys);
        },
        clock: () => now,
        diagnostics: RecordingDiagnosticsLogger(),
      );

      await agent.handleRequest(_requestIdentities);
      await agent.handleRequest(_requestIdentities);
      expect(loads, 1);

      // The key was deleted in the app.
      keys = [];
      now = now.add(const Duration(seconds: 3));

      expect(
        _readIdentities(await agent.handleRequest(_requestIdentities)),
        isEmpty,
      );
      expect(loads, 2);
    });
  });

  group('settings that change while a request waits', () {
    late List<Completer<SshAgentForwardingPolicy>> loads;

    setUp(() => loads = []);

    SshAgentForwardingPolicy policy(
      List<SshAgentKey> keys, {
      bool confirm = false,
    }) => SshAgentForwardingPolicy(
      enabled: true,
      confirmEachSignature: confirm,
      keys: keys,
    );

    SshAgentForwarding waitingAgent({SshAgentSignatureConfirmer? confirm}) =>
        SshAgentForwarding(
          hostId: 7,
          hostLabel: 'build box',
          loadPolicy: () {
            final load = Completer<SshAgentForwardingPolicy>();
            loads.add(load);
            return load.future;
          },
          confirm: confirm,
          diagnostics: RecordingDiagnosticsLogger(),
        );

    test('a request waiting on settings that turn off is refused', () async {
      final agent = waitingAgent();
      final key = SshAgentKey(label: 'GitHub work', identity: ed25519);
      final blob = ed25519.toPublicKey().encode();

      final response = agent.handleRequest(
        _signRequest(blob, _userauthData(keyBlob: blob)),
      );
      await pumpEventQueue();
      agent.refreshPolicy();
      loads[0].complete(policy([key]));
      await pumpEventQueue();
      loads[1].complete(SshAgentForwardingPolicy.off);

      expect(await response, [_failure]);
      expect(agent.status.value.signatureCount, 0);
    });

    test('confirmation turned on while a request waits asks first', () async {
      var asked = 0;
      final agent = waitingAgent(
        confirm: (_) async {
          asked++;
          return SshAgentSignatureDecision.declined;
        },
      );
      final key = SshAgentKey(label: 'GitHub work', identity: ed25519);
      final blob = ed25519.toPublicKey().encode();

      final response = agent.handleRequest(
        _signRequest(blob, _userauthData(keyBlob: blob)),
      );
      await pumpEventQueue();
      agent.refreshPolicy();
      loads[0].complete(policy([key]));
      await pumpEventQueue();
      loads[1].complete(policy([key], confirm: true));

      expect(await response, [_failure]);
      expect(asked, 1);
    });

    test('a key deselected while its prompt is open is not used', () async {
      final answer = Completer<SshAgentSignatureDecision>();
      final agent = waitingAgent(confirm: (_) => answer.future);
      final key = SshAgentKey(label: 'GitHub work', identity: ed25519);
      final other = SshAgentKey(label: 'deploy', identity: rsa);
      final blob = ed25519.toPublicKey().encode();

      final response = agent.handleRequest(
        _signRequest(blob, _userauthData(keyBlob: blob)),
      );
      await pumpEventQueue();
      loads[0].complete(policy([key], confirm: true));
      await pumpEventQueue();
      agent.refreshPolicy();
      loads[1].complete(policy([other], confirm: true));
      await pumpEventQueue();
      answer.complete(SshAgentSignatureDecision.approved);

      expect(await response, [_failure]);
      expect(agent.status.value.signatureCount, 0);
    });

    test(
      'a signature finished after forwarding turns off is not sent',
      () async {
        final signing = Completer<void>();
        final slowKey = SshAgentKey(
          label: 'enclave',
          identity: SSHIdentity.custom(
            type: 'ssh-ed25519',
            publicKey: ed25519.toPublicKey(),
            signer: (data) async {
              await signing.future;
              return ed25519.sign(data);
            },
          ),
        );
        final agent = waitingAgent();
        final blob = ed25519.toPublicKey().encode();

        final response = agent.handleRequest(
          _signRequest(blob, _userauthData(keyBlob: blob)),
        );
        await pumpEventQueue();
        loads[0].complete(policy([slowKey]));
        await pumpEventQueue();
        agent.refreshPolicy();
        loads[1].complete(SshAgentForwardingPolicy.off);
        await pumpEventQueue();
        signing.complete();

        expect(await response, [_failure]);
        expect(agent.status.value.signatureCount, 0);
      },
    );
  });

  test('signs a burst, then at the set rate', () async {
    var now = DateTime(2026, 10, 9, 12);
    final agent = SshAgentForwarding(
      hostId: 7,
      hostLabel: 'build box',
      loadPolicy: () async => SshAgentForwardingPolicy(
        enabled: true,
        keys: [SshAgentKey(label: 'GitHub work', identity: ed25519)],
      ),
      policyLifetime: const Duration(days: 1),
      clock: () => now,
      diagnostics: RecordingDiagnosticsLogger(),
    );
    final blob = ed25519.toPublicKey().encode();
    final request = _signRequest(blob, _userauthData(keyBlob: blob));
    Future<int> signed(int count) async {
      var made = 0;
      for (var index = 0; index < count; index++) {
        if ((await agent.handleRequest(request)).first == _signResponse) {
          made++;
        }
      }
      return made;
    }

    expect(await signed(30), 20);
    now = now.add(const Duration(seconds: 1));
    expect(await signed(30), 10);
    now = now.add(const Duration(milliseconds: 500));
    expect(await signed(30), 5);
  });

  test('deny and turn off reports the stop once', () async {
    var stops = 0;
    final agent = SshAgentForwarding(
      hostId: 7,
      hostLabel: 'build box',
      loadPolicy: () async => SshAgentForwardingPolicy(
        enabled: true,
        confirmEachSignature: true,
        keys: [SshAgentKey(label: 'GitHub work', identity: ed25519)],
      ),
      confirm: (_) async => SshAgentSignatureDecision.stopForwarding,
      onStop: () => stops++,
      diagnostics: RecordingDiagnosticsLogger(),
    );
    final blob = ed25519.toPublicKey().encode();

    await agent.handleRequest(_signRequest(blob, _userauthData(keyBlob: blob)));
    agent.stop();

    expect(stops, 1);
  });

  group('prompt flooding', () {
    test('keeps at most one prompt open per connection', () async {
      final answer = Completer<SshAgentSignatureDecision>();
      var asked = 0;
      final agent = forwarding(
        confirmEachSignature: true,
        confirm: (_) {
          asked++;
          return answer.future;
        },
      );
      final blob = ed25519.toPublicKey().encode();
      final request = _signRequest(blob, _userauthData(keyBlob: blob));

      final first = agent.handleRequest(request);
      await pumpEventQueue();
      expect(await agent.handleRequest(request), [_failure]);
      expect(asked, 1);

      answer.complete(SshAgentSignatureDecision.approved);
      expect((await first).first, _signResponse);
    });

    test('refuses without asking for a while after a refusal', () async {
      var now = DateTime(2026, 10, 9, 12);
      var asked = 0;
      final agent = SshAgentForwarding(
        hostId: 7,
        hostLabel: 'build box',
        loadPolicy: () async => SshAgentForwardingPolicy(
          enabled: true,
          confirmEachSignature: true,
          keys: [SshAgentKey(label: 'GitHub work', identity: ed25519)],
        ),
        confirm: (_) async {
          asked++;
          return SshAgentSignatureDecision.declined;
        },
        clock: () => now,
        diagnostics: RecordingDiagnosticsLogger(),
      );
      final blob = ed25519.toPublicKey().encode();
      final request = _signRequest(blob, _userauthData(keyBlob: blob));

      expect(await agent.handleRequest(request), [_failure]);
      now = now.add(const Duration(seconds: 5));
      expect(await agent.handleRequest(request), [_failure]);
      expect(asked, 1);

      now = now.add(const Duration(seconds: 6));
      expect(await agent.handleRequest(request), [_failure]);
      expect(asked, 2);
    });

    test('deny and stop ends forwarding on the connection', () async {
      var asked = 0;
      final agent = forwarding(
        confirmEachSignature: true,
        confirm: (_) async {
          asked++;
          return SshAgentSignatureDecision.stopForwarding;
        },
      );
      final blob = ed25519.toPublicKey().encode();
      final request = _signRequest(blob, _userauthData(keyBlob: blob));

      expect(await agent.handleRequest(request), [_failure]);

      expect(agent.status.value.serving, isFalse);
      expect(agent.status.value.stoppedByUser, isTrue);
      expect(await agent.handleRequest(_requestIdentities), [_failure]);
      expect(await agent.handleRequest(request), [_failure]);
      expect(asked, 1);
    });
  });

  test('logs a bounded number of requests per connection', () async {
    final diagnostics = RecordingDiagnosticsLogger();
    final agent = forwarding(diagnostics: diagnostics);

    for (var index = 0; index < 500; index++) {
      await agent.handleRequest(Uint8List.fromList([17]));
    }

    expect(diagnostics.events.length, lessThanOrEqualTo(33));
    expect(diagnostics.events.last.message, 'log_limit_reached');
  });

  test(
    'never logs key names, user names, host labels or key material',
    () async {
      final diagnostics = RecordingDiagnosticsLogger();
      final agent = forwarding(
        diagnostics: diagnostics,
        confirmEachSignature: true,
        confirm: (_) async => SshAgentSignatureDecision.approved,
      );
      final blob = ed25519.toPublicKey().encode();
      final data = _userauthData(keyBlob: blob, user: 'secret-user');

      await agent.handleRequest(_requestIdentities);
      await agent.handleRequest(_signRequest(blob, data));
      await agent.handleRequest(Uint8List.fromList([17]));

      expect(diagnostics.events, isNotEmpty);
      final logged = diagnostics.events
          .map((event) => event.searchableText)
          .join('\n');
      for (final secret in [
        'GitHub work',
        'secret-user',
        'build box',
        base64.encode(blob),
        base64.encode(data),
      ]) {
        expect(logged, isNot(contains(secret)));
      }
    },
  );
}
