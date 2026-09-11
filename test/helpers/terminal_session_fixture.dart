// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockShellChannel extends Mock implements SSHSession {}

class TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  TestActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{
    session.connectionId: SshConnectionState.connected,
  };

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) =>
      hostId == session.hostId ? <int>[session.connectionId] : const <int>[];

  @override
  ActiveConnection? getActiveConnection(int connectionId) => null;

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  Future<void> syncBackgroundStatus() async {}
}

Host buildSelectionTestHost({required int id}) => Host(
  id: id,
  label: 'Terminal selection test host',
  hostname: 'terminal.example.com',
  port: 22,
  username: 'root',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
);

class TerminalSessionFixture {
  TerminalSessionFixture({
    required int hostId,
    required int connectionId,
    Stream<Uint8List>? stdout,
  }) {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final hostRepository = _MockHostRepository();
    final sshClient = _MockSshClient();
    final shellChannel = _MockShellChannel();
    final host = buildSelectionTestHost(id: hostId);
    final shellDoneCompleter = Completer<void>();
    final shellStdoutController = stdout == null
        ? StreamController<Uint8List>.broadcast()
        : null;
    if (shellStdoutController != null) {
      addTearDown(shellStdoutController.close);
    }

    when(() => hostRepository.getById(host.id)).thenAnswer((_) async => host);
    when(
      () => sshClient.shell(pty: any(named: 'pty')),
    ).thenAnswer((_) async => shellChannel);
    when(
      () => shellChannel.stdout,
    ).thenAnswer((_) => stdout ?? shellStdoutController!.stream);
    when(
      () => shellChannel.stderr,
    ).thenAnswer((_) => const Stream<Uint8List>.empty());
    when(() => shellChannel.done).thenAnswer((_) => shellDoneCompleter.future);
    when(() => shellChannel.write(any())).thenReturn(null);

    final session = SshSession(
      connectionId: connectionId,
      hostId: host.id,
      client: sshClient,
      config: const SshConnectionConfig(
        hostname: 'terminal.example.com',
        port: 22,
        username: 'root',
      ),
    )..getOrCreateTerminal();

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        hostRepositoryProvider.overrideWithValue(hostRepository),
        sharedClipboardProvider.overrideWith((ref) async => false),
        activeSessionsProvider.overrideWith(
          () => TestActiveSessionsNotifier(session),
        ),
      ],
    );
    addTearDown(container.dispose);

    this.host = host;
    this.session = session;
    this.container = container;
  }

  late final Host host;
  late final SshSession session;
  late final ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: TerminalScreen(
            hostId: host.id,
            connectionId: session.connectionId,
          ),
        ),
      ),
    );
  }
}
