// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/host_key_prompt.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';

void registerHostKeyPromptTests() {
  group('host_key_prompt', () {
    group('createHostKeyPromptHandler', () {
      testWidgets('fails closed for unknown hosts without a navigator', (
        tester,
      ) async {
        final handler = createHostKeyPromptHandler();

        await expectLater(
          handler(
            HostKeyVerificationRequest(
              presentedHostKey: _verifiedHostKey('headless.example.com', 22, [
                1,
                2,
                3,
              ]),
              existingKnownHost: null,
            ),
          ),
          throwsA(
            isA<HostKeyVerificationException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('Host key verification is required'),
                contains('trust prompt could not be shown'),
              ),
            ),
          ),
        );
      });

      testWidgets('fails closed for changed hosts without a navigator', (
        tester,
      ) async {
        final currentKey = _verifiedHostKey('changed.example.com', 22, [
          4,
          5,
          6,
        ]);
        final replacementKey = _verifiedHostKey('changed.example.com', 22, [
          7,
          8,
          9,
        ]);
        final handler = createHostKeyPromptHandler();

        await expectLater(
          handler(
            HostKeyVerificationRequest(
              presentedHostKey: replacementKey,
              existingKnownHost: KnownHost(
                id: 1,
                hostname: currentKey.hostname,
                port: currentKey.port,
                keyType: currentKey.keyType,
                fingerprint: currentKey.fingerprint,
                hostKey: currentKey.encodedHostKey,
                firstSeen: DateTime(2026),
                lastSeen: DateTime(2026),
              ),
            ),
          ),
          throwsA(
            isA<HostKeyVerificationException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('host key for changed.example.com:22 changed'),
                contains('trust prompt could not be shown'),
              ),
            ),
          ),
        );
      });
    });
  });
}

VerifiedHostKey _verifiedHostKey(
  String hostname,
  int port,
  List<int> keyData,
) => VerifiedHostKey(
  hostname: hostname,
  port: port,
  keyType: 'ssh-ed25519',
  hostKeyBytes: _ed25519HostKeyBlob(keyData),
);

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final typeBytes = utf8.encode('ssh-ed25519');
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(typeBytes.length))
    ..add(typeBytes)
    ..add(_uint32(keyData.length))
    ..add(keyData);
  return writer.takeBytes();
}

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);
