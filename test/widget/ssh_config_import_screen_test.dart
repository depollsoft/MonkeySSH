// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/presentation/screens/ssh_config_import_screen.dart';

const _config = '''
Include ~/.ssh/extra
Host bastion
  HostName bastion.example.com
  User jump
Host app
  HostName 10.0.0.2
  User deploy
  ProxyJump bastion
  LocalForward 8080 localhost:80
  ProxyCommand nc %h %p
Host nouser
  HostName nouser.example.com
  IdentityFile ~/.ssh/id_work
Match host app
  User root
''';

Widget _app(AppDatabase db, {String? text = _config}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(db),
    hostRepositoryProvider.overrideWithValue(
      HostRepository(db, SecretEncryptionService.forTesting()),
    ),
  ],
  child: MaterialApp(home: SshConfigImportScreen(initialText: text)),
);

/// Unmounts the screen so drift can close its watched queries, whose close
/// timer would otherwise outlive the test.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('preview lists hosts, jumps, forwards, keys and skips', (
    tester,
  ) async {
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('3 hosts · 0 jump-only · 4 skipped'), findsOneWidget);
    expect(find.text('app'), findsOneWidget);
    expect(find.text('deploy@10.0.0.2:22'), findsOneWidget);
    expect(find.text('via bastion'), findsOneWidget);
    expect(
      find.textContaining('1 forward: L 8080→localhost:80'),
      findsOneWidget,
    );
    expect(find.textContaining('Key needed: import id_work'), findsOneWidget);
    expect(find.text('Username for hosts without User'), findsOneWidget);
    expect(find.textContaining('This host has no User'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('skipped (4)'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('skipped (4)'), findsOneWidget);
    for (final keyword in ['Include', 'ProxyCommand', 'Match']) {
      expect(
        find.textContaining(keyword, findRichText: true),
        findsWidgets,
        reason: keyword,
      );
    }
    expect(
      find.textContaining('Include files aren’t read', findRichText: true),
      findsOneWidget,
    );

    // nouser is blocked until a username is given.
    expect(find.text('Import 2 Hosts'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('imports the selection with its jump host and forwards', (
    tester,
  ) async {
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('ssh-config-default-username')),
      'me',
    );
    await tester.pumpAndSettle();
    expect(find.text('Import 3 Hosts'), findsOneWidget);

    // Deselect bastion: it is still saved because app jumps through it.
    await tester.tap(find.text('bastion'));
    await tester.pumpAndSettle();
    expect(find.text('Needed as a jump host'), findsOneWidget);
    expect(find.text('Import 3 Hosts'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ssh-config-import-button')));
    await tester.pumpAndSettle();

    expect(find.text('Imported 3 hosts.'), findsOneWidget);
    final hosts = (await tester.runAsync(
      () => HostRepository(db, SecretEncryptionService.forTesting()).getAll(),
    ))!;
    expect(hosts.map((host) => host.label), ['bastion', 'app', 'nouser']);
    final app = hosts.singleWhere((host) => host.label == 'app');
    final bastion = hosts.singleWhere((host) => host.label == 'bastion');
    expect(app.jumpHostId, bastion.id);
    expect(hosts.singleWhere((host) => host.label == 'nouser').username, 'me');
    final forwards = (await tester.runAsync(
      () => PortForwardRepository(db).getByHostId(app.id),
    ))!;
    expect(forwards.single.localPort, 8080);
    await _unmount(tester);
  });

  testWidgets('hosts already saved start unselected', (tester) async {
    await tester.runAsync(
      () => HostRepository(db, SecretEncryptionService.forTesting()).insert(
        HostsCompanion.insert(
          label: 'Bastion',
          hostname: 'bastion.example.com',
          username: 'jump',
        ),
      ),
    );
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('Already saved as Bastion.'), findsOneWidget);
    // app is selected; bastion is not, but app still needs it.
    expect(find.text('Import 2 Hosts'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('preview waits for text', (tester) async {
    await tester.pumpWidget(_app(db, text: null));
    await tester.pumpAndSettle();
    final preview = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Preview'),
    );
    expect(preview.onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('ssh-config-source')),
      'Host *\n  User me\n',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No hosts to import'), findsOneWidget);
    expect(find.text('Select Hosts to Import'), findsOneWidget);
    await _unmount(tester);
  });
}
