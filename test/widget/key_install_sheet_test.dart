// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/authorized_key_install_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/key_install_sheet.dart';

import '../helpers/mocks.dart';

const _publicKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyzmuYFVXnOvGclmhCuS6X1QWypbVXqzlWgC5mOZJyp';

class _FakeInstallService extends AuthorizedKeyInstallService {
  _FakeInstallService(HostRepository hosts)
    : super(
        hostRepository: hosts,
        connectKeyOnly: (_) async =>
            const SshConnectionResult(success: false, error: 'unused'),
      );

  AuthorizedKeyInstallOutcome outcome = AuthorizedKeyInstallOutcome.added;
  KeyLoginVerification verification = const KeyLoginVerification(success: true);
  final installedKeyIds = <int>[];
  final switches = <({int hostId, int keyId, bool removePassword})>[];

  @override
  Future<AuthorizedKeyInstallOutcome> installKey(
    SshSession session,
    SshKey key,
  ) async {
    installedKeyIds.add(key.id);
    return outcome;
  }

  @override
  Future<KeyLoginVerification> verifyKeyOnlyLogin(
    SshSession session,
    SshKey key,
  ) async => verification;

  @override
  Future<void> switchHostToKey(
    int hostId,
    int keyId, {
    required bool removePassword,
  }) async => switches.add((
    hostId: hostId,
    keyId: keyId,
    removePassword: removePassword,
  ));
}

class _FakeSshService extends SshService {
  _FakeSshService(this.session);

  final SshSession session;

  @override
  List<SshSession> getSessionsForHost(int hostId) => [session];

  @override
  SshSession? getSession(int connectionId) => session;
}

Host _host() => Host(
  id: 5,
  label: 'build-box',
  hostname: 'build.example.com',
  port: 22,
  username: 'me',
  password: 'hunter2',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  lastConnectedAt: DateTime(2026, 10),
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
);

void main() {
  late AppDatabase db;
  late _FakeInstallService service;
  late MockSshSession session;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = _FakeInstallService(
      HostRepository(db, SecretEncryptionService.forTesting()),
    );
    session = MockSshSession();
    when(() => session.connectionId).thenReturn(1);
    when(() => session.hostId).thenReturn(5);
  });

  tearDown(() => db.close());

  Future<void> pumpSheet(WidgetTester tester) async {
    final key = SshKey(
      id: 9,
      name: 'Laptop key',
      keyType: 'ssh-ed25519',
      publicKey: _publicKey,
      privateKey: 'PRIVATE',
      createdAt: DateTime(2026),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          keyRepositoryProvider.overrideWithValue(
            KeyRepository(db, SecretEncryptionService.forTesting()),
          ),
          allKeysProvider.overrideWith((ref) => Stream.value([key])),
          authorizedKeyInstallServiceProvider.overrideWithValue(service),
          sshServiceProvider.overrideWithValue(_FakeSshService(session)),
        ],
        child: MaterialApp(
          home: Scaffold(body: KeyInstallSheet(host: _host())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('installs, verifies, then removes the password', (tester) async {
    await pumpSheet(tester);

    expect(find.text('Key Login'), findsOneWidget);
    expect(find.text('Laptop key'), findsOneWidget);
    expect(find.text('Generate a new Ed25519 key'), findsOneWidget);

    await tester.tap(find.text('Install Key'));
    await tester.pumpAndSettle();

    expect(service.installedKeyIds, [9]);
    expect(service.switches, [(hostId: 5, keyId: 9, removePassword: false)]);
    expect(find.text('Remove the saved password?'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Reconnect with only the key, done'),
      findsOneWidget,
    );

    await tester.tap(find.text('Remove Password'));
    await tester.pumpAndSettle();

    expect(service.switches.last, (hostId: 5, keyId: 9, removePassword: true));
    expect(
      find.text('This host now signs in with Laptop key.'),
      findsOneWidget,
    );
    expect(find.text('No password is saved for it.'), findsOneWidget);
  });

  testWidgets('keeping the password leaves it as a fallback', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('Install Key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep Password'));
    await tester.pumpAndSettle();

    expect(service.switches, hasLength(1));
    expect(
      find.text('The saved password is kept as a fallback.'),
      findsOneWidget,
    );
  });

  testWidgets('a rejected key keeps the password and offers manual setup', (
    tester,
  ) async {
    service.verification = const KeyLoginVerification(
      success: false,
      error: 'Authentication failed: All authentication methods failed',
    );
    await pumpSheet(tester);
    await tester.tap(find.text('Install Key'));
    await tester.pumpAndSettle();

    expect(service.switches, isEmpty);
    expect(
      find.textContaining('the host still uses the password'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Reconnect with only the key, failed'),
      findsOneWidget,
    );
    expect(find.text('Add the Key by Hand'), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('a failed install explains why and stops', (tester) async {
    service.outcome = AuthorizedKeyInstallOutcome.fileNotWritable;
    await pumpSheet(tester);
    await tester.tap(find.text('Install Key'));
    await tester.pumpAndSettle();

    expect(
      find.text('Couldn’t write ~/.ssh/authorized_keys on the server.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Reconnect with only the key, waiting'),
      findsOneWidget,
    );
    expect(service.switches, isEmpty);
  });
}
