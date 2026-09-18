import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';
const _testHost = String.fromEnvironment('TEST_SSH_HOST');
const _testPort = int.fromEnvironment('TEST_SSH_PORT');
const _testUsername = String.fromEnvironment('TEST_SSH_USERNAME');
const _testPrivateKeyBase64 = String.fromEnvironment(
  'TEST_SSH_PRIVATE_KEY_B64',
);
const _testPublicKeyBase64 = String.fromEnvironment('TEST_SSH_PUBLIC_KEY_B64');
const _hasSshImeTestConfig =
    _testHost != '' &&
    _testPort > 0 &&
    _testUsername != '' &&
    _testPrivateKeyBase64 != '' &&
    _testPublicKeyBase64 != '';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TerminalScreen IME behavior matches in a real SSH session', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final encryptionService = SecretEncryptionService.forTesting();
    final hostRepository = HostRepository(db, encryptionService);
    final keyRepository = KeyRepository(db, encryptionService);

    final privateKey = utf8.decode(base64Decode(_testPrivateKeyBase64));
    final publicKey = utf8.decode(base64Decode(_testPublicKeyBase64));
    final keyId = await keyRepository.insert(
      SshKeysCompanion.insert(
        name: 'IME SSH Test Key',
        keyType: 'ed25519',
        publicKey: publicKey,
        privateKey: privateKey,
        passphrase: const Value(null),
        fingerprint: const Value('ime-ssh-test'),
      ),
    );

    final hostId = await hostRepository.insert(
      HostsCompanion.insert(
        label: 'IME SSH Test Host',
        hostname: _testHost,
        port: const Value(_testPort),
        username: _testUsername,
        keyId: Value(keyId),
        password: const Value(null),
      ),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secretEncryptionServiceProvider.overrideWithValue(encryptionService),
        hostKeyPromptHandlerProvider.overrideWithValue(
          (_) async => HostKeyTrustDecision.trust,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: TerminalScreen(hostId: hostId)),
      ),
    );

    await _pumpUntilConnected(tester);
    await _focusTerminal(tester);

    final terminal = _terminalFromView(tester);

    await _runRemoteEchoCase(
      tester,
      terminal: terminal,
      readyMarker: 'R1',
      resultMarker: 'V1',
      input: () async {
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '\u200B\u200Bteh ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '\u200B\u200Bte',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '\u200B\u200B the ',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await _submitNewline(tester);
      },
      expectedResult: 'the ',
    );

    await _runRemoteEchoCase(
      tester,
      terminal: terminal,
      readyMarker: 'R2',
      resultMarker: 'V2',
      input: () async {
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hello',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}hell',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}o',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
        await _submitNewline(tester);
      },
      expectedResult: 'hello',
    );

    await _runRemoteEchoCase(
      tester,
      terminal: terminal,
      readyMarker: 'R3',
      resultMarker: 'V3',
      input: () async {
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}didnt',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}didn',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await _updateTerminalEditingValue(
          tester,
          const TextEditingValue(
            text: '$_deleteDetectionMarker test',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await _submitNewline(tester);
      },
      expectedResult: 'didntest',
    );
  }, skip: !_hasSshImeTestConfig);
}

Future<void> _pumpUntilConnected(WidgetTester tester) async {
  for (var i = 0; i < 120; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.text('Connecting...').evaluate().isEmpty) {
      break;
    }
  }
  expect(find.textContaining('Failed to start shell'), findsNothing);
  expect(find.textContaining('Connection failed'), findsNothing);
}

Future<void> _focusTerminal(WidgetTester tester) async {
  await tester.tap(find.byType(MonkeyTerminalView));
  await tester.pump();
}

Terminal _terminalFromView(WidgetTester tester) =>
    tester.widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView)).terminal;

Future<void> _updateTerminalEditingValue(
  WidgetTester tester,
  TextEditingValue value,
) async {
  tester.testTextInput.updateEditingValue(value);
  await tester.pump();
}

Future<void> _submitNewline(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.newline);
  await tester.pump();
}

Future<void> _runRemoteEchoCase(
  WidgetTester tester, {
  required Terminal terminal,
  required String readyMarker,
  required String resultMarker,
  required Future<void> Function() input,
  required String expectedResult,
}) async {
  final normalizedExpectedResult = expectedResult.replaceAll(' ', '_');
  terminal.textInput(
    'python3 -u -c \'import sys; print("$readyMarker"); sys.stdout.flush(); '
    'line=sys.stdin.readline().rstrip("\\\\r\\\\n"); print("$resultMarker"); '
    'print(line.replace(" ", "_")); print("OK"); '
    'sys.stdout.flush()\'\r',
  );
  await _waitForTerminalText(
    tester,
    terminal,
    readyMarker,
    description: 'Timed out waiting for remote SSH echo program startup',
  );

  await input();

  await _waitForTerminalText(
    tester,
    terminal,
    '$resultMarker\n$normalizedExpectedResult',
    description: 'Timed out waiting for SSH IME result $resultMarker',
  );
}

Future<void> _waitForTerminalText(
  WidgetTester tester,
  Terminal terminal,
  String expected, {
  required String description,
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
    if (_terminalBufferText(terminal).contains(expected)) {
      return;
    }
  }
  fail(
    '$description\nCurrent terminal text:\n${_terminalBufferText(terminal)}',
  );
}

String _terminalBufferText(Terminal terminal) {
  final logicalLines = <StringBuffer>[];

  for (var index = 0; index < terminal.buffer.lines.length; index += 1) {
    final line = terminal.buffer.lines[index];
    final text = line.getText(0, terminal.buffer.viewWidth);
    if (line.isWrapped && logicalLines.isNotEmpty) {
      logicalLines.last.write(text);
      continue;
    }
    logicalLines.add(StringBuffer(text));
  }

  return logicalLines
      .map((line) => line.toString().replaceFirst(RegExp(r' +$'), ''))
      .join('\n');
}
