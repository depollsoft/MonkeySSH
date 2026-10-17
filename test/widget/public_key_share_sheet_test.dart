// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/authorized_key_install_service.dart';
import 'package:monkeyssh/presentation/widgets/public_key_share_sheet.dart';

const _publicKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyzmuYFVXnOvGclmhCuS6X1QWypbVXqzlWgC5mOZJyp';

SshKey _key({String publicKey = _publicKey}) => SshKey(
  id: 1,
  name: 'Phone key',
  keyType: 'ssh-ed25519',
  publicKey: publicKey,
  privateKey: 'PRIVATE-KEY-MATERIAL',
  createdAt: DateTime(2026),
);

void main() {
  late List<String> clipboard;

  setUp(() {
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<void> pump(WidgetTester tester, SshKey key) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PublicKeyShareSheet(sshKey: key)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a QR code and copies the key and command', (tester) async {
    await pump(tester, _key());

    expect(
      find.bySemanticsLabel('QR code of the public key Phone key'),
      findsOneWidget,
    );
    expect(find.text('$_publicKey Phone-key'), findsOneWidget);
    expect(find.text('Share Install Command'), findsOneWidget);

    await tester.tap(find.text('Copy Key'));
    await tester.pump();
    await tester.tap(find.text('Copy Command'));
    await tester.pump();

    expect(clipboard, [
      '$_publicKey Phone-key',
      buildManualAuthorizedKeyCommand('$_publicKey Phone-key'),
    ]);
    expect(clipboard.join(), isNot(contains('PRIVATE')));
  });

  testWidgets('an unrecognized key still offers a copy but no command', (
    tester,
  ) async {
    await pump(tester, _key(publicKey: 'ssh-unknown AAAA'));
    expect(find.text('ssh-unknown AAAA'), findsOneWidget);
    expect(find.text('Share Install Command'), findsNothing);
    expect(find.text('Copy Command'), findsNothing);
  });
}
