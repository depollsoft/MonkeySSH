// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/hardware_key.dart';
import 'package:monkeyssh/domain/services/biometric_prompt_coordinator.dart';
import 'package:monkeyssh/domain/services/hardware_key_service.dart';
import 'package:monkeyssh/domain/services/ssh_wire.dart';

import '../../helpers/fake_hardware_key_platform.dart';

Uint8List _bytes(int length, int value) =>
    Uint8List.fromList(List.filled(length, value));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('wire encoding', () {
    test('encodes an uncompressed point as an OpenSSH public-key blob', () {
      final point = Uint8List.fromList([0x04, ..._bytes(64, 7)]);
      final blob = encodeEcdsaP256PublicKeyBlob(point);

      expect(readSshHostKeyType(blob), hardwareKeyAlgorithm);
      final curve = readSshString(blob, 4 + hardwareKeyAlgorithm.length)!;
      expect(ascii.decode(curve), 'nistp256');
      final q = readSshString(blob, 8 + hardwareKeyAlgorithm.length + 8)!;
      expect(q, point);
    });

    test('rejects compressed or truncated points', () {
      expect(
        () => encodeEcdsaP256PublicKeyBlob(
          Uint8List.fromList([0x02, ..._bytes(32, 1)]),
        ),
        throwsFormatException,
      );
      expect(
        () => encodeEcdsaP256PublicKeyBlob(
          Uint8List.fromList([0x04, ..._bytes(63, 1)]),
        ),
        throwsFormatException,
      );
    });

    test('converts DER signatures that a server verifies', () {
      final pair = generateP256KeyPair();
      final blob = encodeEcdsaP256PublicKeyBlob(
        pair.publicKey.Q!.getEncoded(false),
      );
      for (var i = 0; i < 24; i++) {
        final data = Uint8List.fromList(utf8.encode('challenge $i'));
        final signature = ecdsaP256SignatureFromDer(
          derSignP256(pair.privateKey, data),
        ).encode();
        expect(
          verifySshSignature(
            publicKeyBlob: blob,
            data: data,
            signature: signature,
          ),
          isTrue,
        );
        expect(
          verifySshSignature(
            publicKeyBlob: blob,
            data: Uint8List.fromList(utf8.encode('tampered $i')),
            signature: signature,
          ),
          isFalse,
        );
      }
    });

    test('encodes scalars as minimal positive mpints', () {
      // r has its high bit set and needs a leading zero; s is short.
      final r = BigInt.parse('80${'11' * 31}', radix: 16);
      final s = BigInt.from(0x7f);
      final encoded = ecdsaP256SignatureFromDer(derEncodeSignature(r, s))
          .encode();

      expect(readSshHostKeyType(encoded), hardwareKeyAlgorithm);
      final blob = readSshString(encoded, 4 + hardwareKeyAlgorithm.length)!;
      final rBytes = readSshString(blob, 0)!;
      expect(rBytes.length, 33);
      expect(rBytes.first, 0);
      final sBytes = readSshString(blob, 4 + rBytes.length)!;
      expect(sBytes, [0x7f]);
    });

    test('rejects malformed DER', () {
      final valid = derEncodeSignature(BigInt.from(5), BigInt.from(9));
      for (final der in [
        Uint8List(0),
        Uint8List.fromList([0x31, ...valid.skip(1)]),
        Uint8List.fromList([...valid, 0]),
        Uint8List.fromList(valid.take(valid.length - 1).toList()),
        derEncodeSignature(BigInt.zero, BigInt.one),
        derEncodeSignature(BigInt.one << 264, BigInt.one),
        // A negative INTEGER.
        Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0x01]),
      ]) {
        expect(() => ecdsaP256SignatureFromDer(der), throwsFormatException);
      }
    });
  });

  group('HardwareKeyReference', () {
    final blob = encodeEcdsaP256PublicKeyBlob(
      Uint8List.fromList([0x04, ..._bytes(64, 3)]),
    );

    test('round-trips through its stored encoding', () {
      final reference = HardwareKeyReference(
        alias: 'alias-1',
        backing: HardwareKeyBacking.strongBox,
        publicKeyBlob: blob,
        requiresUserPresence: true,
      );
      final parsed = parseHardwareKeyReference(reference.encode())!;

      expect(parsed.alias, 'alias-1');
      expect(parsed.backing, HardwareKeyBacking.strongBox);
      expect(parsed.publicKeyBlob, blob);
      expect(parsed.requiresUserPresence, isTrue);
      expect(parsed.isEmulated, isFalse);
      expect(parsed.backingLabel, 'StrongBox');
    });

    test('labels an emulated keystore', () {
      final reference = HardwareKeyReference(
        alias: 'a',
        backing: HardwareKeyBacking.tee,
        publicKeyBlob: blob,
        requiresUserPresence: false,
        isEmulated: true,
      );
      expect(
        parseHardwareKeyReference(reference.encode())!.backingLabel,
        'TEE (emulator)',
      );
    });

    test('treats damaged references as hardware but unusable', () {
      for (final damaged in [
        '${HardwareKeyReference.prefix}not json',
        '${HardwareKeyReference.prefix}{"alias":"a"}',
        // A public key that is not an ecdsa-sha2-nistp256 blob.
        HardwareKeyReference.prefix +
            jsonEncode({'alias': 'a', 'backing': 'tee', 'publicKey': 'AAAA'}),
      ]) {
        final key = SshKey(
          id: 1,
          name: 'damaged',
          keyType: hardwareKeyAlgorithm,
          publicKey: '',
          privateKey: damaged,
          createdAt: DateTime(2026),
        );
        expect(key.isHardwareBacked, isTrue, reason: damaged);
        expect(key.hardwareKeyReference, isNull, reason: damaged);
      }
    });

    test('ignores PEM private keys', () {
      final key = SshKey(
        id: 1,
        name: 'pem',
        keyType: 'ssh-ed25519',
        publicKey: '',
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----',
        createdAt: DateTime(2026),
      );
      expect(key.isHardwareBacked, isFalse);
      expect(key.hardwareKeyReference, isNull);
    });
  });

  group('HardwareKeyService', () {
    test('reports unsupported platforms without calling native code', () async {
      final platform = FakeHardwareKeyPlatform();
      final service = HardwareKeyService(
        platform: platform,
        isPlatformSupported: false,
      );

      final capabilities = await service.getCapabilities();
      expect(capabilities.isAvailable, isFalse);
      expect(
        capabilities.unavailableReason,
        HardwareKeyUnavailableReason.unsupportedPlatform,
      );
      await expectLater(
        service.generate(requireUserPresence: false),
        throwsA(
          isA<HardwareKeyException>().having(
            (error) => error.code,
            'code',
            HardwareKeyErrorCode.unavailable,
          ),
        ),
      );
    });

    test('parses capabilities, including simulator degradation', () async {
      final platform = FakeHardwareKeyPlatform()
        ..capabilities = const {
          'available': true,
          'backing': 'tee',
          'userPresenceAvailable': false,
          'isEmulator': true,
        };
      final service = HardwareKeyService(
        platform: platform,
        isPlatformSupported: true,
      );

      final emulator = await service.getCapabilities();
      expect(emulator.backing, HardwareKeyBacking.tee);
      expect(emulator.userPresenceAvailable, isFalse);
      expect(emulator.isEmulator, isTrue);
      expect(emulator.strongBoxAvailable, isFalse);

      platform.capabilities = const {
        'available': true,
        'backing': 'tee',
        'userPresenceAvailable': true,
        'userPresenceAllowsPasscode': false,
      };
      expect(
        (await service.getCapabilities()).userPresenceAllowsPasscode,
        isFalse,
      );

      platform.capabilities = const {'available': false, 'reason': 'simulator'};
      final simulator = await service.getCapabilities();
      expect(simulator.isAvailable, isFalse);
      expect(
        simulator.unavailableReason,
        HardwareKeyUnavailableReason.simulator,
      );
      expect(simulator.unavailableReason!.message, contains('Simulator'));
    });

    test('generates a reference that carries the public key', () async {
      final platform = FakeHardwareKeyPlatform()
        ..backing = HardwareKeyBacking.strongBox;
      final service = HardwareKeyService(
        platform: platform,
        isPlatformSupported: true,
      );

      final generated = await service.generate(requireUserPresence: true);
      final reference = generated.reference;

      expect(reference.alias, startsWith('xyz.depollsoft.monkeyssh.sshkey.'));
      expect(reference.backing, HardwareKeyBacking.strongBox);
      expect(reference.requiresUserPresence, isTrue);
      expect(reference.publicKeyBlob, generated.publicKeyBlob);
      expect(
        generated.publicKeyBlob,
        encodeEcdsaP256PublicKeyBlob(
          platform.keys[reference.alias]!.publicKey.Q!.getEncoded(false),
        ),
      );
      final other = await service.generate(requireUserPresence: false);
      expect(other.reference.alias, isNot(reference.alias));
    });

    test('deletes the key when the platform returns a bad point', () async {
      final platform = FakeHardwareKeyPlatform()
        ..publicPointOverride = Uint8List.fromList([0x04, 1, 2]);
      final service = HardwareKeyService(
        platform: platform,
        isPlatformSupported: true,
      );

      await expectLater(
        service.generate(requireUserPresence: false),
        throwsA(isA<HardwareKeyException>()),
      );
      expect(platform.deletedAliases, hasLength(1));
      expect(platform.keys, isEmpty);
    });

    test('maps capability failures to a retryable state', () async {
      final service = HardwareKeyService(
        platform: _ThrowingCapabilitiesPlatform(),
        isPlatformSupported: true,
      );
      final capabilities = await service.getCapabilities();
      expect(
        capabilities.unavailableReason,
        HardwareKeyUnavailableReason.checkFailed,
      );
    });
  });

  group('HardwareKeyIdentity', () {
    late FakeHardwareKeyPlatform platform;
    late BiometricPromptCoordinator coordinator;
    late HardwareKeyService service;

    setUp(() {
      platform = FakeHardwareKeyPlatform();
      coordinator = BiometricPromptCoordinator();
      service = HardwareKeyService(
        platform: platform,
        isPlatformSupported: true,
        promptCoordinator: coordinator,
      );
    });

    Future<HardwareKeyIdentity> perUseIdentity() async => service.identityFor(
      (await service.generate(requireUserPresence: true)).reference,
    );

    Matcher failsWith(HardwareKeyErrorCode code) => throwsA(
      isA<HardwareKeyException>().having((error) => error.code, 'code', code),
    );

    test('per-use prompts show one at a time', () async {
      platform.holdSigns = true;
      final first = await perUseIdentity();
      final second = await perUseIdentity();

      final firstSign = first.sign(Uint8List.fromList([1]));
      final secondSign = second.sign(Uint8List.fromList([2]));
      final firstRequest = await platform.waitForPrompt();
      await pumpEventQueue();
      // Android shares one prompt view model per activity: a second prompt
      // would replace the first one's callback.
      expect(platform.signRequests, hasLength(1));

      platform.approve(firstRequest);
      await firstSign;
      final secondRequest = await platform.waitForPrompt();
      expect(secondRequest, isNot(firstRequest));
      expect(platform.signRequests, hasLength(2));
      platform.approve(secondRequest);
      await secondSign;
    });

    test('per-use prompts wait for the app lock to go away', () async {
      platform.holdSigns = true;
      final identity = await perUseIdentity();
      coordinator.setAppLocked(locked: true);

      final signing = identity.sign(Uint8List.fromList([1]));
      await pumpEventQueue();
      expect(platform.signRequests, isEmpty);

      coordinator.setAppLocked(locked: false);
      platform.approve(await platform.waitForPrompt());
      await signing;
      expect(platform.signRequests, hasLength(1));
    });

    test('a request cancelled behind the app lock never prompts', () async {
      final identity = await perUseIdentity();
      coordinator.setAppLocked(locked: true);

      final signing = identity.sign(Uint8List.fromList([1]));
      await pumpEventQueue();
      identity.cancelPendingSigns();
      await expectLater(signing, failsWith(HardwareKeyErrorCode.cancelled));

      coordinator.setAppLocked(locked: false);
      await pumpEventQueue();
      expect(platform.signRequests, isEmpty);
    });

    test('a request cancelled behind another prompt never shows', () async {
      platform.holdSigns = true;
      final first = await perUseIdentity();
      final second = await perUseIdentity();

      final firstSign = first.sign(Uint8List.fromList([1]));
      final secondSign = second.sign(Uint8List.fromList([2]));
      final firstRequest = await platform.waitForPrompt();
      second.cancelPendingSigns();
      await expectLater(secondSign, failsWith(HardwareKeyErrorCode.cancelled));

      platform.approve(firstRequest);
      await firstSign;
      await pumpEventQueue();
      expect(platform.signRequests, hasLength(1));
    });

    test(
      'an unanswered prompt times out, is dismissed and frees the queue',
      () async {
        final quick = HardwareKeyService(
          platform: platform,
          isPlatformSupported: true,
          promptCoordinator: coordinator,
          promptTimeout: const Duration(milliseconds: 30),
        );
        platform.holdSigns = true;
        final generated = await quick.generate(requireUserPresence: true);
        final identity = quick.identityFor(generated.reference);

        await expectLater(
          identity.sign(Uint8List.fromList([1])),
          failsWith(HardwareKeyErrorCode.timedOut),
        );
        expect(platform.cancelledRequests, hasLength(1));

        platform.holdSigns = false;
        await identity.sign(Uint8List.fromList([2]));
        expect(platform.signRequests, hasLength(2));
      },
    );

    test(
      'a key without confirmation that needs interaction is locked',
      () async {
        final identity = service.identityFor(
          (await service.generate(requireUserPresence: false)).reference,
        );
        platform.signError = const HardwareKeyException(
          HardwareKeyErrorCode.interactionRequired,
        );

        await expectLater(
          identity.sign(Uint8List.fromList([1])),
          failsWith(HardwareKeyErrorCode.deviceLocked),
        );
      },
    );

    test('the declining signature cannot verify', () async {
      final generated = await service.generate(requireUserPresence: false);
      final data = Uint8List.fromList(utf8.encode('challenge'));
      expect(
        verifySshSignature(
          publicKeyBlob: generated.publicKeyBlob,
          data: data,
          signature: HardwareKeyIdentity.unverifiableSignature.encode(),
        ),
        isFalse,
      );
    });

    test('probes first and signs with the hardware key', () async {
      final generated = await service.generate(requireUserPresence: false);
      final identity = service.identityFor(generated.reference);
      final data = Uint8List.fromList(utf8.encode('session challenge'));

      expect(identity.type, 'ecdsa-sha2-nistp256');
      expect(identity.shouldProbe, isTrue);
      expect(identity.comment, isNull);
      expect(identity.toPublicKey().encode(), generated.publicKeyBlob);

      final signature = await identity.sign(data);
      expect(
        verifySshSignature(
          publicKeyBlob: generated.publicKeyBlob,
          data: data,
          signature: signature.encode(),
        ),
        isTrue,
      );
      expect(platform.signRequests.single.alias, generated.reference.alias);
      expect(identity.hasPendingSign, isFalse);
    });

    test('cancels a waiting prompt and reports the cancellation', () async {
      platform.holdSigns = true;
      final generated = await service.generate(requireUserPresence: true);
      final identity = service.identityFor(generated.reference);

      final signing = identity.sign(Uint8List.fromList([1, 2, 3]));
      final requestId = await platform.waitForPrompt();
      expect(identity.hasPendingSign, isTrue);

      identity.cancelPendingSigns();
      await expectLater(
        signing,
        throwsA(
          isA<HardwareKeyException>().having(
            (error) => error.code,
            'code',
            HardwareKeyErrorCode.cancelled,
          ),
        ),
      );
      expect(platform.cancelledRequests, [requestId]);
      expect(identity.hasPendingSign, isFalse);
    });

    test('guarded copies share pending prompts with the original', () async {
      platform.holdSigns = true;
      final generated = await service.generate(requireUserPresence: true);
      final identity = service.identityFor(generated.reference);
      var guardRuns = 0;
      final guarded = identity.guardedBy((sign) {
        guardRuns++;
        return sign();
      });

      final signing = guarded.sign(Uint8List.fromList([4]));
      await platform.waitForPrompt();
      expect(guardRuns, 1);
      expect(identity.hasPendingSign, isTrue);

      identity.cancelPendingSigns();
      await expectLater(signing, throwsA(isA<HardwareKeyException>()));
    });
  });

  group('MethodChannelHardwareKeyPlatform', () {
    const channel = MethodChannel(
      MethodChannelHardwareKeyPlatform.hardwareKeyChannelName,
    );
    final calls = <MethodCall>[];

    tearDown(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    void handle(Future<Object?>? Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return handler(call);
          });
    }

    test('passes sign arguments and returns the DER bytes', () async {
      handle((call) async => Uint8List.fromList([9, 9]));
      const platform = MethodChannelHardwareKeyPlatform();

      final der = await platform.sign(
        alias: 'alias',
        data: Uint8List.fromList([1, 2]),
        reason: 'reason',
        requestId: 'sign-1',
      );

      expect(der, [9, 9]);
      expect(calls.single.method, 'sign');
      expect(calls.single.arguments, {
        'alias': 'alias',
        'data': [1, 2],
        'reason': 'reason',
        'requestId': 'sign-1',
      });
    });

    test('maps native error codes without platform messages', () async {
      for (final code in HardwareKeyErrorCode.values) {
        handle(
          (call) async => throw PlatformException(
            code: code.wireName,
            message: 'native detail',
          ),
        );
        const platform = MethodChannelHardwareKeyPlatform();
        await expectLater(
          platform.deleteKey('alias'),
          throwsA(
            isA<HardwareKeyException>()
                .having((error) => error.code, 'code', code)
                .having(
                  (error) => error.toString(),
                  'toString',
                  isNot(contains('native detail')),
                ),
          ),
        );
      }
    });

    test('treats a missing plugin as unavailable hardware', () async {
      const platform = MethodChannelHardwareKeyPlatform();
      await expectLater(
        platform.getCapabilities(),
        throwsA(
          isA<HardwareKeyException>().having(
            (error) => error.code,
            'code',
            HardwareKeyErrorCode.unavailable,
          ),
        ),
      );
    });

    test('reads generated keys', () async {
      final point = Uint8List.fromList([0x04, ..._bytes(64, 5)]);
      handle(
        (call) async => {
          'publicKey': point,
          'backing': 'strongBox',
          'isEmulator': false,
        },
      );
      const platform = MethodChannelHardwareKeyPlatform();

      final result = await platform.generateKey(
        alias: 'alias',
        requireUserPresence: true,
      );

      expect(result.publicKey, point);
      expect(result.backing, HardwareKeyBacking.strongBox);
      expect(result.isEmulated, isFalse);
      expect(calls.single.arguments, {
        'alias': 'alias',
        'requireUserPresence': true,
      });
    });
  });
}

class _ThrowingCapabilitiesPlatform extends FakeHardwareKeyPlatform {
  @override
  Future<Map<Object?, Object?>> getCapabilities() async =>
      throw const HardwareKeyException(HardwareKeyErrorCode.failed);
}
