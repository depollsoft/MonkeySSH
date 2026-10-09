import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

import '../../helpers/in_memory_sftp.dart';

const _notes = '/home/demo/notes.txt';

const _freeMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

class _MockSshClient extends Mock implements SSHClient {
  @override
  Future<void> close() async {}
}

class _MockMonetizationService extends Mock implements MonetizationService {
  _MockMonetizationService() {
    when(() => currentState).thenReturn(_freeMonetizationState);
  }
}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{
    session.connectionId: SshConnectionState.connected,
  };

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  Future<void> syncBackgroundStatus() async {}
}

String _text(InMemorySftpClient server, String path) =>
    utf8.decode(server.files[path]!);

Future<InMemorySftpClient> _openNotesInEditor(WidgetTester tester) async {
  final server = InMemorySftpClient()
    ..writeFile(_notes, utf8.encode('line one\n'));
  final ssh = _MockSshClient();
  when(ssh.sftp).thenAnswer((_) async => server);
  final session = SshSession(
    connectionId: 7,
    hostId: 1,
    client: ssh,
    config: const SshConnectionConfig(
      hostname: 'demo.example.com',
      port: 22,
      username: 'demo',
    ),
  );
  addTearDown(session.close);
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        activeSessionsProvider.overrideWith(
          () => _TestActiveSessionsNotifier(session),
        ),
        monetizationServiceProvider.overrideWithValue(
          _MockMonetizationService(),
        ),
        monetizationStateProvider.overrideWith(
          (ref) => Stream.value(_freeMonetizationState),
        ),
      ],
      child: const MaterialApp(home: SftpScreen(hostId: 1, connectionId: 7)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('notes.txt'));
  await tester.pumpAndSettle();
  expect(find.byType(RemoteTextEditorScreen), findsOneWidget);
  await tester.enterText(
    find.descendant(
      of: find.byType(RemoteTextEditorScreen),
      matching: find.byType(TextField),
    ),
    'line one\nfrom the phone\n',
  );
  await tester.pump();
  return server;
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Save'));
  await tester.pumpAndSettle();
}

Future<void> _tearDown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('SFTP editor save conflicts', () {
    testWidgets('an unchanged file saves with no extra prompt', (tester) async {
      final server = await _openNotesInEditor(tester);
      server.now += 60;

      await _tapSave(tester);

      expect(find.text('File changed on the host'), findsNothing);
      expect(find.byType(RemoteTextEditorScreen), findsNothing);
      expect(_text(server, _notes), 'line one\nfrom the phone\n');
      expect(find.text('Saved "notes.txt"'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets(
      'an agent edit before the save prompts instead of overwriting',
      (tester) async {
        final server = await _openNotesInEditor(tester);
        server.writeFile(
          _notes,
          utf8.encode('line one\nfrom the agent\n'),
          modifyTime: server.now + 5,
        );

        await _tapSave(tester);

        expect(find.text('File changed on the host'), findsOneWidget);
        expect(_text(server, _notes), 'line one\nfrom the agent\n');

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(RemoteTextEditorScreen), findsOneWidget);
        expect(_text(server, _notes), 'line one\nfrom the agent\n');

        await _tapSave(tester);
        await tester.tap(find.text('Overwrite host version'));
        await tester.pumpAndSettle();
        expect(_text(server, _notes), 'line one\nfrom the phone\n');
        expect(find.byType(RemoteTextEditorScreen), findsNothing);
        await _tearDown(tester);
      },
    );

    testWidgets('save as a copy writes beside the original only', (
      tester,
    ) async {
      final server = await _openNotesInEditor(tester);
      server.writeFile(_notes, utf8.encode('line one\nfrom the agent\n'));

      await _tapSave(tester);
      await tester.tap(find.text('Save as a copy'));
      await tester.pumpAndSettle();

      expect(_text(server, _notes), 'line one\nfrom the agent\n');
      expect(
        _text(server, '/home/demo/notes (copy).txt'),
        'line one\nfrom the phone\n',
      );
      expect(find.byType(RemoteTextEditorScreen), findsNothing);
      expect(
        find.text('Saved your edits as "notes (copy).txt"'),
        findsOneWidget,
      );
      expect(find.text('notes (copy).txt'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('reload loads the host version and becomes the baseline', (
      tester,
    ) async {
      final server = await _openNotesInEditor(tester);
      server.writeFile(
        _notes,
        utf8.encode('line one\nfrom the agent\n'),
        modifyTime: server.now + 5,
      );

      await _tapSave(tester);
      await tester.tap(find.text('Reload host version'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard and reload'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(RemoteTextEditorScreen),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, 'line one\nfrom the agent\n');

      // A save after reloading is checked against the reloaded version.
      await tester.enterText(
        find.byWidget(field),
        'line one\nfrom the agent\nand the phone\n',
      );
      await tester.pump();
      await _tapSave(tester);
      expect(find.text('File changed on the host'), findsNothing);
      expect(
        _text(server, _notes),
        'line one\nfrom the agent\nand the phone\n',
      );
      await _tearDown(tester);
    });
  });
}
