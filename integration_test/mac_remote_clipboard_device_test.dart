import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/domain/services/remote_clipboard_sync_service.dart';

const _testHost = String.fromEnvironment('TEST_SSH_HOST');
const _testPort = int.fromEnvironment('TEST_SSH_PORT');
const _testUsername = String.fromEnvironment('TEST_SSH_USERNAME');
const _testPrivateKeyBase64 = String.fromEnvironment(
  'TEST_SSH_PRIVATE_KEY_B64',
);
const _hasMacRemoteClipboardConfig =
    _testHost != '' &&
    _testPort > 0 &&
    _testUsername != '' &&
    _testPrivateKeyBase64 != '';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Mac remote clipboard commands work with device clipboard APIs', (
    tester,
  ) async {
    final client = await _connectClient();
    addTearDown(client.close);

    const localText = 'device-local-copy';
    await Clipboard.setData(const ClipboardData(text: localText));
    final writeSession = await client.execute(
      RemoteClipboardSyncService.buildWriteCommand(localText),
    );
    await _drainSession(writeSession);

    final remoteReadback = await _runCommand(client, 'pbpaste');
    expect(remoteReadback.trimRight(), localText);

    const remoteText = 'remote-mac-copy';
    await _runCommand(client, "printf %s 'remote-mac-copy' | pbcopy");
    final readSession = await client.execute(
      RemoteClipboardSyncService.buildReadCommand(),
    );
    final readOutput = await _drainSession(readSession);
    final parsed = RemoteClipboardSyncService.parseReadOutput(readOutput);
    expect(parsed.supported, isTrue);
    expect(parsed.text, remoteText);

    await Clipboard.setData(ClipboardData(text: parsed.text));
    final localClipboard = await Clipboard.getData(Clipboard.kTextPlain);
    expect(localClipboard?.text, remoteText);
  }, skip: !_hasMacRemoteClipboardConfig);
}

Future<SSHClient> _connectClient() async {
  final socket = await SSHSocket.connect(_testHost, _testPort);
  final privateKey = utf8.decode(base64Decode(_testPrivateKeyBase64));
  return SSHClient(
    socket,
    username: _testUsername,
    onVerifyHostKey: (_, _) => true,
    identities: SSHKeyPair.fromPem(privateKey),
  );
}

Future<String> _runCommand(SSHClient client, String command) async {
  final session = await client.execute(command);
  return _drainSession(session);
}

Future<String> _drainSession(SSHSession session) async {
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  final stdoutFuture = session.stdout
      .cast<List<int>>()
      .transform(utf8.decoder)
      .forEach(stdout.write);
  final stderrFuture = session.stderr
      .cast<List<int>>()
      .transform(utf8.decoder)
      .forEach(stderr.write);
  await Future.wait<void>([stdoutFuture, stderrFuture, session.done]);
  return stdout.toString().isNotEmpty ? stdout.toString() : stderr.toString();
}
