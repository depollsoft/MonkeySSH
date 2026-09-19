// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/presentation/widgets/host_key_trust_dialog.dart';

void registerHostKeyTrustDialogTests() {
  group('host_key_trust_dialog', () {
    group('showHostKeyTrustDialog', () {
      testWidgets('returns trust for an unknown host', (tester) async {
        final request = HostKeyVerificationRequest(
          presentedHostKey: _verifiedHostKey('unknown.example.com', 22, [
            1,
            2,
            3,
          ]),
          existingKnownHost: null,
        );
        late HostKeyTrustDecision decision;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    decision = await showHostKeyTrustDialog(
                      context: context,
                      request: request,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Verify host identity'), findsOneWidget);
        expect(find.text('Trust host'), findsOneWidget);

        await tester.tap(find.text('Trust host'));
        await tester.pumpAndSettle();

        expect(decision, HostKeyTrustDecision.trust);
      });

      testWidgets('shows previous key details for replacements', (
        tester,
      ) async {
        final currentKey = _verifiedHostKey('changed.example.com', 22, [
          4,
          5,
          6,
        ]);
        final request = HostKeyVerificationRequest(
          presentedHostKey: _verifiedHostKey('changed.example.com', 22, [
            7,
            8,
            9,
          ]),
          existingKnownHost: KnownHost(
            id: 1,
            hostname: 'changed.example.com',
            port: 22,
            keyType: currentKey.keyType,
            fingerprint: currentKey.fingerprint,
            hostKey: currentKey.encodedHostKey,
            firstSeen: DateTime(2024),
            lastSeen: DateTime(2024),
          ),
        );
        late HostKeyTrustDecision decision;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    decision = await showHostKeyTrustDialog(
                      context: context,
                      request: request,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Host key changed'), findsOneWidget);
        expect(find.text('Previously trusted'), findsOneWidget);
        expect(find.text('Replace trusted key'), findsOneWidget);

        await tester.tap(find.text('Replace trusted key'));
        await tester.pumpAndSettle();

        expect(decision, HostKeyTrustDecision.replace);
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
